//
//  AIGoodbyeApp.swift
//  AiGoodbye - aigoodbye.ai
//
//  Say goodbye to monthly subscriptions, sharing your private data,
//  and requiring internet connection.
//
//  v3.0: the app opens straight into chat. Models load lazily; on devices
//  with Apple Intelligence, chatting works instantly with no download.
//

import SwiftUI
import SwiftData
import Combine

@main
struct AIGoodbyeApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("hasAcceptedTerms") private var hasAcceptedTerms = false
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var lock = AppLock.shared

    var body: some Scene {
        WindowGroup {
            LanguageAwareRoot(settings: appState.settings) {
                contentView
            }
            .environmentObject(appState)
            // Presented at the window root so it covers sheets and
            // full-screen covers too (a lock that any open sheet defeats
            // is not a lock).
            .fullScreenCover(isPresented: Binding(
                get: { lock.isLocked },
                set: { _ in }   // dismissed only by a successful unlock
            )) {
                LockScreen()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    // Only on real backgrounding: `.inactive` also fires for
                    // Control Center, banners and the biometric prompt.
                    lock.lockIfNeeded()
                case .active:
                    Task { await lock.unlockOnForeground() }
                default:
                    break
                }
            }
            .task { await lock.unlockOnForeground() }
            .task {
                if hasAcceptedTerms {
                    await appState.initialize()
                }
            }
            .onChange(of: hasAcceptedTerms) { _, accepted in
                if accepted {
                    Task { await appState.initialize() }
                }
            }
            // Share sheet, widgets and Control Center all arrive here.
            .onOpenURL { url in
                appState.handleDeepLink(url)
            }
            .onChange(of: scenePhase) { _, phase in
                // Don't hand shared content to a screen the user can't see:
                // behind the terms wall or the lock it would be consumed and
                // silently dropped into an invisible chat.
                if phase == .active, hasAcceptedTerms, !lock.isLocked {
                    appState.consumeSharedContent()
                }
            }
            .onChange(of: lock.isLocked) { _, locked in
                if !locked, hasAcceptedTerms {
                    appState.consumeSharedContent()
                }
            }
            // Give memory back before the system takes the whole app.
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification
            )) { _ in
                appState.releaseMemory()
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if !hasAcceptedTerms {
            TermsView(hasAcceptedTerms: $hasAcceptedTerms)
        } else {
            MainView()
                // Redacted rather than blurred, and without animation, so the
                // app-switcher snapshot can never catch readable content.
                .redacted(reason: lock.isLocked ? .privacy : [])
                .accessibilityHidden(lock.isLocked)
        }
    }
}

// MARK: - App lock

