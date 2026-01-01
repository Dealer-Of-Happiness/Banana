//
//  SideMenuView.swift
//  DOH AI
//
//  Side menu with folders and chat organization
//

import SwiftUI
import SwiftData

struct SideMenuView: View {
    @EnvironmentObject var appState: AppState
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var selectedFolder: Folder?
    @State private var showFolderOptions = false
    @State private var showPasswordPrompt = false
    @State private var passwordInput = ""
    @State private var folderToUnlock: Folder?

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
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("DOH AI")
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

            // Sample folders - in real app, fetch from SwiftData
            ForEach(sampleFolders) { folder in
                FolderRow(
                    folder: folder,
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
            }
        }
        .confirmationDialog("Folder Options", isPresented: $showFolderOptions, presenting: selectedFolder) { folder in
            Button("Rename") {
                // Handle rename
            }

            if folder.isLocked {
                Button("Unlock") {
                    folderToUnlock = folder
                    showPasswordPrompt = true
                }
                Button("Remove Lock") {
                    // Handle remove lock
                }
                Button("Change Lock") {
                    // Handle change lock
                }
            } else {
                Button("Lock") {
                    // Handle add lock
                }
            }

            Button("Delete", role: .destructive) {
                // Handle delete
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
                    ForEach(sampleChats) { chat in
                        ChatRow(conversation: chat)
                            .onTapGesture {
                                appState.currentConversation = chat
                                appState.toggleSideMenu()
                            }
                    }
                }
            }
        }
    }

    // MARK: - Settings Button

    private var settingsButton: some View {
        NavigationLink {
            SettingsView()
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
        // Create folder in SwiftData
        newFolderName = ""
    }

    // MARK: - Sample Data

    private var sampleFolders: [Folder] {
        [
            Folder(name: "Work", isLocked: true),
            Folder(name: "Personal", isLocked: false),
            Folder(name: "Research", isLocked: false)
        ]
    }

    private var sampleChats: [Conversation] {
        [
            Conversation(title: "Chat about recipes"),
            Conversation(title: "Photo analysis - car"),
            Conversation(title: "Meeting notes review"),
            Conversation(title: "Voice chat 12/15")
        ]
    }
}

// MARK: - Folder Row

struct FolderRow: View {
    let folder: Folder
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.yellow)

                Text(folder.name)
                    .foregroundStyle(.primary)

                if folder.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
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

    var body: some View {
        HStack {
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

            Text(conversation.updatedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
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

                if showError {
                    Text("Incorrect password")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button("Unlock") {
                    // Verify password
                    if password == "123456" { // Replace with actual verification
                        onSuccess()
                    } else {
                        showError = true
                        password = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.count < 6)
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
