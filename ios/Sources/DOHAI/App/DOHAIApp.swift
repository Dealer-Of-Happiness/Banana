//
//  DOHAIApp.swift
//  DOH AI - Dealer Of Happiness AI
//
//  Privacy-first, offline-capable AI assistant
//

import SwiftUI
import SwiftData
import Combine

@main
struct DOHAIApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("hasAcceptedTerms") private var hasAcceptedTerms = false

    var body: some Scene {
        WindowGroup {
            contentView
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
        } else if appState.isLoading {
            LoadingView(
                progress: appState.loadingProgress,
                message: appState.loadingMessage
            )
        } else if let error = appState.errorMessage {
            ErrorView(message: error) {
                Task { await appState.initialize() }
            }
        } else {
            MainView()
        }
    }
}

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isLoading = false
    @Published var loadingProgress: Double = 0
    @Published var loadingMessage = "Initializing..."
    @Published var errorMessage: String?
    @Published var showSideMenu = false
    @Published var currentConversation: Conversation?

    // Services
    let settings: SettingsManager
    let llamaService: LlamaService
    let speechService: SpeechService
    let documentService: DocumentService
    let imageService: ImageAnalysisService
    let knowledgeBaseService: KnowledgeBaseService
    let cloudAIService: CloudAIService
    let iCloudService: ICloudSyncService
    let conversationManager: ConversationManager

    init() {
        self.settings = SettingsManager()
        // Pass values directly to avoid actor isolation issues
        self.llamaService = LlamaService(
            temperature: settings.temperature,
            contextWindow: settings.contextWindow
        )
        self.speechService = SpeechService(settings: settings)
        self.documentService = DocumentService()
        self.imageService = ImageAnalysisService()
        self.knowledgeBaseService = KnowledgeBaseService()
        self.cloudAIService = CloudAIService(
            chatGPTEnabled: settings.chatGPTEnabled,
            chatGPTApiKey: settings.chatGPTApiKey,
            claudeEnabled: settings.claudeEnabled,
            claudeApiKey: settings.claudeApiKey,
            googleEnabled: settings.googleEnabled,
            googleApiKey: settings.googleApiKey,
            temperature: settings.temperature
        )
        self.iCloudService = ICloudSyncService(settings: settings)
        self.conversationManager = ConversationManager()
    }

    func initialize() async {
        isLoading = true
        loadingMessage = "Initializing AI..."

        do {
            // LLM.swift handles downloading from HuggingFace automatically
            // First download is ~800MB and may take 5-10 minutes
            loadingMessage = "Downloading AI model (~800MB)...\nThis may take several minutes on first run."
            loadingProgress = 0.1
            try await llamaService.loadModel()
            loadingProgress = 0.9

            loadingMessage = "Initializing services..."
            await conversationManager.initialize()

            if settings.iCloudSyncEnabled {
                loadingMessage = "Syncing with iCloud..."
                try await iCloudService.sync()
            }

            loadingProgress = 1.0
            isModelLoaded = true
            isLoading = false

        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
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

// MARK: - Loading View

struct LoadingView: View {
    let progress: Double
    let message: String

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 80))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("DOH AI")
                .font(.largeTitle.bold())

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if progress > 0 {
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)

                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
        .padding()
    }
}

// MARK: - Error View

struct ErrorView: View {
    let message: String
    let retryAction: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.red)

            Text("Something went wrong")
                .font(.title2.bold())

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again", action: retryAction)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
