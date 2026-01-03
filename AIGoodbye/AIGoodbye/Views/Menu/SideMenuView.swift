//
//  SideMenuView.swift
//  AIGoodbye
//
//  Side menu with folders and chat organization
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SideMenuView: View {
    @EnvironmentObject var appState: AppState
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var selectedFolder: Folder?
    @State private var showFolderOptions = false
    @State private var showSettings = false
    @State private var draggedConversation: Conversation?
    @State private var targetedFolderId: UUID?
    @State private var showMoveToFolder = false
    @State private var conversationToMove: Conversation?
    @State private var showDeleteConfirmation = false
    @State private var conversationToDelete: Conversation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()

            // New Chat/Folder buttons
            actionButtons

            Divider()

            // Folders section
            foldersSection

            Divider()

            // Recent Chats section
            recentChatsSection

            Spacer()

            Divider()

            // Settings button
            settingsButton
        }
        .background(Color(.systemBackground))
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {
                newFolderName = ""
            }
            Button("Create") {
                createFolder()
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(appState)
            }
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
                    appState.conversationManager.deleteConversation(conversation)
                    if appState.currentConversation?.id == conversation.id {
                        appState.currentConversation = nil
                    }
                }
                conversationToDelete = nil
            }
        } message: {
            Text("This conversation will be permanently deleted.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("AI goodbye")
                .font(.title.bold())
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            Spacer()

            Button {
                appState.toggleSideMenu()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 8) {
            Button {
                appState.createNewConversation()
                appState.toggleSideMenu()
            } label: {
                Label("New Chat", systemImage: "plus.bubble.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.blue.opacity(0.1))
                    .foregroundStyle(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

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
                        onTap: {
                            selectedFolder = folder
                        },
                        onLongPress: {
                            selectedFolder = folder
                            showFolderOptions = true
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
        .confirmationDialog("Folder Options", isPresented: $showFolderOptions, presenting: selectedFolder) { folder in
            Button("Rename") {
                // TODO: Handle rename with alert
            }

            Button("Delete", role: .destructive) {
                appState.conversationManager.deleteFolder(folder, deleteContents: false)
            }

            Button("Cancel", role: .cancel) {}
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

            ScrollView {
                LazyVStack(spacing: 4) {
                    if appState.conversationManager.conversations.isEmpty {
                        Text("No chats yet")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .padding()
                    } else {
                        ForEach(appState.conversationManager.conversations) { chat in
                            ChatRow(conversation: chat, isDragging: draggedConversation?.id == chat.id)
                                .onTapGesture {
                                    appState.currentConversation = chat
                                    appState.toggleSideMenu()
                                }
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

                                    Button(role: .destructive) {
                                        conversationToDelete = chat
                                        showDeleteConfirmation = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .draggable(chat.id.uuidString) {
                                    // Drag preview
                                    ChatDragPreview(title: chat.title)
                                }
                                .onDrag {
                                    draggedConversation = chat
                                    return NSItemProvider(object: chat.id.uuidString as NSString)
                                }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Settings Button

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Label("Settings", systemImage: "gear")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .foregroundStyle(.primary)
    }

    // MARK: - Actions

    private func createFolder() {
        guard !newFolderName.isEmpty else { return }
        // Create folder using ConversationManager
        _ = appState.conversationManager.createFolder(name: newFolderName)
        newFolderName = ""
    }
}

// MARK: - Folder Row

struct FolderRow: View {
    let folder: Folder
    var isDropTarget: Bool = false
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack {
                Image(systemName: isDropTarget ? "folder.fill.badge.plus" : "folder.fill")
                    .foregroundStyle(isDropTarget ? .blue : .yellow)

                Text(folder.name)
                    .foregroundStyle(.primary)

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
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    onLongPress()
                }
        )
    }
}

// MARK: - Chat Row

struct ChatRow: View {
    let conversation: Conversation
    var isDragging: Bool = false

    var body: some View {
        HStack {
            // Drag handle indicator
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title)
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
        .contentShape(Rectangle())
        .opacity(isDragging ? 0.5 : 1.0)
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
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    SideMenuView()
        .environmentObject(AppState())
}
