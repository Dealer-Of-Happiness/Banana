//
//  LlamaService.swift
//  AIGoodbye
//
//  Local Llama model inference service using LLM.swift
//  SIMPLE APPROACH: Load once, keep alive, just call respond()
//

import Foundation
import LLM

@MainActor
class LlamaService {
    private var bot: LLM?
    private let temperature: Float
    private var currentModelId: String?
    private var modelURL: URL?

    // Download state - observable from outside
    static var downloadedBytes: Int64 = 0
    static var totalBytes: Int64 = 0
    static var isDownloading: Bool = false

    // Default: low temperature for consistent responses
    init(temperature: Double = 0.3) {
        self.temperature = Float(temperature)
    }

    // MARK: - Model Management

    private func getModelManager() -> ModelManager {
        ModelManager.shared
    }

    func loadModel() async throws {
        let manager = getModelManager()
        let model = manager.activeModel

        // If already loaded with same model, skip - KEEP BOT ALIVE
        if bot != nil && currentModelId == model.id {
            print("[LlamaService] Model already loaded, reusing existing instance")
            return
        }

        // Only unload when switching to a different model
        if currentModelId != nil && currentModelId != model.id {
            print("[LlamaService] Switching models, unloading previous")
            bot = nil
        }
        currentModelId = nil

        // Load the model
        try await loadModelInternal(model)
    }

    private func loadModelInternal(_ model: AIModel) async throws {
        let manager = getModelManager()
        let url = manager.modelPath(for: model)
        let fileManager = FileManager.default

        // Check if model is downloaded and valid
        var needsDownload = !fileManager.fileExists(atPath: url.path)

        if !needsDownload {
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let fileSize = attributes[.size] as? Int64 {
                let minimumSize = model.sizeBytes / 2
                if fileSize < minimumSize {
                    print("[LlamaService] Model file too small (\(fileSize) bytes), redownloading...")
                    try? fileManager.removeItem(at: url)
                    needsDownload = true
                }
            }
        }

        if needsDownload {
            try await downloadModel(model)
        }

        let template = templateForModel(model)

        guard fileManager.fileExists(atPath: url.path) else {
            throw LlamaError.modelNotFound
        }

        // Load model - single attempt, no complex retry logic
        print("[LlamaService] Loading model...")

        guard let llm = LLM(from: url, template: template, historyLimit: 30) else {
            throw LlamaError.modelLoadFailed("Could not initialize AI model. Try closing other apps to free memory, then restart the app.")
        }

        bot = llm
        modelURL = url
        currentModelId = model.id
        print("[LlamaService] Model loaded successfully with historyLimit: 30")
    }

    private func templateForModel(_ model: AIModel) -> Template {
        let systemPrompt = "You are AiGoodbye, a helpful AI assistant created by Dealer Of Happiness. You run completely offline on the user's device. Be concise, helpful, and friendly."

        switch model.templateType {
        case .mistral:
            return .mistral
        case .llama3:
            return .llama(systemPrompt)
        case .gemma:
            return .gemma
        case .phi:
            return .chatML(systemPrompt)
        case .chatml:
            return .chatML(systemPrompt)
        case .alpaca:
            return .alpaca(systemPrompt)
        }
    }

    func loadSpecificModel(_ model: AIModel) async throws {
        // Only nil out if we're loading a different model
        if currentModelId != model.id {
            bot = nil
            currentModelId = nil
        }

        let manager = getModelManager()
        let url = manager.modelPath(for: model)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: url.path) else {
            throw LlamaError.modelNotFound
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? Int64 {
            let minimumSize = model.sizeBytes / 2
            if fileSize < minimumSize {
                try? fileManager.removeItem(at: url)
                throw LlamaError.modelLoadFailed("Model file is incomplete. Please download again.")
            }
        }

        let template = templateForModel(model)

        guard let llm = LLM(from: url, template: template, historyLimit: 30) else {
            throw LlamaError.modelLoadFailed("Model file may be corrupted. Please download again.")
        }

        bot = llm
        modelURL = url
        currentModelId = model.id
    }

    private func downloadModel(_ model: AIModel) async throws {
        let manager = getModelManager()

        LlamaService.isDownloading = true
        LlamaService.downloadedBytes = 0
        LlamaService.totalBytes = model.sizeBytes

        do {
            try await manager.downloadModel(model)
            LlamaService.isDownloading = false
        } catch {
            LlamaService.isDownloading = false
            throw error
        }
    }

