//
//  KnowledgeLibraryView.swift
//  AIGoodbye
//
//  Manage the permanent document library the AI can consult in any chat.
//

import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct KnowledgeLibraryView: View {
    @ObservedObject private var library = KnowledgeLibrary.shared
    @State private var showingPicker = false
    @State private var importError: String?
    @State private var isImporting = false
    @State private var showDeleteAll = false

    var body: some View {
        List {
            Section {
                Button {
                    showingPicker = true
                } label: {
                    Label("Add Document", systemImage: "plus.circle")
                }
                .disabled(isImporting)

                if isImporting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading document...")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Documents you add here can be used in every conversation. They are stored on this device only, and the AI reads them without any internet connection.")
            }

            Section {
                if library.documents.isEmpty {
                    Text("No documents yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(library.documents) { document in
                        row(for: document)
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { library.documents[$0] }
                        doomed.forEach(library.delete)
                    }
                }
            } header: {
                Text("Documents")
            } footer: {
                Text("Up to \(KnowledgeLibrary.maxEnabled) documents can be switched on at once, so answers stay fast.")
            }

            if !library.documents.isEmpty {
                Section {
                    Button("Remove All Documents", role: .destructive) {
                        showDeleteAll = true
                    }
                }
            }
        }
        .navigationTitle("Knowledge Library")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            DocumentPickerView { urls in
                showingPicker = false
                Task { await importDocuments(urls) }
            }
        }
        .alert("Couldn't Add Document", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("Remove all documents?", isPresented: $showDeleteAll) {
            Button("Remove All", role: .destructive) { library.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every document in your library will be deleted from this device. This can't be undone.")
        }
    }

    private func row(for document: LibraryDocument) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .foregroundStyle(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(document.name)
                    .lineLimit(1)
                Text(sizeText(for: document))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { document.isEnabled },
                set: { library.setEnabled($0, for: document) }
            ))
            .labelsHidden()
            .disabled(!library.canEnableMore(than: document))
            .accessibilityLabel(Text("Use \(document.name) in chats"))
        }
        .accessibilityElement(children: .combine)
    }

    private func sizeText(for document: LibraryDocument) -> String {
        // String(), not Int: an Int interpolation generates a "%lld" key,
        // which wouldn't match the catalog's "%@" entry.
        let approxPages = String(max(1, document.characterCount / 1800))
        return L10n.text("About \(approxPages) pages")
    }

    // MARK: - Import

    private func importDocuments(_ urls: [URL]) async {
        guard let url = urls.first else { return }
        isImporting = true
        defer { isImporting = false }

        guard url.startAccessingSecurityScopedResource() else {
            importError = L10n.text("This file can't be accessed. Try picking it again.")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 25 * 1024 * 1024 {
            importError = L10n.text("This file is too large to import. The limit is \(ByteCountFormatter.string(fromByteCount: 25 * 1024 * 1024, countStyle: .file)).")
            return
        }

        do {
            let text: String
            if url.pathExtension.lowercased() == "pdf" {
                text = try await Task.detached(priority: .userInitiated) {
                    guard let document = PDFDocument(url: url) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    var full = ""
                    for index in 0..<min(document.pageCount, 300) {
                        if let page = document.page(at: index), let pageText = page.string {
                            full += "[Page \(index + 1)]\n\(pageText)\n\n"
                        }
                    }
                    return full
                }.value
            } else {
                text = try await Task.detached(priority: .userInitiated) {
                    try String(contentsOf: url, encoding: .utf8)
                }.value
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                importError = L10n.text("No readable text was found in \(url.lastPathComponent).")
                return
            }
            await library.add(name: url.lastPathComponent, fullText: trimmed)
        } catch {
            importError = L10n.text("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
