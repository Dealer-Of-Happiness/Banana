//
//  SideMenuView.swift
//  AIGoodbye
//
//  Side menu with folders and chat organization
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Combine

struct SideMenuView: View {
    /// True when shown beside the chat (regular width) rather than sliding
    /// over it. A sidebar has no close button and stays put after a choice.
    var isSidebar = false

    @EnvironmentObject var appState: AppState
    @ObservedObject private var recordingStore = RecordingStore.shared
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var showSearch = false
    @State private var showRecordings = false
    @State private var exportURL: URL?
    @State private var exportFailed = false
    @State private var draggedConversation: Conversation?
    @State private var targetedFolderId: UUID?
    @State private var showMoveToFolder = false
    @State private var conversationToMove: Conversation?
    @State private var showDeleteConfirmation = false
    @State private var conversationToDelete: Conversation?
    @State private var folderToView: Folder?
    @State private var showRenameFolderAlert = false
    @State private var renameFolderName = ""
    @State private var folderToRename: Folder?
    @State private var folderToDelete: Folder?

    // Pre-compute folder chat counts once - O(n) instead of O(n * m)
    private var folderChatCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for conversation in appState.conversationManager.conversations {
            if let folderId = conversation.folderId {
                counts[folderId, default: 0] += 1
            }
        }
        return counts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()

            // New Chat/Folder buttons
            actionButtons

            Divider()

            // One scroll region for folders + chats, so many folders can
            // never push Recent Chats or Settings off-screen.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    foldersSection

                    Divider()
                        .padding(.top, 8)