    func unloadModel() {
        bot = nil
        currentModelId = nil
        modelURL = nil
    }

    func isModelLoaded() -> Bool {
        bot != nil && currentModelId != nil
    }

    /// Reload the model with current settings (e.g., after context window change)
    func reloadModel() async throws {
        guard let modelId = currentModelId,
              let model = AIModel.model(withId: modelId) else {
            throw LlamaError.modelNotLoaded
        }

        print("[LlamaService] Reloading model with new settings...")
        bot = nil
        try await loadModelInternal(model)
        print("[LlamaService] Model reloaded successfully")
    }

    /// Reset conversation - clears the bot's internal conversation history
    /// Only call this when starting a NEW conversation or user explicitly clears chat
    func resetConversation() {
        print("[LlamaService] resetConversation called - clearing bot history")
        bot?.history.removeAll()
    }

    /// Restore history from saved conversation
    func restoreHistory(_ messages: [(role: String, content: String)]) {
        guard let bot = bot else {
            print("[LlamaService] restoreHistory called but bot is nil")
            return
        }

        bot.history.removeAll()

        for message in messages {
            let role = message.0.lowercased()
            let content = message.1

            if role == "user" {
                bot.history.append((.user, content))
            } else if role == "assistant" {
                bot.history.append((.bot, content))
            }
        }

        print("[LlamaService] restoreHistory: restored \(bot.history.count) messages")
    }

    /// Force reset - only for manual user-triggered reset from Settings
    func forceReset() async throws {
        print("[LlamaService] Force reset initiated...")
        bot = nil
        currentModelId = nil

        try? await Task.sleep(nanoseconds: 500_000_000)
        try await loadModel()
        print("[LlamaService] Force reset completed successfully")
    }

    // MARK: - Text Generation

    /// Generate response - v2.x library handles multi-turn natively
    func generate(prompt: String, conversationHistory: [(role: String, content: String)] = []) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    // Make sure model is loaded (only loads if not already loaded)
                    if self.bot == nil {
                        print("[LlamaService] Bot not loaded, loading model...")
                        try await self.loadModel()
                    }

                    guard let bot = self.bot else {
                        throw LlamaError.modelNotLoaded
                    }

                    print("[LlamaService] Generating response...")
                    print("[LlamaService] Bot history count: \(bot.history.count)")
                    print("[LlamaService] User prompt: \(prompt.prefix(50))...")

                    // v2.x library handles multi-turn natively with historyLimit: 30
                    // Just pass the prompt - library manages context automatically
                    await bot.respond(to: prompt)

                    let response = bot.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    print("[LlamaService] Raw output length: \(response.count)")
                    print("[LlamaService] Bot history count after: \(bot.history.count)")

                    let cleanedResponse = self.cleanResponse(response)

                    if cleanedResponse.isEmpty {
                        print("[LlamaService] WARNING: Empty response")
                        continuation.yield("I couldn't generate a response. Please try again.")
                    } else {
                        continuation.yield(cleanedResponse)
                    }
                    continuation.finish()

                } catch {
                    print("[LlamaService] Generate error: \(error)")
                    continuation.yield("Error: \(error.localizedDescription)")
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Response Cleaning

    private func cleanResponse(_ response: String) -> String {
        var cleaned = response

        // Remove common artifacts
        let patternsToRemove = [
            "<|im_end|>", "<|im_start|>",
            "<|endoftext|>", "<|end|>",
            "<|", "|>",
            "[INST]", "[/INST]",
            "<<SYS>>", "<</SYS>>"
        ]

        for pattern in patternsToRemove {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "")
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Vision Analysis

    func analyzeImage(_ imageData: Data, prompt: String) async throws -> String {
        guard bot != nil else {
            throw LlamaError.modelNotLoaded
        }

        return "Image analysis requires a vision-capable model. Please describe what you'd like to know about the image."
    }
}

// MARK: - Errors

enum LlamaError: LocalizedError {
    case modelNotFound
    case modelNotLoaded
    case downloadFailed(String)
    case generationFailed(String)
    case modelLoadFailed(String)
    case simulatorNotSupported

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "AI model not found. Please download it first."
        case .modelNotLoaded:
            return "AI model is not loaded."
        case .downloadFailed(let reason):
            return "Failed to download model: \(reason)"
        case .generationFailed(let reason):
            return "Failed to generate response: \(reason)"
        case .modelLoadFailed(let reason):
            return "Failed to load model: \(reason)"
        case .simulatorNotSupported:
            return "Local AI requires a physical iPhone device."
        }
    }
}
