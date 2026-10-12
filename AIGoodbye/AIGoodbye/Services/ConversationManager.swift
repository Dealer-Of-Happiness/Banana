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
    /// Readable so background work (ChatSearchIndex) can open its own
    /// context on the same store; nil until `initialize` succeeds.
    private(set) var modelContainer: ModelContainer?
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

    /// Naming a chat is not activity in it: `updatedAt` stays put, so a
    /// renamed old chat does not jump to the top of Recent Chats.
    func renameConversation(_ conversation: Conversation, to name: String) {
        let trimmed = name
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != conversation.title else { return }
        conversation.title = trimmed
        save()
        // The list holds the same objects, so `conversations` does not
        // change; AppState forwards this to the views that show titles.
        objectWillChange.send()
    }

    func deleteConversation(_ conversation: Conversation) {
        deleteAttachmentFiles(for: conversation)
        // The composer keeps an unsent draft per chat (ChatViewModel); it
        // must not outlive the chat it belongs to.
        UserDefaults.standard.removeObject(forKey: Self.draftKey(for: conversation.id))
        modelContext?.delete(conversation)
        save()
        conversations.removeAll { $0.id == conversation.id }
    }

    /// The UserDefaults key ChatViewModel stores a conversation's draft under.
    nonisolated static func draftKey(for id: UUID) -> String {
        "draft.\(id.uuidString)"
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
    /// Backed up along with the conversations that reference them. They
    /// used to be excluded while the message store was not, so restoring a
    /// phone from a backup brought every chat back with blank image bubbles
    /// and silently document-less document chats. The backup is the user's
    /// own, encrypted, and the Privacy Center says what is in it.
    static let imagesDirectory: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        includeInBackup(directory)
        return directory
    }()

    /// Undo the exclusion earlier versions applied.
    nonisolated static func includeInBackup(_ url: URL) {
        guard (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?
            .isExcludedFromBackup == true else { return }
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try? mutable.setResourceValues(values)
    }

    /// Applied on every launch rather than only at creation: one failed call
    /// must not permanently break the promise the UI makes.
    nonisolated static func excludeFromBackup(_ url: URL) {
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
        let empties = emptyRootConversations()
        guard empties.count > 1 else { return }
        // Keep the most recent one so the user still lands on a blank chat.
        for conversation in empties.dropFirst() {
            deleteConversation(conversation)
        }
    }

    /// The newest untitled, message-less chat outside any folder: the one
    /// New Chat should reuse instead of stacking up identical blank rows.
    func emptyRootConversation() -> Conversation? {
        emptyRootConversations(limit: 1).first
    }

    /// Blank root chats, newest first.
    ///
    /// The candidates come from the stored counters in one SQLite query, so
    /// no chat that has messages gets its messages loaded - this ran over
    /// every conversation at launch and on every New Chat. A
    /// `messages.isEmpty` predicate would be the direct query, but a to-many
    /// `isEmpty` is not a translation SwiftData documents, and getting this
    /// query wrong deletes conversations. So the relationship still has the
    /// final word, for the candidates only.
    ///
    /// Untitled only: a chat the user named, or one that was cleared but
    /// kept its title, is theirs - not a leftover to reuse or sweep.
    private func emptyRootConversations(limit: Int? = nil) -> [Conversation] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { conversation in
                conversation.folderId == nil
                    && conversation.messageCount == 0
                    && conversation.lastPreview == ""
                    && conversation.title == "New Chat"
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        guard let candidates = try? context.fetch(descriptor) else { return [] }
        var empties: [Conversation] = []
        var healed = false
        for conversation in candidates {
            if conversation.messages.isEmpty {
                empties.append(conversation)
                if let limit, empties.count >= limit { break }
            } else {
                // Saved before the counters existed: fill them in, so this
                // chat is never a candidate again.
                conversation.refreshListSummary()
                healed = true
            }
        }
        if healed { save() }
        return empties
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
        // The new message is the newest, so the row summary is just this
        // (the relationship is loaded anyway after the append).
        conversation.lastPreview = Conversation.plainPreview(content)
        conversation.messageCount = conversation.messages.count

        // Title from the first thing the user says, while the chat is still
        // untitled - a chat the user renamed keeps its name.
        if role == .user && conversation.title == "New Chat" {
            conversation.updateTitle(from: Self.titleSource(for: content))
        }

        save()
        resortConversations()
        return message
    }

    /// The text a chat title is made from. Document questions are stored
    /// as "[lease.pdf] Summarize the key terms" (the bubble and exports read
    /// that format), which made the title "[lease.pdf] Summarize the...".
    nonisolated static func titleSource(for content: String) -> String {
        guard let prefix = content.range(of: #"^\[(.+?)\] "#, options: .regularExpression) else {
            return content
        }
        let question = content[prefix.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty { return question }
        // Only a file was sent: its name is the best title there is.
        return String(content[prefix].dropFirst().dropLast(2))
    }

    func deleteMessage(_ message: Message) {
        deleteMessages([message])
    }

    /// Delete many messages with one save: Clear Chat on a long
    /// conversation used to issue one transaction per message and freeze
    /// the app for seconds.
    func deleteMessages(_ messages: [Message]) {
        guard !messages.isEmpty else { return }
        // Each chat's row summary is worked out from the survivors BEFORE
        // deleting: a deleted model must not be read again.
        let doomed: Set<UUID> = Set(messages.map { $0.id })
        var affected: [Conversation] = []
        for message in messages {
            guard let conversation = message.conversation,
                  !affected.contains(where: { $0 === conversation }) else { continue }
            affected.append(conversation)
        }
        for conversation in affected {
            conversation.refreshListSummary(
                from: conversation.messages.filter { !doomed.contains($0.id) }
            )
        }
        for message in messages {
            modelContext?.delete(message)
        }
        save()
    }

    // MARK: - Folder CRUD

    func createFolder(name: String) -> Folder {
        let folder = Folder(name: name)
        modelContext?.insert(folder)
        save()
        folders.append(folder)
        sortFolders()
        return folder
    }

    func renameFolder(_ folder: Folder, to name: String) {
        folder.name = name
        save()
        sortFolders()
    }

    /// The same order at launch, after creating and after renaming: by
    /// name. Folders used to be sorted at launch and appended afterwards.
    private func sortFolders() {
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        // Filing a chat is not activity in it: bumping `updatedAt` here
        // pushed an old chat to the top of Recent Chats.
        conversation.folderId = folder?.id
        save()
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

        // Sweep any orphaned attachment files - the files, never the folder.
        // Removing the folder (created once per process) meant every photo
        // attached until the next launch was silently never written.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: Self.imagesDirectory.path) {
            for name in names {
                try? FileManager.default.removeItem(at: Self.imagesDirectory.appendingPathComponent(name))
            }
        }

        // Unsent drafts are conversation text too.
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("draft.") {
            defaults.removeObject(forKey: key)
        }

        conversations.removeAll()
        folders.removeAll()
    }
}
