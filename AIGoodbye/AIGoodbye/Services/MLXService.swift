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
    @Published var isPreparingModel: Bool = false
    @Published var loadedModelId: String?

    // MARK: - Private state

    private var modelContainer: ModelContainer?
    private var session: ChatSession?
    private var sessionModelId: String?

    private let settings: SettingsManager

    /// Brand and behavior instructions sent to every model.
    static let systemPrompt = """
    You are AiGoodbye, a helpful AI assistant created by Dmitry Mikhaylov (Dealer Of Happiness). \
    Official website: aigoodbye.ai. Contact: marketing@dealerofhappiness.com. \
    You run completely offline on the user's device; no data ever leaves the phone. \
    Be concise, helpful, and friendly. Use Markdown formatting (bold, lists, code blocks) when it makes answers clearer. \
    When analyzing images, describe what you see clearly and answer questions about the visual content. \
    Always respond in the same language the user writes to you.
    """

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
            isDownloading = true
            downloadProgress = 0
        } else {
            isPreparingModel = true
        }
        defer {
            isDownloading = false
            isPreparingModel = false
        }

        let configuration = ModelConfiguration(id: hfId)
        do {
            modelContainer = try await VLMModelFactory.shared.loadContainer(
                configuration: configuration
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloadProgress = progress.fractionCompleted
                    if progress.isFinished { self.isDownloading = false }
                }
            }
        } catch {
            throw MLXError.modelLoadFailed(friendlyMessage(for: error))
        }

        loadedModelId = model.id
        ModelManager.shared.noteModelInstalled(model)
    }

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

        let parameters = GenerateParameters(
            maxTokens: 1200,
            temperature: Float(settings.temperature),
            topP: 0.9
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

        if chatHistory.isEmpty {
            session = ChatSession(
                container,
                instructions: Self.systemPrompt,
                generateParameters: parameters,
                processing: processing
            )
        } else {
            session = ChatSession(
                container,
                instructions: Self.systemPrompt,
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
                return String(localized: "No internet connection. The model download needs internet once; chatting works fully offline afterward.")
            case NSURLErrorTimedOut:
                return String(localized: "The connection timed out. Please try again.")
            default: break
            }
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
            return String(localized: "The AI model isn't ready yet. Download or select a model in Settings.")
        case .modelLoadFailed(let reason):
            return String(localized: "Couldn't load the model: \(reason)")
        case .generationFailed(let reason):
            return String(localized: "Couldn't generate a response: \(reason)")
        case .unsupportedBackend(let name):
            return String(localized: "\(name) can't run on this engine.")
        }
    }
}