private struct LockScreen: View {
    @ObservedObject private var lock = AppLock.shared

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThickMaterial)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)

                Text("Your conversations are locked")
                    .font(.headline)

                if let error = lock.lastError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await lock.unlock() }
                } label: {
                    Text("Unlock")
                        .font(.headline)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Language-aware root

/// Applies the in-app language choice to the whole view tree, immediately.
/// The `.id` forces a rebuild on change so localized text re-resolves; the
/// AppleLanguages override in SettingsManager covers the next cold launch.
private struct LanguageAwareRoot<Content: View>: View {
    @ObservedObject var settings: SettingsManager
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if let locale = settings.appLanguage.locale {
                content()
                    .environment(\.locale, locale)
            } else {
                content()
            }
        }
        .id(settings.appLanguage)
    }
}

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    /// Set on creation so App Intents (Siri/Shortcuts) can reach the live
    /// engines instead of building a second copy of everything.
    static weak var shared: AppState?

    @Published var showSideMenu = false
    @Published var currentConversation: Conversation? {
        didSet {
            guard let id = currentConversation?.id else { return }
            UserDefaults.standard.set(id.uuidString, forKey: Self.lastConversationKey)
        }
    }
    @Published var isInitialized = false

    /// Which conversation to reopen on the next launch.
    fileprivate static let lastConversationKey = "lastConversationId"

    // Services
    let settings: SettingsManager
    let engine: ChatEngine
    let conversationManager: ConversationManager

    /// Owned here (not by ChatView) so drafts, pending attachments, and an
    /// in-flight answer survive the language-change UI rebuild.
    let chatViewModel = ChatViewModel()

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Shared with App Intents (Siri/Shortcuts), which can run without a
        // scene and therefore without an AppState.
        self.settings = EngineHost.shared.settings
        self.engine = EngineHost.shared.engine
        self.conversationManager = ConversationManager()

        // Views read child-object state through `appState.…`; forward their
        // changes so those views (e.g. the download progress chip, the
        // sidebar list) update.
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        conversationManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        AppState.shared = self

        // Start recording our own network requests so the Privacy Center can
        // show the user exactly what this app does (and doesn't) send.
        NetworkAudit.begin()
    }

    /// When the last memory warning arrived, so a repeat can escalate.
    private var lastMemoryWarning: Date?

    /// Give back everything re-creatable when the system warns us. Without
    /// this, a multi-gigabyte model plus caches means the app is simply
    /// killed - which, mid-recording or mid-answer, costs the user real work.
    func releaseMemory() {
        chatViewModel.releaseMemory()
        Task { await DocumentIndex.shared.purgeCaches() }
        engine.appleIntelligence.dropSession()

        // A 6 GB phone sends memory warnings routinely while a 1.8 GB model
        // is loading or answering - that is normal, not an emergency. Acting
        // on them at that moment achieved nothing useful (the weights are
        // retained by the running generation anyway) and cost a great deal:
        // every warning threw the session away, so the next turn re-read the
        // whole conversation, and a pair of warnings unloaded the weights,
        // so the next turn also reloaded 1.8 GB. From the user's side the
        // first answer simply never came. So: only ever act while idle.
        guard !engine.mlx.isBusy else {
            lastMemoryWarning = Date()
            return
        }

        // Idle: the key-value cache is the cheap thing to give back.
        engine.mlx.dropSession()

        // Escalate only for a genuinely repeated warning while idle, which
        // means something else on the phone needs the memory more.
        let now = Date()
        if let last = lastMemoryWarning, now.timeIntervalSince(last) < 30 {
            engine.mlx.unload()
        }
        lastMemoryWarning = now
    }

    /// Fast, non-blocking startup: prepare storage, then show the app.
    /// Models load lazily on first use, with progress shown inside the chat.
    func initialize() async {
        guard !isInitialized else { return }
        await conversationManager.initialize()
        // Anything the share extension already handed over is attached to no
        // conversation yet, so the sweep must be told to spare it.
        conversationManager.sweepOrphanedDocuments(
            alsoKeep: Set([chatViewModel.pendingDocumentId].compactMap { $0 })
        )
        conversationManager.sweepOrphanedImages()
        conversationManager.sweepEmptyConversations()
        engine.appleIntelligence.refreshAvailability()

        // Come back to the conversation the user was actually in. Always
        // cold-starting on a blank chat meant re-opening the drawer and
        // hunting for your own conversation on every single launch.
        if currentConversation == nil,
           let lastId = UserDefaults.standard.string(forKey: Self.lastConversationKey),
           let uuid = UUID(uuidString: lastId),
           let restored = conversationManager.conversations.first(where: { $0.id == uuid }) {
            currentConversation = restored
        }
        isInitialized = true

        // Warm up the weights in the background so the first answer is quick.
        //
        // Only the weights - deliberately not a session. A session built here
        // has empty history, and if the restored conversation finished
        // loading a moment later, the first message found a session already
        // waiting and answered as if the conversation had never happened.
        // The first message builds its own session with the right history.
        //
        // Failures are left to that first message too: it retries the load
        // through the normal path and shows the real reason. Recording a
        // failure here turned a transient launch-time memory squeeze into a
        // permanent "Set up your AI model" chip on a phone with the model
        // fully installed.
        // Never in the Simulator: MLX has no Metal device there and aborts
        // the process the moment it touches one, so this warm-up took the
        // whole app down about twenty seconds after every launch with a
        // downloaded model. The chat path already knows this and echoes.
        #if !targetEnvironment(simulator)
        let model = engine.selectedModel
        if model.backend == .mlx && model.isDownloaded {
            Task { [engine] in
                try? await engine.mlx.loadModel(model)
            }
        }
        #endif
    }

    func createNewConversation() {
        // Reuse an empty chat rather than stacking up identical "New Chat /
        // No messages" rows. Tapping New Chat five times used to leave five
        // permanent empty conversations in the sidebar.
        if let current = currentConversation, current.messages.isEmpty {
            return
        }
        if let existingEmpty = conversationManager.conversations.first(where: {
            $0.messages.isEmpty && $0.folderId == nil
        }) {
            currentConversation = existingEmpty
            return
        }
        currentConversation = conversationManager.createConversation()
    }

    // MARK: - Deep links and shared content

    /// Set when another part of the system (widget, Control Center, share
    /// sheet) asked for a specific screen.
    @Published var pendingRoute: Route?

    enum Route: Equatable {
        case newChat
        case voice
        case camera
        case translate
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == SharedInbox.urlScheme else { return }
        switch url.host() {
        case "voice": pendingRoute = .voice
        case "camera": pendingRoute = .camera
        case "translate": pendingRoute = .translate
        case "new": pendingRoute = .newChat
        case "shared": consumeSharedContent()
        default: break
        }
    }

    /// Pick up anything the share extension left for us and drop it into the
    /// composer of a fresh chat.
    func consumeSharedContent() {
        if WidgetLaunchBridge.consumeVoiceRequest() {
            pendingRoute = .voice
        }
        guard let item = SharedInbox.takePending() else { return }

        Task { @MainActor in
            // Switch conversations FIRST: loading a conversation clears the
            // composer, so populating before this point would be wiped.
            createNewConversation()
            showSideMenu = false
            // Let the view observe the change and run loadConversation.
            await Task.yield()

            switch item.kind {
            case .text, .url:
                chatViewModel.inputText = item.text ?? ""
            case .file:
                if let name = item.fileName, let url = SharedInbox.fileURL(named: name) {
                    await chatViewModel.processSharedFile(url, displayName: item.displayName ?? url.lastPathComponent)
                    SharedInbox.cleanUp(fileName: name)
                }
            }
        }
        SharedInbox.sweepStaleFiles()
    }

    func toggleSideMenu() {
        withAnimation(.spring(response: 0.3)) {
            showSideMenu.toggle()
        }
    }
}
