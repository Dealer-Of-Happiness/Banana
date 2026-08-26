//
//  ChatEngine.swift
//  AIGoodbye
//
//  Routes chat requests to the right backend: the built-in Apple Intelligence
//  model (instant, text-only) or a downloaded MLX model (full vision support).
//  Owns model selection, download consent, and engine status for the UI.
//

import Foundation
import UIKit
import Combine

@MainActor
final class ChatEngine: ObservableObject {

    // MARK: - Types

    enum Status: Equatable {
        case idle
        case downloading(Double)
        case preparing
        case ready(String)          // ready with model name
        case needsSetup             // no usable engine yet
    }

    enum RouteError: LocalizedError {
        case needsDownloadConsent(AIModel)
        case visionNeedsDownloadedModel(AIModel)
        case nothingAvailable(String)

        var errorDescription: String? {
            switch self {
            case .needsDownloadConsent(let model):
                return String(localized: "\(model.name) needs to be downloaded first.")
            case .visionNeedsDownloadedModel(let model):
                return String(localized: "Analyzing images needs the \(model.name) vision model.")
            case .nothingAvailable(let reason):
                return reason
            }
        }
    }

    // MARK: - Services

    let mlx: MLXService
    let appleIntelligence: AppleIntelligenceService
    private let settings: SettingsManager

    // MARK: - Selection & consent

    /// The engine the user selected. Defaults are device-aware and set on first use.
    @Published private(set) var selectedModel: AIModel

    private static let selectedModelKey = "selectedModelId"
    private static let approvedDownloadsKey = "approvedModelDownloads"

    // MARK: - Init

    init(settings: SettingsManager) {
        self.settings = settings
        self.mlx = MLXService(settings: settings)
        self.appleIntelligence = AppleIntelligenceService()

        // Restore selection, or pick a smart device-aware default.
        if let savedId = UserDefaults.standard.string(forKey: Self.selectedModelKey),
           let saved = AIModel.model(withId: savedId) {
            self.selectedModel = saved
        } else if AppleIntelligenceService().isAvailable {
            // Instant chat out of the box; vision model can come later.
            self.selectedModel = .appleIntelligence
        } else {
            self.selectedModel = AIModel.recommendedDownloadModel
        }
    }

    // MARK: - Selection

    func select(_ model: AIModel) {
        selectedModel = model
        UserDefaults.standard.set(model.id, forKey: Self.selectedModelKey)
    }

    /// Models shown in pickers: built-in first (when available), then current
    /// models, then legacy ones the user already has on disk.
    var availableChoices: [AIModel] {
        var choices: [AIModel] = []
        if appleIntelligence.isAvailable { choices.append(.appleIntelligence) }
        choices.append(contentsOf: AIModel.allModels.filter { !$0.isLegacy || $0.isDownloaded })
        return choices
    }

    // MARK: - Download consent

    func hasApprovedDownload(for model: AIModel) -> Bool {
        let approved = UserDefaults.standard.stringArray(forKey: Self.approvedDownloadsKey) ?? []
        return approved.contains(model.id)
    }

    func approveDownload(for model: AIModel) {
        var approved = UserDefaults.standard.stringArray(forKey: Self.approvedDownloadsKey) ?? []
        if !approved.contains(model.id) {
            approved.append(model.id)
            UserDefaults.standard.set(approved, forKey: Self.approvedDownloadsKey)
        }
    }

    // MARK: - Routing

    /// Decide which backend will answer, given whether an image is attached.
    /// Throws RouteError when user action is needed (download consent, etc.).
    func route(hasImage: Bool) throws -> AIModel {
        if hasImage {
            // Vision always needs a downloaded model.
            if selectedModel.backend == .mlx && selectedModel.supportsVision {
                return try routeMLX(selectedModel)
            }
            // Apple Intelligence selected: fall back to the best downloaded
            // vision model, or ask to set one up.
            if let downloaded = AIModel.allModels.first(where: { $0.isDownloaded && $0.supportsVision }) {
                return try routeMLX(downloaded)
            }
            throw RouteError.visionNeedsDownloadedModel(AIModel.recommendedDownloadModel)
        }

        if selectedModel.backend == .appleIntelligence {
            if appleIntelligence.isAvailable { return selectedModel }
            // Apple Intelligence became unavailable: fall back to a downloaded model.
            if let downloaded = AIModel.allModels.first(where: { $0.isDownloaded }) {
                return try routeMLX(downloaded)
            }
            throw RouteError.needsDownloadConsent(AIModel.recommendedDownloadModel)
        }

        return try routeMLX(selectedModel)
    }

