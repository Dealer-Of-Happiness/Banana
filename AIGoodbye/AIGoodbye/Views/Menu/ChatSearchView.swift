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
                    ContentUnavailableView.search(text: query)
                } else {
                    List(hits) { hit in
                        Button {
                            appState.currentConversation = hit.conversation
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
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var hits: [Hit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var results: [Hit] = []
        for conversation in appState.conversationManager.conversations {
            if conversation.title.localizedCaseInsensitiveContains(needle) {
                results.append(Hit(
                    id: conversation.id,
                    conversation: conversation,
                    snippet: conversation.previewText,
                    isTitleMatch: true
                ))
                continue
            }
            if let message = conversation.messages.first(where: { $0.content.localizedCaseInsensitiveContains(needle) }) {
                results.append(Hit(
                    id: conversation.id,
                    conversation: conversation,
                    snippet: Self.excerpt(of: message.content, around: needle),
                    isTitleMatch: false
                ))
            }
        }
        return results
    }

    /// A short window of text around the match, so the user sees context.
    /// Searches the ORIGINAL string: indices from `lowercased()` belong to a
    /// different string and can trap on characters whose case mapping
    /// changes length.
    private static func excerpt(of text: String, around needle: String, window: Int = 70) -> String {
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
