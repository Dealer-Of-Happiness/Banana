//
//  MLXService.swift
//  AIGoodbye
//
//  On-device inference for downloaded models via Apple MLX.
//
//  v3.0: rebuilt around the library's ChatSession:
//  - real token streaming (text appears as it is generated)
//  - generation cancels when the caller stops listening (Stop button)
//  - the model's own chat template is applied by the library (no manual
//    prompt strings, no template token cleanup)
//  - the key-value cache is reused across turns, so each message no longer
//    re-processes the whole conversation (big win on older devices)
//  - the Context Window setting genuinely limits how much history is loaded
//

import Foundation
import UIKit
import Combine
import MLX
import MLXLMCommon
import MLXVLM

@MainActor
final class MLXService: ObservableObject {

    // MARK: - Published state

    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalDownloadBytes: Int64 = 0
    @Published var isDownloadStalled: Bool = false
    @Published var isPreparingModel: Bool = false
    @Published var loadedModelId: String?

    /// Last moment download bytes moved; drives the stall warning.
    private var lastDownloadActivity = Date()
    private var stallMonitor: Task<Void, Never>?

    // MARK: - Private state

    private var modelContainer: ModelContainer?
    private var session: ChatSession?
    private var sessionModelId: String?

    private let settings: SettingsManager

    /// Brand and behavior instructions sent to every model.
    static let basePrompt = """
    You are AiGoodbye, a helpful AI assistant created by Dmitry Mikhaylov (Dealer Of Happiness). \
    Official website: aigoodbye.ai. Contact: marketing@dealerofhappiness.com. \
    You run completely offline on the user's device; no data ever leaves the phone. \
    Be concise, helpful, and friendly. Use Markdown formatting (bold, lists, code blocks) when it makes answers clearer. \
    When analyzing images, describe what you see clearly and answer questions about the visual content.
    """

    /// Full system prompt including the response-language rule.
    static func systemPrompt(for language: AppLanguage) -> String {
        basePrompt + " " + language.modelInstruction
    }

    init(settings: SettingsManager) {
        self.settings = settings

        #if !targetEnvironment(simulator)
        // Cap the MLX GPU cache to prevent memory accumulation during inference.
        // 20 MB follows the official mlx-swift-examples guidance for iOS.
        // (Never touch MLX's Metal device in the simulator; it aborts.)
        GPU.set(cacheLimit: 20 * 1024 * 1024)
        #endif
    }

    // MARK: - Model loading

    /// Load (and download if needed) the given model. Safe to call repeatedly.
    func loadModel(_ model: AIModel) async throws {
        guard model.backend == .mlx, let hfId = model.huggingFaceId else {
            throw MLXError.unsupportedBackend(model.name)
        }

        if modelContainer != nil && loadedModelId == model.id { return }

        // Switching models: free the previous one first.
        unload()

        let wasDownloaded = ModelManager.shared.isModelDownloaded(model)
        if !wasDownloaded {
            beginDownloadState(expectedBytes: model.sizeBytes)
        } else {
            isPreparingModel = true
        }
        defer {
            endDownloadState()
            isPreparingModel = false
        }

        // Fast path: download the files ourselves at full network speed with
        // real byte progress. On any failure fall back to the library's own
        // downloader below (which then finds whatever we already fetched).
        if !wasDownloaded, let repoDir = ModelManager.shared.modelDirectory(for: model) {
            do {
                try await ModelPrefetcher().prefetch(hfId: hfId, into: repoDir) { [weak self] done, total in
                    Task { @MainActor in
                        self?.noteDownloadProgress(done: done, total: total)
                    }
                }
                isDownloading = false
                isDownloadStalled = false
                isPreparingModel = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Library fallback still runs; show byte progress from disk.
                startDiskPollProgress(for: model)
            }
        }

        let configuration = ModelConfiguration(id: hfId)
        do {
            modelContainer = try await VLMModelFactory.shared.loadContainer(
                configuration: configuration
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    if progress.isFinished && self.isDownloading {
                        self.isDownloading = false
                        self.isPreparingModel = true
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MLXError.modelLoadFailed(friendlyMessage(for: error))
        }

        loadedModelId = model.id
        ModelManager.shared.noteModelInstalled(model)
    }

    // MARK: - Download progress bookkeeping

    private func beginDownloadState(expectedBytes: Int64) {
        isDownloading = true
        downloadProgress = 0
        downloadedBytes = 0
        totalDownloadBytes = expectedBytes
        isDownloadStalled = false
        lastDownloadActivity = Date()

        // Warn when no bytes have moved for a while (bad Wi-Fi, captive
        // portal, etc.) so the user is never stuck staring at a frozen bar.
        stallMonitor?.cancel()
        stallMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.isDownloading else { break }
                if Date().timeIntervalSince(self.lastDownloadActivity) > 45 {
                    self.isDownloadStalled = true
                }
            }
        }
    }

    private func endDownloadState() {
        isDownloading = false
        isDownloadStalled = false
        stallMonitor?.cancel()
        stallMonitor = nil
    }

    private func noteDownloadProgress(done: Int64, total: Int64) {
        if done > downloadedBytes {
            lastDownloadActivity = Date()
            isDownloadStalled = false
        }
        downloadedBytes = done
        totalDownloadBytes = max(total, 1)
        downloadProgress = min(Double(done) / Double(max(total, 1)), 0.999)
    }

