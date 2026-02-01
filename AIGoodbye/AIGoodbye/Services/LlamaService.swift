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
        let modelSizeBytes = model.sizeBytes
        let template = templateForModel(model)

        // Quick check if download needed (minimal main thread impact)
        var needsDownload = !fileManager.fileExists(atPath: url.path)

        if !needsDownload {
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let fileSize = attributes[.size] as? Int64 {
                let minimumSize = modelSizeBytes / 2
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

        guard fileManager.fileExists(atPath: url.path) else {
            throw LlamaError.modelNotFound
        }

        print("[LlamaService] Loading model on background thread (non-blocking)...")

        // CRITICAL FIX: Use withCheckedThrowingContinuation for TRUE async suspension
        // This allows the main thread to remain responsive while waiting for model load
        // Unlike Task.detached().value which BLOCKS the calling thread waiting for result,
        // this pattern properly SUSPENDS the async function, freeing the main thread
        let loadedLLM = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LLM, Error>) in
            // Dispatch ALL heavy work to background queue
            // Main thread is now FREE - not blocked waiting
            DispatchQueue.global(qos: .userInitiated).async {
                // 1. Verify file on background thread (was blocking main thread before!)
                let verifyResult = Self.verifyFileOnBackgroundThread(at: url, modelSizeBytes: modelSizeBytes)
                if case .failure(let error) = verifyResult {
                    continuation.resume(throwing: error)
                    return
                }

                // 2. Try to load the model with default GPU settings
                // The LLM library handles GPU/CPU fallback automatically
                for attempt in 1...3 {
                    print("[LlamaService] Loading attempt \(attempt)...")

                    if let llm = LLM(from: url, template: template, historyLimit: 30) {
                        print("[LlamaService] Model loaded successfully!")
                        continuation.resume(returning: llm)
                        return
                    }

                    if attempt < 3 {
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }

                print("[LlamaService] All loading attempts failed")

                // All configurations failed - diagnose on background thread
                let diagnosis = Self.diagnoseLoadFailureOnBackgroundThread(at: url, expectedSize: modelSizeBytes)
                continuation.resume(throwing: LlamaError.modelLoadFailed(diagnosis))
            }
        }

        // Back on MainActor after continuation resumes - assign to instance
        bot = loadedLLM
        modelURL = url
        currentModelId = model.id
        print("[LlamaService] Model assigned and ready for use")
    }

    // MARK: - Background Thread Helpers (Static to avoid @MainActor isolation)

    /// Verify file on background thread - nonisolated to allow calling from DispatchQueue
    nonisolated private static func verifyFileOnBackgroundThread(at url: URL, modelSizeBytes: Int64) -> Result<Void, Error> {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: url.path) else {
            return .failure(LlamaError.modelNotFound)
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            return .failure(LlamaError.modelLoadFailed("Cannot read model file attributes"))
        }

        let minimumSize = modelSizeBytes / 2
        if fileSize < minimumSize {
            try? fileManager.removeItem(at: url)
            return .failure(LlamaError.modelLoadFailed("Model file is incomplete (\(fileSize / 1_000_000) MB). Please download again."))
        }

        // Verify GGUF magic header
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            guard let headerData = try handle.read(upToCount: 4),
                  headerData.count == 4 else {
                return .failure(LlamaError.modelLoadFailed("Cannot read model file header"))
            }

            let magic = headerData.withUnsafeBytes { $0.load(as: UInt32.self) }
            if magic != 0x46554747 { // "GGUF"
                try? fileManager.removeItem(at: url)
                return .failure(LlamaError.modelLoadFailed("Model file is corrupted. Please download again."))
            }
        } catch {
            return .failure(LlamaError.modelLoadFailed("Cannot verify model file: \(error.localizedDescription)"))
        }

        print("[LlamaService] File verification passed: \(fileSize / 1_000_000) MB, valid GGUF")
        return .success(())
    }

    /// Diagnose load failure on background thread - nonisolated to allow calling from DispatchQueue
    nonisolated private static func diagnoseLoadFailureOnBackgroundThread(at url: URL, expectedSize: Int64) -> String {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: url.path) else {
            return "Model file not found. Please download again."
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? Int64 {
            let percentComplete = Int((Double(fileSize) / Double(expectedSize)) * 100)

            if fileSize < expectedSize / 2 {
                try? fileManager.removeItem(at: url)
                return "Download incomplete (\(percentComplete)%). Please download again."
            }

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

        return "Could not initialize AI model. Try restarting the app."
    }

    private func templateForModel(_ model: AIModel) -> Template {
        let systemPrompt = buildSystemPrompt()

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
        case .qwenvl:
            // Qwen VL models (Qwen2-VL, Qwen3-VL) use ChatML format
            return .chatML(systemPrompt)
        case .smolvlm:
            // SmolVLM uses ChatML format
            return .chatML(systemPrompt)
        }
    }

    /// Build system prompt with brand info and language setting
    private func buildSystemPrompt() -> String {
        let brandInfo = """
        You are AiGoodbye, a helpful AI assistant. \
        AiGoodbye was created by Dmitry Mikhaylov, also known as Dealer Of Happiness. \
        The official website is aigoodbye.ai. \
        For inquiries, users can contact marketing@dealerofhappiness.com. \
        You run completely offline on the user's device, ensuring complete privacy.
        """

        let languageCode = UserDefaults.standard.string(forKey: "output_language") ?? "en"

        var prompt = brandInfo
        prompt += " Be concise, helpful, and friendly."

        // Add language instruction if not English
        if languageCode != "en" {
            let languageName: String
            switch languageCode {
            case "es": languageName = "Spanish"
            case "fr": languageName = "French"
            case "de": languageName = "German"
            case "it": languageName = "Italian"
            case "pt": languageName = "Portuguese"
            case "ru": languageName = "Russian"
            case "ja": languageName = "Japanese"
            case "ko": languageName = "Korean"
            case "zh": languageName = "Chinese"
            case "ar": languageName = "Arabic"
            case "hi": languageName = "Hindi"
            case "vi": languageName = "Vietnamese"
            case "th": languageName = "Thai"
            case "tr": languageName = "Turkish"
            case "pl": languageName = "Polish"
            case "nl": languageName = "Dutch"
            case "id": languageName = "Indonesian"
            default: languageName = "English"
            }
            prompt += " IMPORTANT: Always respond in \(languageName)."
        }

        return prompt
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
        let modelSizeBytes = model.sizeBytes
        let template = templateForModel(model)

        guard fileManager.fileExists(atPath: url.path) else {
            throw LlamaError.modelNotFound
        }

        print("[LlamaService] Loading specific model on background thread (non-blocking)...")

        // Use withCheckedThrowingContinuation for TRUE async suspension
        let loadedLLM = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LLM, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // Verify file on background thread
                let verifyResult = Self.verifyFileOnBackgroundThread(at: url, modelSizeBytes: modelSizeBytes)
                if case .failure(let error) = verifyResult {
                    continuation.resume(throwing: error)
                    return
                }

                // Try to load the model with default settings
                for attempt in 1...3 {
                    print("[LlamaService] Loading \(model.name) attempt \(attempt)...")

                    if let llm = LLM(from: url, template: template, historyLimit: 30) {
                        print("[LlamaService] Model \(model.name) loaded successfully!")
                        continuation.resume(returning: llm)
                        return
                    }

                    if attempt < 3 {
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }

                print("[LlamaService] All loading attempts failed for \(model.name)")

                let diagnosis = Self.diagnoseLoadFailureOnBackgroundThread(at: url, expectedSize: modelSizeBytes)
                continuation.resume(throwing: LlamaError.modelLoadFailed(diagnosis))
            }
        }

        bot = loadedLLM
        modelURL = url
        currentModelId = model.id
        print("[LlamaService] Model \(model.name) assigned and ready for use")
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
