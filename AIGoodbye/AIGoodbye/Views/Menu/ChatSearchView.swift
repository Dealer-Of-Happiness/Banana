//
//  ChatSearchView.swift
//  AIGoodbye
//
//  Search every conversation and message, entirely on device.
//

import SwiftUI

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
                                Text(hit.conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
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
                hits = await search(needle)
                isSearching = false
            }
        }
    }

    /// Plain copies of the text to search, so the comparison of every
    /// message in every chat (the slow part) can leave the main actor.
    private struct Haystack: Sendable {
        let id: UUID
        let title: String
        let preview: String
        let messages: [String]
    }

    private func search(_ needle: String) async -> [Hit] {
        let conversations = appState.conversationManager.conversations
        let haystacks = conversations.map { conversation in
            Haystack(
                id: conversation.id,
                title: conversation.title,
                preview: conversation.previewText,
                messages: conversation.messages.map(\.content)
            )
        }
        let matches = await Task.detached(priority: .userInitiated) { () -> [(UUID, String, Bool)] in
            var results: [(UUID, String, Bool)] = []
            for hay in haystacks {
                if Task.isCancelled { break }
                if hay.title.localizedCaseInsensitiveContains(needle) {
                    results.append((hay.id, hay.preview, true))
                    continue
                }
                if let message = hay.messages.first(where: { $0.localizedCaseInsensitiveContains(needle) }) {
                    results.append((hay.id, Self.excerpt(of: message, around: needle), false))
                }
            }
            return results
        }.value
        let byId = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        return matches.compactMap { id, snippet, isTitle in
            guard let conversation = byId[id] else { return nil }
            return Hit(id: id, conversation: conversation, snippet: snippet, isTitleMatch: isTitle)
        }
    }

    /// A short window of text around the match, so the user sees context.
    /// Searches the ORIGINAL string: indices from `lowercased()` belong to a
    /// different string and can trap on characters whose case mapping
    /// changes length.
    nonisolated private static func excerpt(of text: String, around needle: String, window: Int = 70) -> String {
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