    /// Fallback progress source: watch bytes appear on disk while the
    /// library's own downloader runs.
    private func startDiskPollProgress(for model: AIModel) {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isDownloading else { break }
                let bytes = ModelManager.shared.downloadedSizeBytes(for: model)
                self.noteDownloadProgress(done: bytes, total: max(model.sizeBytes, bytes))
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    #if DEBUG
    /// Test hook: run only the download phase (no Metal weight loading), so
    /// the full download UX can be exercised in the iOS Simulator.
    /// Launch with AIG_SIM_TEST_DOWNLOAD=1 to activate.
    func debugDownloadOnly(_ model: AIModel) async throws {
        guard let hfId = model.huggingFaceId,
              let repoDir = ModelManager.shared.modelDirectory(for: model) else { return }
        beginDownloadState(expectedBytes: model.sizeBytes)
        defer { endDownloadState() }
        try await ModelPrefetcher().prefetch(hfId: hfId, into: repoDir) { [weak self] done, total in
            Task { @MainActor in
                self?.noteDownloadProgress(done: done, total: total)
            }
        }
        ModelManager.shared.noteModelInstalled(model)
    }
    #endif

    func unload() {
        session = nil
        sessionModelId = nil
        modelContainer = nil
        loadedModelId = nil
    }

    /// Drop only the chat session; the loaded model stays in memory.
    func dropSession() {
        session = nil
        sessionModelId = nil
    }

    var isModelLoaded: Bool { modelContainer != nil }

    // MARK: - Conversation session

    /// Start (or restart) the chat session for a conversation.
    ///
    /// Call when: a conversation is opened or switched, history is edited
    /// (regenerate, clear), or the model / context setting changes.
    /// Do NOT call between normal turns; keeping the session alive is what
    /// enables cache reuse.
    func startSession(model: AIModel, history: [(role: String, content: String)]) {
        guard let container = modelContainer, loadedModelId == model.id else {
            session = nil
            sessionModelId = nil
            return
        }

        // repetitionPenalty is essential for small quantized models: without
        // it, 2B-class models can loop the same phrases endlessly.
        let parameters = GenerateParameters(
            maxTokens: 1200,
            temperature: Float(settings.temperature),
            topP: 0.9,
            repetitionPenalty: 1.15,
            repetitionContextSize: 64
        )

        let edge = model.imageProcessingEdge
        let processing = UserInput.Processing(
            resize: CGSize(width: edge, height: edge)
        )

        let trimmed = Self.trimHistory(history, tokenBudget: settings.contextWindow)
        let chatHistory: [Chat.Message] = trimmed.compactMap { entry in
            switch entry.role.lowercased() {
            case "user": return .user(entry.content)
            case "assistant": return .assistant(entry.content)
            default: return nil
            }
        }

        let instructions = Self.systemPrompt(for: settings.appLanguage)
        if chatHistory.isEmpty {
            session = ChatSession(
                container,
                instructions: instructions,
                generateParameters: parameters,
                processing: processing
            )
        } else {
            session = ChatSession(
                container,
                instructions: instructions,
                history: chatHistory,
                generateParameters: parameters,
                processing: processing
            )
        }
        sessionModelId = model.id
    }

    /// Whether a live session exists for the given model.
    func hasSession(for model: AIModel) -> Bool {
        session != nil && sessionModelId == model.id
    }

    // MARK: - Generation

    /// Stream a response. Yields the FULL response text so far with each event
    /// (snapshot semantics). Ending iteration early cancels generation.
    func respondStream(prompt: String, image: UIImage?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let session = self.session else {
                continuation.finish(throwing: MLXError.modelNotLoaded)
                return
            }

            let userImage: UserInput.Image?
            if let image, let cgImage = image.cgImage {
                userImage = .ciImage(CIImage(cgImage: cgImage))
            } else {
                userImage = nil
            }

            let task = Task {
                var accumulated = ""
                do {
                    let stream = session.streamResponse(to: prompt, image: userImage)
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        accumulated += chunk
                        continuation.yield(accumulated)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: MLXError.generationFailed(self.friendlyMessage(for: error)))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - History trimming

    /// Keep the most recent messages that fit within the token budget.
    /// Tokens are approximated as characters / 3.5 (safe for mixed languages).
    nonisolated static func trimHistory(
        _ history: [(role: String, content: String)],
        tokenBudget: Int
    ) -> [(role: String, content: String)] {
        // Reserve room for the system prompt, the next question, and the answer.
        let reserve = 1800
        let charBudget = max(2000, Int(Double(tokenBudget) * 3.5) - reserve)

        var result: [(role: String, content: String)] = []
        var used = 0
        for entry in history.reversed() {
            // Individual messages are capped so one huge document cannot
            // consume the entire window.
            let content = entry.content.count > 4000
                ? String(entry.content.prefix(4000)) + "\n[Truncated]"
                : entry.content
            let cost = content.count
            if used + cost > charBudget { break }
            result.append((entry.role, content))
            used += cost
        }
        return result.reversed()
    }

    // MARK: - Errors

    private func friendlyMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return L10n.text("No internet connection. The model download needs internet once; chatting works fully offline afterward.")
            case NSURLErrorTimedOut:
                return L10n.text("The connection timed out. Please try again.")
            default: break
            }
        }
        // Missing files after a failed download attempt (the library falls
        // back to an empty local folder when it can't reach the internet).
        if ns.domain == NSCocoaErrorDomain
            && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError) {
            return L10n.text("The download couldn't start. Check your internet connection and try again.")
        }
        return error.localizedDescription
    }
}

// MARK: - Errors

enum MLXError: LocalizedError {
    case modelNotLoaded
    case modelLoadFailed(String)
    case generationFailed(String)
    case unsupportedBackend(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return L10n.text("The AI model isn't ready yet. Download or select a model in Settings.")
        case .modelLoadFailed(let reason):
            return L10n.text("Couldn't load the model: \(reason)")
        case .generationFailed(let reason):
            return L10n.text("Couldn't generate a response: \(reason)")
        case .unsupportedBackend(let name):
            return L10n.text("\(name) can't run on this engine.")
        }
    }
}
