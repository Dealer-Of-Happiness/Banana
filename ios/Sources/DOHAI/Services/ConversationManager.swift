//
//  ConversationManager.swift
//  AI goodbye
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
        try? modelContext?.save()

        conversations.insert(conversation, at: 0)
        return conversation
    }

    func updateConversation(_ conversation: Conversation) {
        conversation.updatedAt = Date()
        try? modelContext?.save()
    }

    func deleteConversation(_ conversation: Conversation) {
        modelContext?.delete(conversation)
        try? modelContext?.save()
        conversations.removeAll { $0.id == conversation.id }
    }

    func getConversations(in folder: Folder? = nil) -> [Conversation] {
        if let folder = folder {
            return conversations.filter { $0.folderId == folder.id }
        }
        return conversations.filter { $0.folderId == nil }
    }

    // MARK: - Message CRUD

    func addMessage(to conversation: Conversation, role: MessageRole, content: String, isVoice: Bool = false) -> Message {
        let message = Message(role: role, content: content, isVoiceMessage: isVoice)
        message.conversation = conversation
        conversation.messages.append(message)
        conversation.updatedAt = Date()

        // Auto-update title from first user message
        if role == .user && conversation.messages.count == 1 {
            conversation.updateTitle(from: content)
        }

        try? modelContext?.save()
        return message
    }

    func deleteMessage(_ message: Message) {
        modelContext?.delete(message)
        try? modelContext?.save()
    }

    // MARK: - Folder CRUD

    func createFolder(name: String) -> Folder {
        let folder = Folder(name: name)
        modelContext?.insert(folder)
        try? modelContext?.save()
        folders.append(folder)
        return folder
    }

    func renameFolder(_ folder: Folder, to name: String) {
        folder.name = name
        try? modelContext?.save()
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
        try? modelContext?.save()
        folders.removeAll { $0.id == folder.id }
    }

    func moveConversation(_ conversation: Conversation, to folder: Folder?) {
        conversation.folderId = folder?.id
        conversation.updatedAt = Date()
        try? modelContext?.save()
    }

    // MARK: - Folder Locking

    func lockFolder(_ folder: Folder, password: String) {
        folder.isLocked = true
        // Store password hash in Keychain
        KeychainHelper.save(key: "folder_\(folder.id.uuidString)", value: password)
        try? modelContext?.save()
    }

    func unlockFolder(_ folder: Folder, password: String) -> Bool {
        let storedPassword = KeychainHelper.load(key: "folder_\(folder.id.uuidString)")
        return storedPassword == password
    }

    func removeLock(from folder: Folder, password: String) -> Bool {
        if unlockFolder(folder, password: password) {
            folder.isLocked = false
            KeychainHelper.delete(key: "folder_\(folder.id.uuidString)")
            try? modelContext?.save()
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

        try? modelContext?.save()

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
