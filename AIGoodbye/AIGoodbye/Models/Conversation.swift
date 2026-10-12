//
//  Conversation.swift
//  AIGoodbye
//
//  Data models for conversations and messages
//

import Foundation
import NaturalLanguage
import SwiftData

// MARK: - Conversation

@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var folderId: UUID?

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message] = []

    // Attached documents/images
    var attachedDocumentIds: [UUID] = []
    var attachedImageIds: [UUID] = []

    /// What a list row shows, kept current by ConversationManager whenever
    /// messages are added or deleted. Rows used to read `messages` to find
    /// the newest one, which loaded every message of every visible chat.
    /// Additive with defaults, so existing stores migrate on their own; a
    /// row saved before these existed reads "" / 0 until `previewText` (or
    /// the empty-chat lookup) fills them in once.
    var lastPreview: String = ""
    var messageCount: Int = 0

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        folderId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.folderId = folderId
    }

    var lastMessage: Message? {
        // Use max(by:) instead of sort().last - O(n) vs O(n log n)
        messages.max(by: { $0.timestamp < $1.timestamp })
    }

    var previewText: String {
        if messageCount == 0 && lastPreview.isEmpty {
            // Genuinely empty, or saved before the summary existed. Look
            // once: a chat with messages comes out with a non-zero count and
            // never takes this path again; an empty one finds an empty,
            // already-loaded relationship and writes nothing.
            refreshListSummary()
        }
        return messageCount == 0 ? L10n.text("No messages") : lastPreview
    }

    /// Recompute the list summary from `remaining` (by default the stored
    /// messages). Pass the survivors when deleting, so a message that is
    /// about to be deleted is never read afterwards. Writes only what
    /// changed, so rows are not redrawn for nothing.
    func refreshListSummary(from remaining: [Message]? = nil) {
        let source = remaining ?? messages
        let newest = source.max(by: { $0.timestamp < $1.timestamp })
        let preview = newest.map { Self.plainPreview($0.content) } ?? ""
        if lastPreview != preview { lastPreview = preview }
        if messageCount != source.count { messageCount = source.count }
    }

    /// One line of readable text for list rows: answers are Markdown, and
    /// the sidebar used to show "**Key terms**" and "## Summary" verbatim.
    nonisolated static func plainPreview(_ markdown: String) -> String {
        var lines: [String] = []
        for rawLine in markdown.prefix(400).split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // Headings, bullets, numbered lists, block quotes.
            while let first = line.first, "#>-*+ ".contains(first) {
                line.removeFirst()
            }
            if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                line.removeSubrange(match)
            }
            // Emphasis and code markers.
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            line = line.replacingOccurrences(of: #"(?<!\w)[*_](?=\S)|(?<=\S)[*_](?!\w)"#, with: "", options: .regularExpression)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
            if lines.joined(separator: " ").count >= 100 { break }
        }
        return String(lines.joined(separator: " ").prefix(100))
    }

    /// Title for display: the stored default localizes at render time, so
    /// untitled chats follow the selected app language.
    var displayTitle: String {
        title == "New Chat" ? L10n.text("New Chat") : title
    }

    func updateTitle(from message: String) {
        title = Self.title(from: message)
    }

    /// A short title from the first message: about six words, one line.
    /// Word boundaries come from the tokenizer, not from spaces - Chinese
    /// and Japanese have none, and an 800-character question used to become
    /// an 800-character title.
    nonisolated static func title(from message: String) -> String {
        let oneLine = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return "New Chat" }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = oneLine
        var end = oneLine.startIndex
        var words = 0
        tokenizer.enumerateTokens(in: oneLine.startIndex..<oneLine.endIndex) { range, _ in
            words += 1
            end = range.upperBound
            return words < 6
        }
        var candidate = String(oneLine[oneLine.startIndex..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty || candidate.count > 40 {
            candidate = String(oneLine.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if candidate.count < oneLine.count {
            candidate += "..."
        }
        return candidate
    }
}

// MARK: - Message

/// Deliberately `nonisolated` (like AppLanguage), and so are the two enums
/// it stores: chat search reads messages on a background ModelActor
/// (ChatSearchIndex), and under the target's main-actor default isolation
/// an unmarked model - and the Codable conformances of its enums - could
/// only be read on the main thread. @Model already makes it Sendable.
@Model
nonisolated final class Message {
    @Attribute(.unique) var id: UUID
    var role: MessageRole
    var content: String
    var timestamp: Date
    var isVoiceMessage: Bool
    var attachmentType: AttachmentType?
    var attachmentId: UUID?

    /// Full prompt sent to the model when it differs from the displayed text
    /// (e.g. document questions show "[Document: name]" but send the extracted
    /// text). Optional and additive, so existing chats migrate automatically.
    var hiddenContext: String?

    var conversation: Conversation?

    /// What the AI should see for this message.
    var modelFacingContent: String { hiddenContext ?? content }

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        isVoiceMessage: Bool = false,
        attachmentType: AttachmentType? = nil,
        attachmentId: UUID? = nil,
        hiddenContext: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isVoiceMessage = isVoiceMessage
        self.attachmentType = attachmentType
        self.attachmentId = attachmentId
        self.hiddenContext = hiddenContext
    }
}

// MARK: - Message Role

nonisolated enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

// MARK: - Attachment Type

nonisolated enum AttachmentType: String, Codable {
    case document
    case image
    case voice
}

// MARK: - Folder

@Model
final class Folder {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var isLocked: Bool
    var password: String? // For demo - in production use Keychain

    init(
        id: UUID = UUID(),
        name: String,
        isLocked: Bool = false,
        password: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.isLocked = isLocked
        self.password = password
    }
}

// MARK: - Document

@Model
final class Document {
    @Attribute(.unique) var id: UUID
    var name: String
    var type: DocumentType
    var size: Int
    var addedAt: Date
    var chunks: [String] = []

    init(
        id: UUID = UUID(),
        name: String,
        type: DocumentType,
        size: Int
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.size = size
        self.addedAt = Date()
    }
}

enum DocumentType: String, Codable {
    case pdf
    case docx
    case txt
    case md
}

// MARK: - Analyzed Image

@Model
final class AnalyzedImage {
    @Attribute(.unique) var id: UUID
    var imagePath: String
    var analysisResult: String?
    var addedAt: Date

    init(
        id: UUID = UUID(),
        imagePath: String
    ) {
        self.id = id
        self.imagePath = imagePath
        self.addedAt = Date()
    }
}
