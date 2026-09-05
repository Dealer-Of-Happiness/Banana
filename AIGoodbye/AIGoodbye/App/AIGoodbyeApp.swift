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

    var body: some Scene {
        WindowGroup {
            LanguageAwareRoot(settings: appState.settings) {
                contentView
            }
            .environmentObject(appState)
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
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if !hasAcceptedTerms {
            TermsView(hasAcceptedTerms: $hasAcceptedTerms)
        } else {
            MainView()
        }
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
    @Published var currentConversation: Conversation?
    @Published var isInitialized = false

    // Services
    let settings: SettingsManager
    let engine: ChatEngine
    let conversationManager: ConversationManager

    /// Owned here (not by ChatView) so drafts, pending attachments, and an
    /// in-flight answer survive the language-change UI rebuild.
    let chatViewModel = ChatViewModel()

    private var cancellables = Set<AnyCancellable>()

    init() {
        let settings = SettingsManager()
        self.settings = settings
        self.engine = ChatEngine(settings: settings)
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
    }

    /// Fast, non-blocking startup: prepare storage, then show the app.
    /// Models load lazily on first use, with progress shown inside the chat.
    func initialize() async {
        guard !isInitialized else { return }
        await conversationManager.initialize()
        engine.appleIntelligence.refreshAvailability()
        isInitialized = true

        // Warm up a ready engine in the background so the first answer is quick.
        // Never blocks the UI and never surfaces launch errors.
        let model = engine.selectedModel
        if model.backend == .appleIntelligence && engine.appleIntelligence.isAvailable {
            try? await engine.startConversation(model: model, history: [])
        } else if model.backend == .mlx && model.isDownloaded {
            Task { [engine] in
                try? await engine.startConversation(model: model, history: [])
            }
        }
    }

    func createNewConversation() {
        currentConversation = conversationManager.createConversation()
    }

    func toggleSideMenu() {
        withAnimation(.spring(response: 0.3)) {
            showSideMenu.toggle()
        }
    }
}
