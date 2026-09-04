//
//  Conversation.swift
//  AIGoodbye
//
//  Data models for conversations and messages
//

import Foundation
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
        lastMessage?.content.prefix(100).description ?? L10n.text("No messages")
    }

    /// Title for display: the stored default localizes at render time, so
    /// untitled chats follow the selected app language.
    var displayTitle: String {
        title == "New Chat" ? L10n.text("New Chat") : title
    }

    func updateTitle(from message: String) {
        // Auto-generate title from first user message
        let words = message.split(separator: " ").prefix(6)
        title = words.joined(separator: " ")
        if message.count > title.count {
            title += "..."
        }
    }
}

// MARK: - Message

@Model
final class Message {
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

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

// MARK: - Attachment Type

enum AttachmentType: String, Codable {
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