                    recentChatsSection
                }
            }

            Divider()

            // Settings button
            settingsButton
        }
        // Under the status bar and the leading safe area too, so a landscape
        // phone doesn't show a bare strip beside the Dynamic Island.
        .background(Color(.systemBackground).ignoresSafeArea())
        // VoiceOver's two-finger scrub closes the drawer like the X does.
        .accessibilityAction(.escape) {
            if !isSidebar { appState.toggleSideMenu() }
        }
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {
                newFolderName = ""
            }
            Button("Create") {
                createFolder()
            }
        }
        .sheet(isPresented: $appState.showSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showSearch) {
            ChatSearchView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showRecordings) {
            RecordingsView()
                .environmentObject(appState)
        }
        .sheet(item: $exportURL) { url in
            ShareSheet(items: [url])
        }
        .alert("Couldn't export this chat", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try again.")
        }
        .sheet(isPresented: $showMoveToFolder) {
            MoveToFolderSheet(
                conversation: conversationToMove,
                folders: appState.conversationManager.folders,
                onMove: { folder in
                    if let conversation = conversationToMove {
                        appState.conversationManager.moveConversation(conversation, to: folder)
                        appState.objectWillChange.send()
                    }
                    showMoveToFolder = false
                    conversationToMove = nil
                },
                onCancel: {
                    showMoveToFolder = false
                    conversationToMove = nil
                }
            )
        }
        .alert("Delete Conversation?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                conversationToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let conversation = conversationToDelete {
                    deleteConversation(conversation)
                }
                conversationToDelete = nil
            }
        } message: {
            Text("This conversation will be permanently deleted.")
        }
        .sheet(item: $folderToView) { folder in
                FolderContentsView(
                    folder: folder,
                    conversations: appState.conversationManager.conversations.filter { $0.folderId == folder.id },
                    onSelectChat: { chat in
                        appState.currentConversation = chat
                        folderToView = nil
                        if !isSidebar { appState.dismissSideMenuAfterSelection() }
                    },
                    onRemoveFromFolder: { chat in
                        appState.conversationManager.moveConversation(chat, to: nil)
                        appState.objectWillChange.send()
                    },
                    onDeleteChat: { chat in
                        deleteConversation(chat)
                    }
                )
        }
    }

    /// Detach the chat screen from a conversation BEFORE deleting it. The
    /// other order let the generation task's finalizer, or one more render
    /// of the message list, touch a model whose row was already gone - a
    /// SwiftData trap a second after the swipe.
    private func deleteConversation(_ conversation: Conversation) {
        Task { @MainActor in
            if appState.currentConversation?.id == conversation.id {
                await appState.chatViewModel.stopGenerationAndWait()
                appState.chatViewModel.loadConversation(nil)
                appState.currentConversation = nil
            }
            appState.conversationManager.deleteConversation(conversation)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("AiGoodbye")
                .font(.title.bold())
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            Spacer()

            if !isSidebar {
                Button {
                    appState.toggleSideMenu()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close menu")
            }
        }
        .padding()
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 8) {
            Button {
                appState.createNewConversation()
                if !isSidebar { appState.dismissSideMenuAfterSelection() }
            } label: {
                Label("New Chat", systemImage: "plus.bubble.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.blue.opacity(0.1))
                    .foregroundStyle(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 8) {
                Button {
                    showNewFolderAlert = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(.systemGray6))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 44, height: 44)
                        .background(Color(.systemGray6))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel(Text("Search chats"))
            }

            Button {
                showRecordings = true
            } label: {
                HStack {
                    Label("Recordings", systemImage: "waveform.badge.mic")
                    Spacer()
                    if !recordingStore.recordings.isEmpty {
                        Text("\(recordingStore.recordings.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.systemGray6))
                .foregroundStyle(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding()
    }

    // MARK: - Folders Section

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Folders")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)

            // Folders list
            if appState.conversationManager.folders.isEmpty {
                Text("No folders yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            } else {
                ForEach(appState.conversationManager.folders) { folder in
                    FolderRow(
                        folder: folder,
                        isDropTarget: targetedFolderId == folder.id,
                        chatCount: folderChatCounts[folder.id, default: 0],
                        onTap: {
                            folderToView = folder
                        },
                        onRename: {
                            folderToRename = folder
                            renameFolderName = folder.name
                            showRenameFolderAlert = true
                        },
                        onDelete: {
                            folderToDelete = folder
                        }
                    )
                    .dropDestination(for: String.self) { items, _ in
                        guard let conversationIdString = items.first,
                              let conversation = appState.conversationManager.conversations.first(where: { $0.id.uuidString == conversationIdString }) else {
                            return false
                        }

                        // Move conversation to folder
                        appState.conversationManager.moveConversation(conversation, to: folder)
                        appState.objectWillChange.send()
                        draggedConversation = nil
                        targetedFolderId = nil
                        return true
                    } isTargeted: { isTargeted in
                        if isTargeted {
                            targetedFolderId = folder.id
                        } else if targetedFolderId == folder.id {
                            targetedFolderId = nil
                        }
                    }
                }
            }
        }
        // Deleting a folder used to be instant and silent; chats confirm,
        // folders should too - and say what happens to the chats inside.
        .confirmationDialog(
            "Delete this folder?",
            isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Folder, Keep Chats") {
                if let folder = folderToDelete {
                    appState.conversationManager.deleteFolder(folder, deleteContents: false)
                }
                folderToDelete = nil
            }
            Button("Delete Folder and Chats", role: .destructive) {
                if let folder = folderToDelete {
                    let doomed = appState.conversationManager.conversations.filter { $0.folderId == folder.id }
                    if doomed.contains(where: { $0.id == appState.currentConversation?.id }) {
                        appState.chatViewModel.loadConversation(nil)
                        appState.currentConversation = nil
                    }
                    appState.conversationManager.deleteFolder(folder, deleteContents: true)
                }
                folderToDelete = nil
            }
            Button("Cancel", role: .cancel) { folderToDelete = nil }
        } message: {
            Text("The chats inside can be kept and moved out of the folder, or deleted with it.")
        }
        .alert("Rename Folder", isPresented: $showRenameFolderAlert) {
            TextField("Folder name", text: $renameFolderName)
            Button("Cancel", role: .cancel) {
                renameFolderName = ""
                folderToRename = nil
            }
            Button("Rename") {
                let renamed = renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let folder = folderToRename, !renamed.isEmpty {
                    appState.conversationManager.renameFolder(folder, to: renamed)
                    appState.objectWillChange.send()
                }
                renameFolderName = ""
                folderToRename = nil
            }
        } message: {
            Text("Enter a new name for this folder")
        }
    }

    // MARK: - Recent Chats Section

    private var recentChatsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Chats")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)

                LazyVStack(spacing: 4) {
                    if appState.conversationManager.conversations.isEmpty {
                        Text("No chats yet")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .padding()
                    } else {
                        ForEach(appState.conversationManager.conversations) { chat in
                            Button {
                                appState.currentConversation = chat
                                if !isSidebar { appState.dismissSideMenuAfterSelection() }
                            } label: {
                                ChatRow(
                                    conversation: chat,
                                    isDragging: draggedConversation?.id == chat.id,
                                    isSelected: isSidebar && appState.currentConversation?.id == chat.id
                                )
                            }
                            .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        conversationToMove = chat
                                        showMoveToFolder = true
                                    } label: {
                                        Label("Move to Folder", systemImage: "folder")
                                    }

                                    if chat.folderId != nil {
                                        Button {
                                            appState.conversationManager.moveConversation(chat, to: nil)
                                            appState.objectWillChange.send()
                                        } label: {
                                            Label("Remove from Folder", systemImage: "folder.badge.minus")
                                        }
                                    }

                                    Divider()

                                    Button {
                                        if let url = ConversationExporter.markdownFile(for: chat) {
                                            exportURL = url
                                        } else {
                                            exportFailed = true
                                        }
                                    } label: {
                                        Label("Export as Markdown", systemImage: "doc.text")
                                    }

                                    Button {
                                        if let url = ConversationExporter.pdfFile(for: chat) {
                                            exportURL = url
                                        } else {
                                            exportFailed = true
                                        }
                                    } label: {
                                        Label("Export as PDF", systemImage: "doc.richtext")
                                    }

                                    Divider()

                                    Button(role: .destructive) {
                                        conversationToDelete = chat
                                        showDeleteConfirmation = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                // `.draggable` alone: a second `.onDrag`
                                // only existed to dim the row, and a
                                // cancelled drag left it dimmed for good.
                                .draggable(chat.id.uuidString) {
                                    // Drag preview
                                    ChatDragPreview(title: chat.displayTitle)
                                }
                        }
                    }
                }
        }
    }

    // MARK: - Settings Button (Liquid Glass Style)

    private var settingsButton: some View {
        Button {
            appState.showSettings = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "gear")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text("Settings")
                    .font(.body.weight(.medium))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.3), .white.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
            )
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func createFolder() {
        newFolderName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newFolderName.isEmpty else { return }
        // Create folder using ConversationManager
        _ = appState.conversationManager.createFolder(name: newFolderName)
        newFolderName = ""
    }
}

// MARK: - Share sheet

/// URL is Identifiable so it can drive `.sheet(item:)`.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Folder Row

struct FolderRow: View {
    let folder: Folder
    var isDropTarget: Bool = false
    var chatCount: Int = 0
    let onTap: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack {
                Image(systemName: isDropTarget ? "folder.fill.badge.plus" : "folder.fill")
                    .foregroundStyle(isDropTarget ? .blue : .yellow)

                Text(folder.name)
                    .foregroundStyle(.primary)

                if chatCount > 0 {
                    Text("\(chatCount)")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue)
                        .clipShape(Capsule())
                }

                Spacer()

                if isDropTarget {
                    Text("Drop here")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isDropTarget ? Color.blue.opacity(0.1) : Color.clear)
            )
            .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        }
        .contextMenu {
            Button {
                onRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Chat Row

struct ChatRow: View {
    let conversation: Conversation
    var isDragging: Bool = false
    /// Highlighted in the sidebar, where the chat it opens is visible
    /// beside it and the list needs to say which one that is.
    var isSelected: Bool = false

    var body: some View {
        HStack {
            // Drag handle indicator
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)

                Text(conversation.previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if conversation.folderId != nil {
                Image(systemName: "folder.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }

            Text(conversation.updatedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .opacity(isDragging ? 0.5 : 1.0)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Chat Drag Preview

struct ChatDragPreview: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.fill")
                .foregroundStyle(.blue)

            Text(title)
                .font(.subheadline)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        )
    }
}

// MARK: - Move to Folder Sheet

struct MoveToFolderSheet: View {
    let conversation: Conversation?
    let folders: [Folder]
    let onMove: (Folder?) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if folders.isEmpty {
                    Text("No folders yet. Create a folder first.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(folders) { folder in
                        Button {
                            onMove(folder)
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.yellow)
                                Text(folder.name)
                                Spacer()
                                if conversation?.folderId == folder.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Move to Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", action: onCancel)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Folder Contents View

struct FolderContentsView: View {
    let folder: Folder
    let conversations: [Conversation]
    let onSelectChat: (Conversation) -> Void
    let onRemoveFromFolder: (Conversation) -> Void
    let onDeleteChat: (Conversation) -> Void

    @State private var showDeleteAlert = false
    @State private var chatToDelete: Conversation?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if conversations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("This folder is empty")
                            .foregroundStyle(.secondary)
                        Text("Drag chats here or use the context menu to move them")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(conversations) { chat in
                        Button {
                            onSelectChat(chat)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chat.displayTitle)
                                    .font(.body)
                                    .foregroundStyle(.primary)

                                Text(chat.previewText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                Text(chat.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contextMenu {
                            Button {
                                onRemoveFromFolder(chat)
                            } label: {
                                Label("Remove from Folder", systemImage: "folder.badge.minus")
                            }

                            Button(role: .destructive) {
                                chatToDelete = chat
                                showDeleteAlert = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle(folder.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "checkmark") {
                        dismiss()
                    }
                }
            }
            .alert("Delete Conversation?", isPresented: $showDeleteAlert) {
                Button("Cancel", role: .cancel) {
                    chatToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let chat = chatToDelete {
                        onDeleteChat(chat)
                    }
                    chatToDelete = nil
                }
            } message: {
                Text("This conversation will be permanently deleted.")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    SideMenuView()
        .environmentObject(AppState())
}
