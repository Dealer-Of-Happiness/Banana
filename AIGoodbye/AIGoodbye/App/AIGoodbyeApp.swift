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
import UIKit

// MARK: - App Delegate for Background Downloads

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // Check if this is our background download session
        if identifier == ModelManager.backgroundSessionIdentifier {
            print("[AppDelegate] Handling background URL session events")
            // Store the completion handler to call when all events are delivered
            Task { @MainActor in
                ModelManager.shared.backgroundCompletionHandler = completionHandler
            }
        }
    }
}

@main
struct AIGoodbyeApp: App {
    // Connect AppDelegate for background download support
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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
    @Published var loadingMessage = "Initializing..."
    @Published var errorMessage: String?
    @Published var showSideMenu = false
    @Published var currentConversation: Conversation?

    // Services
    let settings: SettingsManager
    let mlxService: MLXService  // Vision-capable MLX service
    let documentService: DocumentService
    let conversationManager: ConversationManager

    init() {
        self.settings = SettingsManager()

        // Primary: MLX Service with vision capabilities
        self.mlxService = MLXService(
            temperature: settings.temperature
        )

        self.documentService = DocumentService()
        self.conversationManager = ConversationManager()
    }

    func initialize() async {
        isLoading = true
        loadingMessage = "Checking for AI model..."

        do {
            loadingMessage = "Loading Vision AI..."
            try await mlxService.loadModel()

            loadingMessage = "Initializing services..."
            await conversationManager.initialize()

            if settings.iCloudSyncEnabled {
                loadingMessage = "Syncing with iCloud..."
                try await iCloudService.sync()
            }

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
    @ObservedObject var appState: AppState
    @ObservedObject var modelManager = ModelManager.shared

    // Rotating tagline phrases
    private let taglinePhrases = [
        "Subscriptions",
        "Security Concerns",
        "Need for Reception",
        "Data Tracking",
        "Monthly Fees",
        "Cloud Dependency"
    ]

    @State private var currentPhraseIndex = 0
    @State private var phraseOpacity: Double = 1.0

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            // Logo image
            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 200, height: 200)

            Text(appState.loadingMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Show download progress from ModelManager
            if modelManager.isDownloading {
                VStack(spacing: 12) {
                    // Real progress bar
                    ProgressView(value: modelManager.downloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 250)

                    // Progress percentage
                    Text("\(Int(modelManager.downloadProgress * 100))%")
                        .font(.title2.monospacedDigit())
                        .fontWeight(.semibold)

                    // Downloaded size / Total size
                    Text("\(modelManager.formattedDownloadedBytes) / \(modelManager.formattedTotalBytes)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)

                    // Status text
                    Text("Download continues in background - you can switch apps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                ProgressView()
            }

            Spacer()

            // Animated tagline at bottom
            VStack(spacing: 4) {
                Text("Say \"Goodbye\" to")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(taglinePhrases[currentPhraseIndex])
                    .font(.footnote.bold())
                    .foregroundStyle(.primary)
                    .opacity(phraseOpacity)
                    .animation(.easeInOut(duration: 0.5), value: phraseOpacity)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
        .padding()
        // Use .task for timer - automatically cancelled when view disappears
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                guard !Task.isCancelled else { break }

                // Fade out
                withAnimation(.easeOut(duration: 0.4)) {
                    phraseOpacity = 0
                }

                try? await Task.sleep(nanoseconds: 400_000_000) // 0.4 seconds
                guard !Task.isCancelled else { break }

                // Change text and fade in
                currentPhraseIndex = (currentPhraseIndex + 1) % taglinePhrases.count
                withAnimation(.easeIn(duration: 0.4)) {
                    phraseOpacity = 1
                }
            }
        }
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
