//
//  ConversationManager.swift
//  AIGoodbye
//
//  Manages conversations and folders with SwiftData.
//
//  v3.0.1: storage failures are surfaced instead of swallowed, deleting
//  conversations also deletes their attachment files, folder passwords are
//  stored as hashes, and the sidebar ordering stays fresh.
//

import Foundation
import SwiftData
import Combine
import CryptoKit

@MainActor
class ConversationManager: ObservableObject {
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    @Published var conversations: [Conversation] = []
    @Published var folders: [Folder] = []

    /// Set when the persistent store failed to open: the app still runs, but
    /// nothing will be saved. The UI shows a warning when this is non-nil.
    @Published private(set) var storageError: String?

    // MARK: - Initialization

    func initialize() async {
        do {
            let schema = Schema([
                Conversation.self,
                Message.self,
                Folder.self,
                Document.self,
                AnalyzedImage.self
            ])

            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true
            )

            modelContainer = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )

            modelContext = modelContainer?.mainContext

            await loadData()
        } catch {
            print("Failed to initialize SwiftData: \(error)")
            storageError = L10n.text("Conversations can't be saved right now. Restart the app; if this keeps happening, free up storage space.")
        }
    }

    /// Save, surfacing failures instead of silently dropping data.
    private func save() {
        guard let context = modelContext else { return }
        do {
            try context.save()
            if storageError != nil { storageError = nil }
        } catch {
            print("SwiftData save failed: \(error)")
            storageError = L10n.text("Conversations can't be saved right now. Restart the app; if this keeps happening, free up storage space.")
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        guard let context = modelContext else { return }

        // Load conversations
        let conversationDescriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        conversations = (try? context.fetch(conversationDescriptor)) ?? []

        // Load folders
        let folderDescriptor = FetchDescriptor<Folder>(
            sortBy: [SortDescriptor(\.name)]
        )
        folders = (try? context.fetch(folderDescriptor)) ?? []
    }

    /// Keep the sidebar ordered by recency as conversations change.
    private func resortConversations() {
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Conversation CRUD

    func createConversation(title: String = "New Chat", folderId: UUID? = nil) -> Conversation {
        let conversation = Conversation(title: title, folderId: folderId)

        modelContext?.insert(conversation)
        save()

        conversations.insert(conversation, at: 0)
        return conversation
    }

    func updateConversation(_ conversation: Conversation) {
        conversation.updatedAt = Date()
        save()
        resortConversations()
    }

    func deleteConversation(_ conversation: Conversation) {
        deleteAttachmentFiles(for: conversation)
        modelContext?.delete(conversation)
        save()
        conversations.removeAll { $0.id == conversation.id }
    }

    func getConversations(in folder: Folder? = nil) -> [Conversation] {
        if let folder = folder {
            return conversations.filter { $0.folderId == folder.id }
        }
        return conversations.filter { $0.folderId == nil }
    }

    // MARK: - Attachment files

    /// Directory holding attached images (Documents/images/<uuid>.jpg).
    static var imagesDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("images", isDirectory: true)
    }

    static func imagePath(for id: UUID) -> URL {
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        return imagesDirectory.appendingPathComponent("\(id.uuidString).jpg")
    }

    /// Delete this conversation's attachment files so they don't leak forever.
    private func deleteAttachmentFiles(for conversation: Conversation) {
        for imageId in conversation.attachedImageIds {
            try? FileManager.default.removeItem(at: Self.imagePath(for: imageId))
        }
        for docId in conversation.attachedDocumentIds {
            DocumentIndex.shared.removeDocument(docId)
        }
    }

    // MARK: - Message CRUD

    func addMessage(
        to conversation: Conversation,
        role: MessageRole,
        content: String,
        isVoice: Bool = false,
        attachmentType: AttachmentType? = nil,
        attachmentId: UUID? = nil,
        hiddenContext: String? = nil
    ) -> Message {
        let message = Message(
            role: role,
            content: content,
            isVoiceMessage: isVoice,
            attachmentType: attachmentType,
            attachmentId: attachmentId,
            hiddenContext: hiddenContext
        )
        message.conversation = conversation
        conversation.messages.append(message)
        conversation.updatedAt = Date()

        // Auto-update title from first user message
        if role == .user && conversation.messages.count == 1 {
            // Don't include "[Image attached]" prefix in title
            let titleContent = content.replacingOccurrences(of: "[Image attached] ", with: "")
            conversation.updateTitle(from: titleContent)
        }

        save()
        resortConversations()
        return message
    }

    func deleteMessage(_ message: Message) {
        modelContext?.delete(message)
        save()
    }

    // MARK: - Folder CRUD

    func createFolder(name: String) -> Folder {
        let folder = Folder(name: name)
        modelContext?.insert(folder)
        save()
        folders.append(folder)
        return folder
    }

    func renameFolder(_ folder: Folder, to name: String) {
        folder.name = name
        save()
    }

    func deleteFolder(_ folder: Folder, deleteContents: Bool = false) {
        if deleteContents {
            // Delete all conversations in folder
            let folderConversations = conversations.filter { $0.folderId == folder.id }
            for conversation in folderConversations {
                deleteConversation(conversation)
            }
        } else {
            // Move conversations to root
            for conversation in conversations where conversation.folderId == folder.id {
                conversation.folderId = nil
            }
        }

        KeychainHelper.delete(key: "folder_\(folder.id.uuidString)")
        modelContext?.delete(folder)
        save()
        folders.removeAll { $0.id == folder.id }
    }

    func moveConversation(_ conversation: Conversation, to folder: Folder?) {
        conversation.folderId = folder?.id
        conversation.updatedAt = Date()
        save()
        resortConversations()
    }

    // MARK: - Folder Locking

    private func passwordHash(_ password: String) -> String {
        let digest = SHA256.hash(data: Data(password.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Locks the folder. Returns false (and does NOT lock) if the credential
    /// could not be stored — otherwise the folder would be locked forever.
    @discardableResult
    func lockFolder(_ folder: Folder, password: String) -> Bool {
        guard KeychainHelper.save(key: "folder_\(folder.id.uuidString)", value: passwordHash(password)) else {
            return false
        }
        folder.isLocked = true
        save()
        return true
    }

    func unlockFolder(_ folder: Folder, password: String) -> Bool {
        guard let stored = KeychainHelper.load(key: "folder_\(folder.id.uuidString)") else {
            return false
        }
        if stored == passwordHash(password) { return true }
        // Older versions stored the raw password; accept it once and upgrade.
        if stored == password {
            _ = KeychainHelper.save(key: "folder_\(folder.id.uuidString)", value: passwordHash(password))
            return true
        }
        return false
    }

    func removeLock(from folder: Folder, password: String) -> Bool {
        if unlockFolder(folder, password: password) {
            folder.isLocked = false
            KeychainHelper.delete(key: "folder_\(folder.id.uuidString)")
            save()
            return true
        }
        return false
    }

    func changePassword(for folder: Folder, oldPassword: String, newPassword: String) -> Bool {
        if unlockFolder(folder, password: oldPassword) {
            return KeychainHelper.save(key: "folder_\(folder.id.uuidString)", value: passwordHash(newPassword))
        }
        return false
    }

    // MARK: - Clear All Data

    func clearAllData() {
        // Delete all conversations (and their attachment files)
        for conversation in conversations {
            deleteAttachmentFiles(for: conversation)
            modelContext?.delete(conversation)
        }

        // Delete all folders (and their lock credentials)
        for folder in folders {
            KeychainHelper.delete(key: "folder_\(folder.id.uuidString)")
            modelContext?.delete(folder)
        }

        save()

        // Sweep any orphaned attachment files.
        try? FileManager.default.removeItem(at: Self.imagesDirectory)

        conversations.removeAll()
        folders.removeAll()
    }
}
