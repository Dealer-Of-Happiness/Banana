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
    ///
    /// Excluded from backup: these are photos the user asked the AI to look
    /// at - medical results, documents, private things - and the app's whole
    /// promise is that they stay on this device.
    static let imagesDirectory: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)
        return directory
    }()

    /// Applied on every launch rather than only at creation: one failed call
    /// must not permanently break the promise the UI makes.
    static func excludeFromBackup(_ url: URL) {
        guard (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?
            .isExcludedFromBackup != true else { return }
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    static func imagePath(for id: UUID) -> URL {
        imagesDirectory.appendingPathComponent("\(id.uuidString).jpg")
    }

    /// Remove leftover empty conversations, keeping at most one. Every tap
    /// of "New Chat" used to create a permanent row whether or not the user
    /// said anything.
    func sweepEmptyConversations() {
        let empties = conversations.filter { $0.messages.isEmpty && $0.folderId == nil }
        guard empties.count > 1 else { return }
        // Keep the most recent one so the user still lands on a blank chat.
        for conversation in empties.sorted(by: { $0.updatedAt > $1.updatedAt }).dropFirst() {
            deleteConversation(conversation)
        }
    }

    /// Delete image files no conversation references anymore - left behind by
    /// Clear Chat in earlier versions, or by an interrupted send.
    func sweepOrphanedImages() {
        let keep = Set(conversations.flatMap { $0.attachedImageIds }.map(\.uuidString))
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: Self.imagesDirectory.path
        ) else { return }
        for name in names where name.hasSuffix(".jpg") {
            let id = String(name.dropLast(4))
            guard !keep.contains(id) else { continue }
            try? FileManager.default.removeItem(
                at: Self.imagesDirectory.appendingPathComponent(name)
            )
        }
    }

    /// Delete this conversation's attachment files so they don't leak forever.
    private func deleteAttachmentFiles(for conversation: Conversation) {
        for imageId in conversation.attachedImageIds {
            try? FileManager.default.removeItem(at: Self.imagePath(for: imageId))
        }
        let docIds = conversation.attachedDocumentIds
        Task {
            for id in docIds { await DocumentIndex.shared.removeDocument(id) }
        }
    }

    /// Delete stored document text that no conversation references anymore
    /// (e.g. left behind by an interrupted import). Called at launch.
    ///
    /// `alsoKeep` carries ids that exist but aren't attached to a
    /// conversation yet - a document the user has picked but not sent, or one
    /// the share extension just handed over. Without it, the sweep races the
    /// share handoff and can delete the file out from under the composer.
    func sweepOrphanedDocuments(alsoKeep: Set<UUID> = []) {
        var keep = Set(conversations.flatMap { $0.attachedDocumentIds })
        // Library documents are permanent and belong to no single chat.
        keep.formUnion(KnowledgeLibrary.shared.documents.map(\.id))
        keep.formUnion(alsoKeep)
        Task { await DocumentIndex.shared.removeDocuments(notIn: keep) }
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
