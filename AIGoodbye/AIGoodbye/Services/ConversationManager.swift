//
//  ConversationManager.swift
//  AIGoodbye
//
//  Manages conversations and folders with SwiftData
//

import Foundation
import SwiftData
import Combine

@MainActor
class ConversationManager: ObservableObject {
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    @Published var conversations: [Conversation] = []
    @Published var folders: [Folder] = []
    @Published var lastSaveError: String?

    // MARK: - Private Helpers

    /// Safely save the model context with error logging
    private func saveContext(operation: String = "save") {
        do {
            try modelContext?.save()
        } catch {
            let errorMessage = "[ConversationManager] Failed to \(operation): \(error.localizedDescription)"
            print(errorMessage)
            lastSaveError = errorMessage
        }
    }

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

    // MARK: - Conversation CRUD

    func createConversation(title: String = "New Chat", folderId: UUID? = nil) -> Conversation {
        let conversation = Conversation(title: title, folderId: folderId)

        modelContext?.insert(conversation)
        saveContext()

        conversations.insert(conversation, at: 0)
        return conversation
    }

    func updateConversation(_ conversation: Conversation) {
        conversation.updatedAt = Date()
        saveContext()
    }

    func deleteConversation(_ conversation: Conversation) {
        modelContext?.delete(conversation)
        saveContext()
        conversations.removeAll { $0.id == conversation.id }
    }

    func getConversations(in folder: Folder? = nil) -> [Conversation] {
        if let folder = folder {
            return conversations.filter { $0.folderId == folder.id }
        }
        return conversations.filter { $0.folderId == nil }
    }

    // MARK: - Message CRUD

    func addMessage(
        to conversation: Conversation,
        role: MessageRole,
        content: String,
        isVoice: Bool = false,
        attachmentType: AttachmentType? = nil,
        attachmentId: UUID? = nil
    ) -> Message {
        let message = Message(
            role: role,
            content: content,
            isVoiceMessage: isVoice,
            attachmentType: attachmentType,
            attachmentId: attachmentId
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

        saveContext()
        return message
    }

    func deleteMessage(_ message: Message) {
        modelContext?.delete(message)
        saveContext()
    }

    // MARK: - Folder CRUD

    func createFolder(name: String) -> Folder {
        let folder = Folder(name: name)
        modelContext?.insert(folder)
        saveContext()
        folders.append(folder)
        return folder
    }

    func renameFolder(_ folder: Folder, to name: String) {
        folder.name = name
        saveContext()
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

        modelContext?.delete(folder)
        saveContext()
        folders.removeAll { $0.id == folder.id }
    }

    func moveConversation(_ conversation: Conversation, to folder: Folder?) {
        conversation.folderId = folder?.id
        conversation.updatedAt = Date()
        saveContext()
    }

    // MARK: - Folder Locking

    func lockFolder(_ folder: Folder, password: String) {
        folder.isLocked = true
        // Store password hash in Keychain
        KeychainHelper.save(key: "folder_\(folder.id.uuidString)", value: password)
        saveContext()
    }

    func unlockFolder(_ folder: Folder, password: String) -> Bool {
        let storedPassword = KeychainHelper.load(key: "folder_\(folder.id.uuidString)")
        return storedPassword == password
    }

    func removeLock(from folder: Folder, password: String) -> Bool {
        if unlockFolder(folder, password: password) {
            folder.isLocked = false
            KeychainHelper.delete(key: "folder_\(folder.id.uuidString)")
            saveContext()
            return true
        }
        return false
    }

    func changePassword(for folder: Folder, oldPassword: String, newPassword: String) -> Bool {
        if unlockFolder(folder, password: oldPassword) {
            KeychainHelper.save(key: "folder_\(folder.id.uuidString)", value: newPassword)
            return true
        }
        return false
    }

    // MARK: - Clear All Data

    func clearAllData() {
        // Delete all conversations
        for conversation in conversations {
            modelContext?.delete(conversation)
        }

        // Delete all folders
        for folder in folders {
            modelContext?.delete(folder)
        }

        saveContext()

        conversations.removeAll()
        folders.removeAll()
    }

    // MARK: - Search

    func searchConversations(query: String) -> [Conversation] {
        let lowercased = query.lowercased()
        return conversations.filter { conversation in
            conversation.title.lowercased().contains(lowercased) ||
            conversation.messages.contains { $0.content.lowercased().contains(lowercased) }
        }
    }
}
