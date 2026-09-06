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

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([LibraryDocument].self, from: data) {
            documents = decoded
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

    @discardableResult
    func add(name: String, fullText: String) async -> UUID {
        let id = await DocumentIndex.shared.store(name: name, fullText: fullText)
        documents.append(LibraryDocument(
            id: id, name: name, addedAt: Date(), characterCount: fullText.count
        ))
        save()
        return id
    }

    /// Promote a document already stored by the chat flow into the library.
    func adopt(id: UUID, name: String, characterCount: Int) {
        guard !documents.contains(where: { $0.id == id }) else { return }
        documents.append(LibraryDocument(
            id: id, name: name, addedAt: Date(), characterCount: characterCount
        ))
        save()
    }

    func setEnabled(_ enabled: Bool, for document: LibraryDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[index].isEnabled = enabled
        save()
    }

    func delete(_ document: LibraryDocument) {
        documents.removeAll { $0.id == document.id }
        save()
        Task { await DocumentIndex.shared.removeDocument(document.id) }
    }

    func deleteAll() {
        let ids = documents.map(\.id)
        documents.removeAll()
        save()
        Task {
            for id in ids { await DocumentIndex.shared.removeDocument(id) }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(documents) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
