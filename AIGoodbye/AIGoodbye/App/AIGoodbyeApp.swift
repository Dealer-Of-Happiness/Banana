//
//  AIGoodbyeApp.swift
//  AIGoodbye - aigoodbye.ai
//
//  Say goodbye to monthly subscriptions, sharing your private data,
//  and requiring internet connection
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
            LoadingView(appState: appState)
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
    @Published var downloadedMB: Double = 0
    @Published var totalMB: Double = 0
    @Published var loadingMessage = "Initializing..."
    @Published var errorMessage: String?
    @Published var showSideMenu = false
    @Published var currentConversation: Conversation?

    private var progressTimer: Timer?

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
        loadingMessage = "Checking for AI model..."

        // Start progress monitoring timer
        startProgressMonitoring()

        do {
            loadingMessage = "Downloading AI model..."
            try await llamaService.loadModel()

            stopProgressMonitoring()
            loadingMessage = "Initializing services..."
            await conversationManager.initialize()

            if settings.iCloudSyncEnabled {
                loadingMessage = "Syncing with iCloud..."
                try await iCloudService.sync()
            }

            isModelLoaded = true
            isLoading = false

        } catch {
            stopProgressMonitoring()
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func startProgressMonitoring() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.updateDownloadProgress()
            }
        }
    }

    private func stopProgressMonitoring() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateDownloadProgress() {
        let downloaded = LlamaService.downloadedBytes
        let total = LlamaService.totalBytes

        downloadedMB = Double(downloaded) / (1024 * 1024)
        totalMB = Double(total) / (1024 * 1024)

        if LlamaService.isDownloading && total > 0 {
            loadingMessage = "Downloading AI model..."
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
    @ObservedObject var appState: AppState

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

            Text("AI goodbye")
                .font(.largeTitle.bold())

            Text(appState.loadingMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Show download progress as MB/MB
            if appState.totalMB > 0 {
                VStack(spacing: 12) {
                    // Progress bar
                    ProgressView(value: appState.downloadedMB, total: appState.totalMB)
                        .progressViewStyle(.linear)
                        .frame(width: 250)

                    // MB counter
                    Text("\(Int(appState.downloadedMB)) MB / \(Int(appState.totalMB)) MB")
                        .font(.title3.monospacedDigit())
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    // Percentage
                    let percentage = appState.totalMB > 0 ? (appState.downloadedMB / appState.totalMB) * 100 : 0
                    Text("\(Int(percentage))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Connecting to server...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
