//
//  BananaAIApp.swift
//  BananaAI - Your Offline AI Assistant
//
//  Local LLM with document knowledge and optional internet connectivity
//

import SwiftUI

@main
struct BananaAIApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    await appState.initialize()
                }
        }
    }
}

/// Global application state
@MainActor
class AppState: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isLoading = false
    @Published var loadingProgress: Double = 0
    @Published var loadingMessage = "Initializing..."
    @Published var errorMessage: String?

    // Core components
    let aiEngine: LocalAIEngine
    let knowledgeBase: KnowledgeBase
    let documentProcessor: DocumentProcessor
    let settings: SettingsManager

    init() {
        self.settings = SettingsManager()
        self.knowledgeBase = KnowledgeBase()
        self.documentProcessor = DocumentProcessor(knowledgeBase: knowledgeBase)
        self.aiEngine = LocalAIEngine(
            knowledgeBase: knowledgeBase,
            settings: settings
        )
    }

    func initialize() async {
        isLoading = true
        loadingMessage = "Loading AI model..."

        do {
            // Check if model exists, download if needed
            if !aiEngine.isModelDownloaded() {
                loadingMessage = "Downloading AI model (first time only)..."
                try await aiEngine.downloadModel { progress in
                    Task { @MainActor in
                        self.loadingProgress = progress
                    }
                }
            }

            loadingMessage = "Loading model into memory..."
            try await aiEngine.loadModel()

            loadingMessage = "Initializing knowledge base..."
            try await knowledgeBase.initialize()

            isModelLoaded = true
            isLoading = false

        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}
