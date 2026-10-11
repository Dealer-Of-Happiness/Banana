//
//  KnowledgeLibrary.swift
//  AIGoodbye
//
//  A permanent, private library of documents. Anything added here can be
//  consulted in every conversation - a second brain that never leaves the
//  device.
//
//  The heavy lifting (chunking, retrieval) is done by DocumentIndex; this
//  keeps the user-facing list and which documents are switched on.
//

import Foundation
import Combine

struct LibraryDocument: Identifiable, Codable, Equatable {
    var id: UUID          // matches the DocumentIndex document id
    var name: String
    var addedAt: Date
    var characterCount: Int
    var isEnabled: Bool = true
}

@MainActor
final class KnowledgeLibrary: ObservableObject {
    static let shared = KnowledgeLibrary()

    @Published private(set) var documents: [LibraryDocument] = []

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AiGoodbyeMemory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }

    /// True when the index on disk exists but could not be read. Every write
    /// is refused then: saving an empty list over a file that merely failed
    /// to decode would erase the library.
    private(set) var loadFailed = false

    private init() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([LibraryDocument].self, from: data) {
            documents = decoded
        } else {
            loadFailed = true
        }
    }

    /// How many library documents can be switched on at once. Each enabled
    /// document is chunked and searched on every message, so this is capped
    /// to keep sending a message fast next to a multi-gigabyte model.
    static let maxEnabled = 3

    /// Ids of documents the AI may consult right now.
    var activeDocumentIds: [UUID] {
        Array(documents.filter(\.isEnabled).map(\.id).prefix(Self.maxEnabled))
    }

    var enabledCount: Int { documents.filter(\.isEnabled).count }

    func canEnableMore(than document: LibraryDocument) -> Bool {
        document.isEnabled || enabledCount < Self.maxEnabled
    }

    var hasActiveDocuments: Bool { !activeDocumentIds.isEmpty }

    /// Add a document. A fourth (and later) document is added switched OFF -
    /// the cap is on documents consulted at once, and silently adding it ON
    /// while never consulting it was the worst of both. Throws when the text
    /// or the index could not be written (a full disk), instead of showing
    /// a document that vanishes on the next launch.
    @discardableResult
    func add(name: String, fullText: String) async throws -> LibraryDocument {
        try checkWritable()
        let id = try await DocumentIndex.shared.store(name: name, fullText: fullText)
        let document = LibraryDocument(
            id: id, name: name, addedAt: Date(), characterCount: fullText.count,
            isEnabled: enabledCount < Self.maxEnabled
        )
        documents.append(document)
        do {
            try save()
        } catch {
            documents.removeAll { $0.id == id }
            await DocumentIndex.shared.removeDocument(id)
            throw error
        }
        return document
    }

    /// Promote a document already stored by the chat flow into the library.
    func adopt(id: UUID, name: String, characterCount: Int) throws {
        guard !documents.contains(where: { $0.id == id }) else { return }
        try checkWritable()
        documents.append(LibraryDocument(
            id: id, name: name, addedAt: Date(), characterCount: characterCount,
            isEnabled: enabledCount < Self.maxEnabled
        ))
        try save()
    }

    func setEnabled(_ enabled: Bool, for document: LibraryDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[index].isEnabled = enabled
        try? save()
    }

    func delete(_ document: LibraryDocument) {
        documents.removeAll { $0.id == document.id }
        try? save()
        Task { await DocumentIndex.shared.removeDocument(document.id) }
    }

    func deleteAll() {
        let ids = documents.map(\.id)
        documents.removeAll()
        try? save()
        Task {
            for id in ids { await DocumentIndex.shared.removeDocument(id) }
        }
    }

    /// Forget documents whose text is no longer on disk (a restore from a
    /// backup that did not include them), so the list never shows ghosts
    /// that silently contribute nothing.
    func dropMissingDocuments() async {
        var missing: [UUID] = []
        for document in documents {
            if await !DocumentIndex.shared.hasDocument(document.id) {
                missing.append(document.id)
            }
        }
        guard !missing.isEmpty else { return }
        documents.removeAll { missing.contains($0.id) }
        try? save()
    }

    private func checkWritable() throws {
        if loadFailed { throw LibraryError.indexUnreadable }
    }

    private func save() throws {
        let data = try JSONEncoder().encode(documents)
        try data.write(to: Self.fileURL, options: .atomic)
    }
}

enum LibraryError: LocalizedError {
    case indexUnreadable

    var errorDescription: String? {
        switch self {
        case .indexUnreadable:
            return L10n.text("The library index couldn't be read, so nothing can be added until it is repaired. Restart the app and try again.")
        }
    }
}
