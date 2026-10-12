//
//  ChatSearchView.swift
//  AIGoodbye
//
//  Search every conversation and message, entirely on device.
//

import SwiftUI
import SwiftData

struct ChatSearchView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Results are computed in a debounced task, not in `body`. As a computed
    /// property this scanned every message of every conversation TWICE per
    /// keystroke (once for `isEmpty`, once for the List), on the main thread,
    /// faulting the whole store into memory each time.
    @State private var hits: [Hit] = []
    @State private var isSearching = false
    /// Made on first use and kept while the sheet is open, so each
    /// keystroke reuses one background context.
    @State private var cachedIndex: ChatSearchIndex?

    private struct Hit: Identifiable {
        let id: UUID
        let conversation: Conversation
        let snippet: String
        let isTitleMatch: Bool
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView(
                        L10n.text("Search your chats"),
                        systemImage: "magnifyingglass",
                        description: Text("Find any message or conversation. Nothing is sent anywhere.")
                    )
                } else if hits.isEmpty {
                    if isSearching {
                        ProgressView()
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    List(hits) { hit in
                        Button {
                            appState.currentConversation = hit.conversation
                            // Close the side menu too, or the user lands back
                            // on the drawer with their chat hidden behind it.
                            appState.showSideMenu = false
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.conversation.displayTitle)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(hit.snippet)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(hit.conversation.updatedAt.aigRelative())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            // `.automatic`, not pinned to the navigation bar drawer: on
            // iPhone Duo the bar can be vertical, and the system places the
            // field where it fits.
            .searchable(text: $query, placement: .automatic, prompt: Text("Search chats"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .task(id: query) {
                let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !needle.isEmpty else {
                    hits = []
                    isSearching = false
                    return
                }
                isSearching = true
                // Let typing settle before scanning everything.
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                let found = await search(needle)
                // A newer keystroke owns the results now.
                guard !Task.isCancelled else { return }
                hits = found
                isSearching = false
            }
        }
    }

    /// The matching itself runs in SQLite on a background context
    /// (ChatSearchIndex): building plain copies of every message on the
    /// main actor first - the previous approach - loaded the whole store
    /// into memory on each keystroke and was the slow part. Only the ids
    /// of the hits come back here, to be matched to the list's objects.
    private func search(_ needle: String) async -> [Hit] {
        let manager = appState.conversationManager
        guard let container = manager.modelContainer else { return [] }
        let searchIndex = await makeSearchIndex(for: container)

        // Built here, not in the actor: the key paths belong to the models'
        // own isolation. `localizedStandardContains` is what the Search
        // field in Files and Mail does - case and diacritic insensitive.
        let titles = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.title.localizedStandardContains(needle) }
        )
        var messages = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.content.localizedStandardContains(needle) },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        // Enough for any realistic history; one chat with thousands of
        // matches must not hold every other chat's hit hostage.
        messages.fetchLimit = 2_000

        let found = await searchIndex.search(needle: needle, titles: titles, messages: messages)
        let byConversation = Dictionary(found.map { ($0.conversationID, $0) }, uniquingKeysWith: { first, _ in first })
        // Back to the main context's objects, in the list's own order (most
        // recent first), as before.
        return manager.conversations.compactMap { conversation in
            guard let match = byConversation[conversation.persistentModelID] else { return nil }
            return Hit(
                id: conversation.id,
                conversation: conversation,
                snippet: match.snippet ?? conversation.previewText,
                isTitleMatch: match.snippet == nil
            )
        }
    }

    /// The background index, created off the main thread: a ModelActor's
    /// context made on the main thread can end up running its work there,
    /// which is the very thing this is for avoiding.
    private func makeSearchIndex(for container: ModelContainer) async -> ChatSearchIndex {
        if let cachedIndex { return cachedIndex }
        let created = await Task.detached(priority: .userInitiated) {
            ChatSearchIndex(modelContainer: container)
        }.value
        cachedIndex = created
        return created
    }

    /// A short window of text around the match, so the user sees context.
    /// Searches the ORIGINAL string: indices from `lowercased()` belong to a
    /// different string and can trap on characters whose case mapping
    /// changes length.
    nonisolated static func excerpt(of text: String, around needle: String, window: Int = 70) -> String {
        guard let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(text.prefix(120))
        }
        let start = text.index(range.lowerBound, offsetBy: -window, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: window, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > text.startIndex { snippet = "..." + snippet }
        if end < text.endIndex { snippet += "..." }
        return snippet
    }
}

// MARK: - Background search

/// One search result as plain values. Model objects belong to the context
/// that fetched them and never cross to the main actor.
nonisolated struct ChatSearchMatch: Sendable {
    let conversationID: PersistentIdentifier
    /// Text around the first match in a message; nil for a title match
    /// (the row shows the chat's preview instead).
    let snippet: String?
}

/// Runs chat search on its own context over the app's store, so SQLite
/// does the matching and only hits are ever loaded.
@ModelActor
actor ChatSearchIndex {
    func search(
        needle: String,
        titles: FetchDescriptor<Conversation>,
        messages: FetchDescriptor<Message>
    ) -> [ChatSearchMatch] {
        var results: [ChatSearchMatch] = []
        var seen = Set<PersistentIdentifier>()

        // Identifiers only: a title match needs nothing else from the row.
        if let ids = try? modelContext.fetchIdentifiers(titles) {
            for id in ids where seen.insert(id).inserted {
                results.append(ChatSearchMatch(conversationID: id, snippet: nil))
            }
        }

        guard !Task.isCancelled, let matches = try? modelContext.fetch(messages) else { return results }
        // Newest first, so each chat's snippet comes from its latest match.
        for message in matches {
            if Task.isCancelled { break }
            guard let conversationID = message.conversation?.persistentModelID,
                  seen.insert(conversationID).inserted else { continue }
            results.append(ChatSearchMatch(
                conversationID: conversationID,
                snippet: ChatSearchView.excerpt(of: message.content, around: needle)
            ))
        }
        return results
    }
}
