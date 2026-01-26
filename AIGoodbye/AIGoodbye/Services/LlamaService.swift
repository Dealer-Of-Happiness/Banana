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
            // After download, wait briefly for filesystem to fully sync
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }

        let template = templateForModel(model)

        guard fileManager.fileExists(atPath: url.path) else {
            throw LlamaError.modelNotFound
        }

        // Verify file is readable before attempting to load
        try verifyFileReadable(at: url, model: model)

        // Load model with retry logic
        // CRITICAL: Run LLM initialization OFF the main thread to avoid blocking UI
        // and triggering iOS watchdog timer (which kills apps blocking main thread >2-3 seconds)
        print("[LlamaService] Loading model on background thread...")

        let maxRetries = 3
        let retryDelays: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000] // 500ms, 1s, 2s

        for attempt in 1...maxRetries {
            // Run the heavy LLM initialization on a background thread
            // This prevents blocking the main thread and avoids iOS watchdog termination
            let loadedLLM: LLM? = await Task.detached(priority: .userInitiated) {
                print("[LlamaService] Attempt \(attempt): Initializing LLM on background thread...")
                return LLM(from: url, template: template, historyLimit: 30)
            }.value

            if let llm = loadedLLM {
                bot = llm
                modelURL = url
                currentModelId = model.id
                print("[LlamaService] Model loaded successfully on attempt \(attempt) with historyLimit: 30")
                return
            }

            if attempt < maxRetries {
                print("[LlamaService] Model load attempt \(attempt) failed, retrying in \(retryDelays[attempt - 1] / 1_000_000)ms...")
                try await Task.sleep(nanoseconds: retryDelays[attempt - 1])
            }
        }

        // All retries failed - try to diagnose the issue
        let diagnosis = diagnoseModelLoadFailure(at: url, model: model)
        throw LlamaError.modelLoadFailed(diagnosis)
    }

    /// Verify the model file is readable and has valid GGUF header
    private func verifyFileReadable(at url: URL, model: AIModel) throws {
        let fileManager = FileManager.default

        // Check file exists
        guard fileManager.fileExists(atPath: url.path) else {
            throw LlamaError.modelNotFound
        }

        // Check file size
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            throw LlamaError.modelLoadFailed("Cannot read model file attributes")
        }

        let minimumSize = model.sizeBytes / 2
        if fileSize < minimumSize {
            try? fileManager.removeItem(at: url)
            throw LlamaError.modelLoadFailed("Model file is incomplete (\(fileSize / 1_000_000) MB). Please download again.")
        }

        // Verify GGUF magic header
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            guard let headerData = try handle.read(upToCount: 4),
                  headerData.count == 4 else {
                throw LlamaError.modelLoadFailed("Cannot read model file header")
            }

            let magic = headerData.withUnsafeBytes { $0.load(as: UInt32.self) }
            if magic != 0x46554747 { // "GGUF"
                try? fileManager.removeItem(at: url)
                throw LlamaError.modelLoadFailed("Model file is corrupted (invalid format). Please download again.")
            }
        } catch let error as LlamaError {
            throw error
        } catch {
            throw LlamaError.modelLoadFailed("Cannot verify model file: \(error.localizedDescription)")
        }

        print("[LlamaService] File verification passed: \(fileSize / 1_000_000) MB, valid GGUF")
    }

    /// Diagnose why model loading failed and provide helpful error message
    private func diagnoseModelLoadFailure(at url: URL, model: AIModel) -> String {
        let fileManager = FileManager.default

        // Check if file exists
        guard fileManager.fileExists(atPath: url.path) else {
            return "Model file not found. Please download again."
        }

        // Check file size
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? Int64 {
            let expectedSize = model.sizeBytes
            let percentComplete = Int((Double(fileSize) / Double(expectedSize)) * 100)

            if fileSize < expectedSize / 2 {
                // File is too small - likely incomplete download
                try? fileManager.removeItem(at: url)
                return "Download incomplete (\(percentComplete)%). Please download again."
            }

            // File size looks OK, might be corrupted
            if fileSize > 0 {
                // Check GGUF header
                if let handle = try? FileHandle(forReadingFrom: url),
                   let headerData = try? handle.read(upToCount: 4) {
                    try? handle.close()

                    if headerData.count < 4 {
                        try? fileManager.removeItem(at: url)
                        return "Model file is corrupted. Please download again."
                    }

                    let magic = headerData.withUnsafeBytes { $0.load(as: UInt32.self) }
                    if magic != 0x46554747 {
                        try? fileManager.removeItem(at: url)
                        return "Model file has invalid format. Please download again."
                    }
                }
            }
        }

        // File looks valid but still can't load - likely memory issue
        return "Cannot load model. Try closing other apps and restarting."
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

        // Verify file is readable and valid
        try verifyFileReadable(at: url, model: model)

        let template = templateForModel(model)

        // Load model with retry logic
        // CRITICAL: Run LLM initialization OFF the main thread
        let maxRetries = 3
        let retryDelays: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000] // 500ms, 1s, 2s

        for attempt in 1...maxRetries {
            // Run the heavy LLM initialization on a background thread
            let loadedLLM: LLM? = await Task.detached(priority: .userInitiated) {
                return LLM(from: url, template: template, historyLimit: 30)
            }.value

            if let llm = loadedLLM {
                bot = llm
                modelURL = url
                currentModelId = model.id
                print("[LlamaService] Model \(model.name) loaded successfully on attempt \(attempt)")
                return
            }

            if attempt < maxRetries {
                print("[LlamaService] Model load attempt \(attempt) failed, retrying...")
                try await Task.sleep(nanoseconds: retryDelays[attempt - 1])
            }
        }

        // All retries failed
        let diagnosis = diagnoseModelLoadFailure(at: url, model: model)
        throw LlamaError.modelLoadFailed(diagnosis)
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
