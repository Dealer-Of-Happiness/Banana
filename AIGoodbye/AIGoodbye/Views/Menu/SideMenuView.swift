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
    @State private var showPasswordPrompt = false
    @State private var passwordInput = ""
    @State private var folderToUnlock: Folder?
    @State private var showSettings = false
    @State private var showSetPasswordSheet = false
    @State private var folderToLock: Folder?
    @State private var showRemoveLockPrompt = false
    @State private var folderToRemoveLock: Folder?
    @State private var draggedConversation: Conversation?
    @State private var targetedFolderId: UUID?

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
        .sheet(isPresented: $showPasswordPrompt) {
            PasswordPromptView(
                folder: folderToUnlock,
                onSuccess: {
                    // Folder unlocked, show contents
                    showPasswordPrompt = false
                },
                onCancel: {
                    showPasswordPrompt = false
                    folderToUnlock = nil
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showSetPasswordSheet) {
            SetPasswordView(
                folder: folderToLock,
                onSuccess: { password in
                    // Lock the folder with password
                    if let folder = folderToLock {
                        folder.isLocked = true
                        folder.password = password
                    }
                    showSetPasswordSheet = false
                    folderToLock = nil
                },
                onCancel: {
                    showSetPasswordSheet = false
                    folderToLock = nil
                }
            )
        }
        .sheet(isPresented: $showRemoveLockPrompt) {
            RemoveLockPromptView(
                folder: folderToRemoveLock,
                onSuccess: {
                    // Remove the lock
                    if let folder = folderToRemoveLock {
                        folder.isLocked = false
                        folder.password = nil
                    }
                    showRemoveLockPrompt = false
                    folderToRemoveLock = nil
                },
                onCancel: {
                    showRemoveLockPrompt = false
                    folderToRemoveLock = nil
                }
            )
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
                        isDropTarget: targetedFolderId == folder.id && !folder.isLocked,
                        onTap: {
                            if folder.isLocked {
                                folderToUnlock = folder
                                showPasswordPrompt = true
                            } else {
                                selectedFolder = folder
                            }
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

                        // Don't allow dropping into locked folders
                        if folder.isLocked {
                            return false
                        }

                        // Move conversation to folder
                        appState.conversationManager.moveConversation(conversation, to: folder)
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

            if folder.isLocked {
                Button("Unlock") {
                    folderToUnlock = folder
                    showPasswordPrompt = true
                }
                Button("Remove Lock") {
                    folderToRemoveLock = folder
                    showRemoveLockPrompt = true
                }
                Button("Change Lock") {
                    folderToLock = folder
                    showSetPasswordSheet = true
                }
            } else {
                Button("Lock") {
                    folderToLock = folder
                    showSetPasswordSheet = true
                }
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

                if folder.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

// MARK: - Password Prompt View

struct PasswordPromptView: View {
    let folder: Folder?
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var showError = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.blue)

                Text("Enter Password")
                    .font(.title2.bold())

                if let folder = folder {
                    Text("Unlock \"\(folder.name)\"")
                        .foregroundStyle(.secondary)
                }

                SecureField("6-digit password", text: $password)
                    .keyboardType(.numberPad)
                    .textContentType(.password)
                    .multilineTextAlignment(.center)
                    .font(.title)
                    .frame(width: 200)
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onChange(of: password) { _, newValue in
                        let filtered = newValue.filter { $0.isNumber }
                        if filtered.count > 6 {
                            password = String(filtered.prefix(6))
                        } else if filtered != newValue {
                            password = filtered
                        }
                    }

                if showError {
                    Text("Incorrect password")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button("Unlock") {
                    // Verify password against folder's stored password
                    if password == folder?.password {
                        onSuccess()
                    } else {
                        showError = true
                        password = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.count != 6)
            }
            .padding()
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

// MARK: - Set Password View

struct SetPasswordView: View {
    let folder: Folder?
    let onSuccess: (String) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "lock.badge.plus")
                    .font(.system(size: 50))
                    .foregroundStyle(.blue)

                Text("Set Password")
                    .font(.title2.bold())

                if let folder = folder {
                    Text("Lock \"\(folder.name)\"")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 16) {
                    SecureField("Enter 6-digit password", text: $password)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                        .multilineTextAlignment(.center)
                        .font(.title3)
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .onChange(of: password) { _, newValue in
                            // Limit to 6 digits only
                            let filtered = newValue.filter { $0.isNumber }
                            if filtered.count > 6 {
                                password = String(filtered.prefix(6))
                            } else if filtered != newValue {
                                password = filtered
                            }
                        }

                    SecureField("Confirm password", text: $confirmPassword)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                        .multilineTextAlignment(.center)
                        .font(.title3)
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .onChange(of: confirmPassword) { _, newValue in
                            // Limit to 6 digits only
                            let filtered = newValue.filter { $0.isNumber }
                            if filtered.count > 6 {
                                confirmPassword = String(filtered.prefix(6))
                            } else if filtered != newValue {
                                confirmPassword = filtered
                            }
                        }
                }
                .frame(width: 250)

                if showError {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button("Lock Folder") {
                    if password.count != 6 {
                        errorMessage = "Password must be exactly 6 digits"
                        showError = true
                    } else if password != confirmPassword {
                        errorMessage = "Passwords don't match"
                        showError = true
                        confirmPassword = ""
                    } else {
                        onSuccess(password)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.count != 6 || confirmPassword.count != 6)
            }
            .padding()
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

// MARK: - Remove Lock Prompt View

struct RemoveLockPromptView: View {
    let folder: Folder?
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var showError = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.orange)

                Text("Remove Lock")
                    .font(.title2.bold())

                if let folder = folder {
                    Text("Enter password to remove lock from \"\(folder.name)\"")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                SecureField("6-digit password", text: $password)
                    .keyboardType(.numberPad)
                    .textContentType(.password)
                    .multilineTextAlignment(.center)
                    .font(.title)
                    .frame(width: 200)
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onChange(of: password) { _, newValue in
                        let filtered = newValue.filter { $0.isNumber }
                        if filtered.count > 6 {
                            password = String(filtered.prefix(6))
                        } else if filtered != newValue {
                            password = filtered
                        }
                    }

                if showError {
                    Text("Incorrect password")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button("Remove Lock") {
                    // Verify password against folder's stored password
                    if password == folder?.password {
                        onSuccess()
                    } else {
                        showError = true
                        password = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(password.count != 6)
            }
            .padding()
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