    private func routeMLX(_ model: AIModel) throws -> AIModel {
        if !model.isDownloaded && !hasApprovedDownload(for: model) {
            throw RouteError.needsDownloadConsent(model)
        }
        return model
    }

    // MARK: - Session lifecycle

    /// Prepare the backend for a conversation (loads model if needed, builds
    /// the session with history). Call on conversation open/switch/edit.
    func startConversation(model: AIModel, history: [(role: String, content: String)]) async throws {
        #if targetEnvironment(simulator)
        // Simulator: MLX cannot run; the echo engine needs no setup.
        if model.backend == .appleIntelligence {
            appleIntelligence.startSession(history: history)
        }
        return
        #else
        if model.backend == .appleIntelligence {
            appleIntelligence.startSession(history: history)
        } else {
            try await mlx.loadModel(model)
            mlx.startSession(model: model, history: history)
        }
        #endif
    }

    /// Whether a live session exists (avoids rebuilding between turns).
    func hasSession(for model: AIModel) -> Bool {
        model.backend == .appleIntelligence
            ? appleIntelligence.hasSession
            : mlx.hasSession(for: model)
    }

    /// Stream a response from the given routed model. Snapshot semantics.
    func respondStream(model: AIModel, prompt: String, image: UIImage?) -> AsyncThrowingStream<String, Error> {
        #if targetEnvironment(simulator)
        // Simulator: MLX cannot execute; stream a canned response so the full
        // chat experience (streaming, Stop, Markdown) can be exercised in
        // previews and UI tests. Compiled out of device builds entirely.
        if model.backend != .appleIntelligence || !appleIntelligence.isAvailable {
            return Self.simulatorEchoStream(prompt: prompt, hasImage: image != nil)
        }
        return appleIntelligence.respondStream(prompt: prompt)
        #else
        if model.backend == .appleIntelligence {
            return appleIntelligence.respondStream(prompt: prompt)
        }
        return mlx.respondStream(prompt: prompt, image: image)
        #endif
    }

    #if targetEnvironment(simulator)
    /// Canned streaming response used only in the iOS Simulator.
    nonisolated static func simulatorEchoStream(prompt: String, hasImage: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let reply = """
                **Simulator test mode.** MLX models need a real device, so this is a canned reply.

                You said: *\(prompt.prefix(120))*\(hasImage ? "\n\nAn image was attached." : "")

                Things this reply exercises:
                - Live **streaming** with the Stop button
                - Markdown: **bold**, *italic*, `inline code`
                - Lists and code blocks

                ```swift
                let app = "AiGoodbye"
                print("Hello from \\(app) 3.0")
                ```

                On a real iPhone this text comes from the on-device model.
                """
                var shown = ""
                for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                    if Task.isCancelled { break }
                    shown += (shown.isEmpty ? "" : " ") + word
                    continuation.yield(shown)
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    #endif

    /// Drop all live sessions (e.g. after clearing a chat or changing settings).
    func resetSessions() {
        mlx.dropSession()
        appleIntelligence.startSession(history: [])
    }

    // MARK: - Status for UI

    var status: Status {
        if mlx.isDownloading { return .downloading(mlx.downloadProgress) }
        if mlx.isPreparingModel { return .preparing }
        if selectedModel.backend == .appleIntelligence {
            return appleIntelligence.isAvailable
                ? .ready(selectedModel.name)
                : .needsSetup
        }
        if selectedModel.isDownloaded || mlx.loadedModelId == selectedModel.id {
            return .ready(selectedModel.name)
        }
        return .needsSetup
    }
}

