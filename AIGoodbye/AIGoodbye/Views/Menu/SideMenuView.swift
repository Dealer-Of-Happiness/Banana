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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    @State private var showRenameChatAlert = false
    @State private var renameChatText = ""
    @State private var chatToRename: Conversation?

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
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilitySizeLayout
            } else {
                standardLayout
            }
        }
        // Under the status bar and the leading safe area too, so a landscape
        // phone doesn't show a bare strip beside the Dynamic Island.
        .background(Color(.systemBackground).ignoresSafeArea())
        // VoiceOver's two-finger scrub closes the drawer like the X does.
        .accessibilityAction(.escape) {
            if !isSidebar { appState.toggleSideMenu() }
        }
        .sheet(isPresented: $showNewFolderAlert, onDismiss: { newFolderName = "" }) {
            TextEntrySheet(
                title: "New Folder",
                placeholder: "Folder name",
                actionTitle: "Create"
            ) { name in
                newFolderName = name
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
        // Same pattern as the folder rename below.
        .sheet(isPresented: $showRenameChatAlert, onDismiss: {
            renameChatText = ""
            chatToRename = nil
        }) {
            TextEntrySheet(
                title: "Rename Chat",
                message: "Enter a new name for this chat",
                placeholder: "Chat name",
                actionTitle: "Rename",
                initialText: renameChatText
            ) { name in
                if let chat = chatToRename {
                    appState.conversationManager.renameConversation(chat, to: name)
                }
            }
        }
        .sheet(item: $folderToView) { folder in
                FolderContentsView(
                    folder: folder,
                    conversations: appState.conversationManager.conversations.filter { $0.folderId == folder.id },
                    onSelectChat: { chat in
                        openFromFolder(chat)
                    },
                    onNewChat: {
                        openFromFolder(blankChat(in: folder))
                    },
                    onRemoveFromFolder: { chat in
                        appState.conversationManager.moveConversation(chat, to: nil)
                        appState.objectWillChange.send()
                    },
                    onDeleteChat: { chat in
                        deleteConversation(chat)
                    },
                    onRenameChat: { chat, name in
                        appState.conversationManager.renameConversation(chat, to: name)
                    }
                )
        }
    }

    /// The path a chat picked in a folder sheet has always taken: make it
    /// current (ChatView loads it), close the sheet, and close the drawer.
    private func openFromFolder(_ chat: Conversation) {
        appState.currentConversation = chat
        folderToView = nil
        if !isSidebar { appState.dismissSideMenuAfterSelection() }
    }

    /// A blank chat filed in `folder`: an untitled empty one already there
    /// if there is one (the launch sweep only tidies chats outside
    /// folders, so repeated taps must not stack up blank rows in here),
    /// otherwise a new one.
    private func blankChat(in folder: Folder) -> Conversation {
        let manager = appState.conversationManager
        if let existing = manager.conversations.first(where: {
            $0.folderId == folder.id
                && $0.title == "New Chat"
                && $0.messageCount == 0
                && $0.lastPreview.isEmpty
                && $0.messages.isEmpty
        }) {
            return existing
        }
        return manager.createConversation(folderId: folder.id)
    }

    /// Open the rename alert for a chat. An untitled chat starts with an
    /// empty field rather than the localized "New Chat", which would
    /// otherwise be saved as a real name and stop the automatic title.
    private func beginRename(_ chat: Conversation) {
        chatToRename = chat
        renameChatText = chat.title == "New Chat" ? "" : chat.title
        showRenameChatAlert = true
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

    /// Header and buttons fixed, folders and chats scrolling, Settings
    /// pinned at the bottom.
    private var standardLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
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
    }

    /// At accessibility text sizes the fixed header, buttons and Settings
    /// row no longer fit on the screen, and SwiftUI squeezed every label to
    /// one truncated line ("New...", "Set ti..."). Everything scrolls
    /// together instead, so each label can wrap.
    private var accessibilitySizeLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                Divider()

                actionButtons

                Divider()

                foldersSection

                Divider()
                    .padding(.top, 8)

                recentChatsSection

                Divider()

                settingsButton
            }
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
                    .foregroundStyle(Color.tintedBlue)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            // No ⌘N here: the app's New Chat menu command (AIGoodbyeApp
            // `.commands`) owns it, and a second binding is ambiguous. ⌘F
            // and ⌘, below are bound on these buttons; the drawer stays in
            // the hierarchy while closed (it is only moved off-screen), so
            // they work from the chat too.

            // At accessibility text sizes the pair did not fit on one line
            // and "New Folder" was cut to "New F...". When it does not fit,
            // the two stack and Search gets a labelled row of its own.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    newFolderButton
                    searchButton(labelled: false)
                }
                VStack(spacing: 8) {
                    newFolderButton
                    searchButton(labelled: true)
                }
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

    private var newFolderButton: some View {
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

    /// Icon-only beside New Folder, a labelled row when the two stack.
    private func searchButton(labelled: Bool) -> some View {
        Button {
            showSearch = true
        } label: {
            if labelled {
                Label("Search chats", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(.systemGray6))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                // A minimum, not a fixed 44 x 44: at accessibility sizes the
                // glyph outgrew the frame and the clip shape cut it off.
                Image(systemName: "magnifyingglass")
                    .padding(12)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(Color(.systemGray6))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(Text("Search chats"))
            }
        }
        .keyboardShortcut("f", modifiers: .command)
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
                    .foregroundStyle(.secondary)
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
        .sheet(isPresented: $showRenameFolderAlert, onDismiss: {
            renameFolderName = ""
            folderToRename = nil
        }) {
            TextEntrySheet(
                title: "Rename Folder",
                message: "Enter a new name for this folder",
                placeholder: "Folder name",
                actionTitle: "Rename",
                initialText: renameFolderName
            ) { name in
                if let folder = folderToRename {
                    appState.conversationManager.renameFolder(folder, to: name)
                    appState.objectWillChange.send()
                }
            }
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

            // Still a LazyVStack inside the drawer's one ScrollView (folders
            // and chats scroll together); the age groups are plain headers
            // in it rather than List sections.
            LazyVStack(alignment: .leading, spacing: 4) {
                if appState.conversationManager.conversations.isEmpty {
                    Text("No chats yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                } else {
                    ForEach(RecentChatGroup.sections(of: appState.conversationManager.conversations)) { section in
                        Text(section.group.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.top, 6)
                            .accessibilityAddTraits(.isHeader)

                        ForEach(section.chats) { chat in
                            chatRowButton(chat)
                        }
                    }
                }
            }
        }
    }

    /// One Recent Chats row: opens the chat, long-press for actions, and
    /// drags onto a folder to file it.
    private func chatRowButton(_ chat: Conversation) -> some View {
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
                beginRename(chat)
            } label: {
                Label("Rename", systemImage: "pencil")
            }

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
        // `.draggable` alone: a second `.onDrag` only existed to dim the
        // row, and a cancelled drag left it dimmed for good.
        .draggable(chat.id.uuidString) {
            // Drag preview
            ChatDragPreview(title: chat.displayTitle)
        }
    }

    // MARK: - Settings Button (Liquid Glass Style)

    private var settingsButton: some View {
        Button {
            appState.showSettings = true
        } label: {
            HStack(spacing: 12) {
                // Scales with Dynamic Type: a fixed 18 pt looked tiny beside
                // the accessibility-size "Settings".
                Image(systemName: "gear")
                    .font(.body.weight(.medium))
                    .imageScale(.large)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .accessibilityHidden(true)

                Text("Settings")
                    .font(.body.weight(.medium))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
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
        .keyboardShortcut(",", modifiers: .command)
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
                    .accessibilityHidden(true)

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
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            // At least a full touch target; the row was about 40 pt tall.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
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

// MARK: - Recent chat groups

/// Recent Chats grouped by age, as ChatGPT and Mail do: one undivided list
/// of 200 chats made last week's as hard to find as last year's.
enum RecentChatGroup: Int, CaseIterable {
    case today, yesterday, previousWeek, earlier

    var title: LocalizedStringKey {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previousWeek: return "Previous 7 Days"
        case .earlier: return "Earlier"
        }
    }

    struct ChatSection: Identifiable {
        let group: RecentChatGroup
        let chats: [Conversation]
        var id: RecentChatGroup { group }
    }

    /// The group for a chat last active at `date`. Calendar days, not
    /// 24-hour spans: "Yesterday" is the previous date on the user's own
    /// calendar.
    nonisolated static func group(for date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> RecentChatGroup {
        let startOfToday = calendar.startOfDay(for: now)
        // A clock set back leaves dates in the future: still today.
        if date >= startOfToday { return .today }
        if let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
           date >= startOfYesterday {
            return .yesterday
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday),
           date >= weekAgo {
            return .previousWeek
        }
        return .earlier
    }

    /// Chats bucketed in group order, each bucket keeping the list's own
    /// order (most recent first). Empty groups are left out.
    static func sections(of conversations: [Conversation], now: Date = Date()) -> [ChatSection] {
        let calendar = Calendar.autoupdatingCurrent
        var buckets: [RecentChatGroup: [Conversation]] = [:]
        for conversation in conversations {
            buckets[group(for: conversation.updatedAt, now: now, calendar: calendar), default: []]
                .append(conversation)
        }
        return allCases.compactMap { group in
            guard let chats = buckets[group], !chats.isEmpty else { return nil }
            return ChatSection(group: group, chats: chats)
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
        // No drag-handle glyph: rows are not reorderable (dragging only
        // files a chat into a folder), and the glyph was the same one as
        // the toolbar's Conversations button.
        HStack {
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
                    .accessibilityHidden(true)
            }

            Text(conversation.updatedAt.aigRelative())
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                        let isCurrent = conversation?.folderId == folder.id
                        Button {
                            onMove(folder)
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.yellow)
                                    .accessibilityHidden(true)
                                Text(folder.name)
                                Spacer()
                                if isCurrent {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        // The checkmark is visual; VoiceOver hears "selected".
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
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
    let onNewChat: () -> Void
    let onRemoveFromFolder: (Conversation) -> Void
    let onDeleteChat: (Conversation) -> Void
    let onRenameChat: (Conversation, String) -> Void

    @State private var showDeleteAlert = false
    @State private var chatToDelete: Conversation?
    /// The rename alert lives here, not in SideMenuView: an alert asked for
    /// by the view under this sheet would not appear while it is up.
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var chatToRename: Conversation?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // First, and also in an empty folder: starting a chat that is
                // filed from the outset beats creating it and moving it later.
                Button {
                    onNewChat()
                } label: {
                    Label("New Chat in Folder", systemImage: "plus.bubble")
                }

                if conversations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("This folder is empty")
                            .foregroundStyle(.secondary)
                        Text("Drag chats here or use the context menu to move them")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

                                Text(chat.updatedAt.aigRelative())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button {
                                chatToRename = chat
                                renameText = chat.title == "New Chat" ? "" : chat.title
                                showRenameAlert = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }

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
            .sheet(isPresented: $showRenameAlert, onDismiss: {
                renameText = ""
                chatToRename = nil
            }) {
                TextEntrySheet(
                    title: "Rename Chat",
                    message: "Enter a new name for this chat",
                    placeholder: "Chat name",
                    actionTitle: "Rename",
                    initialText: renameText
                ) { name in
                    if let chat = chatToRename {
                        onRenameChat(chat, name)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    SideMenuView()
        .environmentObject(AppState())
}
