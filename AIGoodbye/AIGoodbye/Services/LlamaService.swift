//
//  LlamaService.swift
//  AIGoodbye
//
//  Local Llama model inference service using LLM.swift
//

import Foundation
import LLM

@MainActor
class LlamaService {
    private var bot: LLM?
    private let temperature: Float
    private var currentModelId: String?

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

    /// Get the current max token count from settings
    private func getMaxTokenCount() -> Int32 {
        return Int32(SettingsManager().contextWindow)
    }

    func loadModel() async throws {
        let manager = getModelManager()
        let model = manager.activeModel

        // If already loaded with same model, skip
        if bot != nil && currentModelId == model.id {
            return
        }

        // Unload previous model
        bot = nil
        currentModelId = nil

        // Load the single model
        try await loadModelInternal(model)
    }

    private func loadModelInternal(_ model: AIModel) async throws {
        let manager = getModelManager()
        let modelURL = manager.modelPath(for: model)
        let fileManager = FileManager.default

        // Always delete existing file if we're retrying after a failure
        // Check UserDefaults for last failed model
        let lastFailedKey = "lastFailedModelId"
        if UserDefaults.standard.string(forKey: lastFailedKey) == model.id {
            // This model failed before, delete and redownload
            try? fileManager.removeItem(at: modelURL)
            UserDefaults.standard.removeObject(forKey: lastFailedKey)
        }

        // Check if model is downloaded and valid
        var needsDownload = !fileManager.fileExists(atPath: modelURL.path)

        if !needsDownload {
            // Check file size - if too small, the download was incomplete
            if let attributes = try? fileManager.attributesOfItem(atPath: modelURL.path),
               let fileSize = attributes[.size] as? Int64 {
                let minimumSize = model.sizeBytes / 2
                if fileSize < minimumSize {
                    try? fileManager.removeItem(at: modelURL)
                    needsDownload = true
                }
            }
        }

        if needsDownload {
            try await downloadModel(model)
        }

        // Get template for the model
        let template = templateForModel(model)

        // Verify file exists after potential download
        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw LlamaError.modelNotFound
        }

        // Try to load the model with settings from user preferences
        let tokenLimit = getMaxTokenCount()
        guard let llm = LLM(
            from: modelURL,
            template: template,
            maxTokenCount: tokenLimit
        ) else {
            // Mark this model as failed so we delete it next time
            UserDefaults.standard.set(model.id, forKey: lastFailedKey)
            // Delete the file
            try? fileManager.removeItem(at: modelURL)
            throw LlamaError.modelLoadFailed("Model failed to initialize. File deleted - restart app to re-download.")
        }

        bot = llm
        currentModelId = model.id
    }

    func loadSpecificModel(_ model: AIModel) async throws {
        // Unload previous model
        bot = nil
        currentModelId = nil

        let manager = getModelManager()
        let modelURL = manager.modelPath(for: model)
        let template = templateForModel(model)
        let fileManager = FileManager.default

        // Verify file exists and has valid size
        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw LlamaError.modelNotFound
        }

        // Check file size
        if let attributes = try? fileManager.attributesOfItem(atPath: modelURL.path),
           let fileSize = attributes[.size] as? Int64 {
            let minimumSize = model.sizeBytes / 2
            if fileSize < minimumSize {
                try? fileManager.removeItem(at: modelURL)
                throw LlamaError.modelLoadFailed("Model file is incomplete. Please download again.")
            }
        }

        let tokenLimit = getMaxTokenCount()
        guard let llm = LLM(
            from: modelURL,
            template: template,
            maxTokenCount: tokenLimit
        ) else {
            try? fileManager.removeItem(at: modelURL)
            throw LlamaError.modelLoadFailed("Model file may be corrupted. Please download again.")
        }

        bot = llm
        currentModelId = model.id
    }

    private let systemPrompt = "You are AiGoodbye, a helpful, friendly AI assistant. Be concise and helpful in your responses."

    private func templateForModel(_ model: AIModel) -> Template {
        switch model.templateType {
        case .mistral:
            return .mistral
        case .llama3:
            return .chatML(systemPrompt)
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
    }

    func isModelLoaded() -> Bool {
        bot != nil
    }

    /// Reset conversation history for starting a new chat
    func resetConversation() {
        bot?.history.removeAll()
        print("[LlamaService] Conversation reset - history cleared")
    }

    /// Restore conversation history from saved messages (for resuming conversations)
    func restoreHistory(_ messages: [(role: String, content: String)]) {
        guard let bot = bot else { return }

        // Convert to LLM.swift's Chat format (role, content) tuples
        // LLM.swift uses .user and .bot for roles
        bot.history.removeAll()
        for msg in messages {
            if msg.role.lowercased() == "user" {
                bot.history.append((.user, msg.content))
            } else {
                bot.history.append((.bot, msg.content))
            }
        }
        print("[LlamaService] Restored \(bot.history.count) messages to history")
    }

    // MARK: - Text Generation

    /// Recreate the LLM instance to reset KV cache (workaround for LLM.swift Issue #50)
    private func recreateLLMInstance() async -> Bool {
        guard let modelId = currentModelId,
              let model = AIModel.model(withId: modelId) else {
            print("[LlamaService] recreateLLMInstance: No model ID or model not found")
            return false
        }

        let manager = getModelManager()
        let modelURL = manager.modelPath(for: model)
        let template = templateForModel(model)

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            print("[LlamaService] recreateLLMInstance: Model file doesn't exist")
            return false
        }

        // Release old instance first
        print("[LlamaService] Releasing old LLM instance...")
        bot = nil

        // CRITICAL: Wait for memory to be freed on physical devices
        // Without this delay, creating a new 2.7GB model while the old one
        // is still in memory can fail on devices with limited RAM
        #if !targetEnvironment(simulator)
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms on physical device
        #else
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms in simulator
        #endif

        // Create a fresh LLM instance with clean KV cache
        print("[LlamaService] Creating fresh LLM instance...")
        let tokenLimit = getMaxTokenCount()
        guard let newLLM = LLM(
            from: modelURL,
            template: template,
            maxTokenCount: tokenLimit
        ) else {
            print("[LlamaService] recreateLLMInstance: Failed to create new LLM instance")
            return false
        }

        bot = newLLM
        print("[LlamaService] recreateLLMInstance: Created fresh LLM instance with \(tokenLimit) token limit")
        return true
    }

    func generate(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                guard let currentBot = self.bot else {
                    print("[LlamaService] ERROR: bot is nil at start of generate")
                    continuation.yield("Error: AI model is not loaded. Please restart the app.")
                    continuation.finish()
                    return
                }

                // Save current history BEFORE recreation (as array of tuples)
                // We store as simple Bool + String to avoid any type issues with LLM.Role
                var savedHistoryData: [(isUser: Bool, content: String)] = []
                for entry in currentBot.history {
                    // Check role by comparing with .user enum case
                    let isUser = (entry.role == .user)
                    savedHistoryData.append((isUser: isUser, content: entry.content))
                    print("[LlamaService] Saved entry - isUser: \(isUser), content: \(entry.content.prefix(30))...")
                }
                print("[LlamaService] Total saved: \(savedHistoryData.count) history entries")

                // ALWAYS recreate LLM to reset KV cache (workaround for Issue #50)
                print("[LlamaService] Recreating LLM to reset KV cache...")

                guard await self.recreateLLMInstance() else {
                    print("[LlamaService] ERROR: recreateLLMInstance failed")
                    continuation.yield("Error: Could not reload AI model. Please restart the app.")
                    continuation.finish()
                    return
                }

                guard let bot = self.bot else {
                    print("[LlamaService] ERROR: bot is nil after recreation")
                    continuation.yield("Error: AI model is not loaded. Please restart the app.")
                    continuation.finish()
                    return
                }

                // Restore saved history to the NEW instance
                bot.history.removeAll()
                for entry in savedHistoryData {
                    if entry.isUser {
                        bot.history.append((.user, entry.content))
                    } else {
                        bot.history.append((.bot, entry.content))
                    }
                }
                print("[LlamaService] Restored \(bot.history.count) history entries to new instance")

                // Generate response - LLM.swift will format prompt with history
                print("[LlamaService] Generating response for: \(prompt.prefix(50))...")
                await bot.respond(to: prompt)

                var response = bot.output.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[LlamaService] Raw response length: \(response.count)")
                print("[LlamaService] Raw response preview: \(response.prefix(100))...")
                print("[LlamaService] New history count: \(bot.history.count)")

                response = self.cleanResponse(response)
                print("[LlamaService] Cleaned response length: \(response.count)")

                if response.isEmpty || response == "..." || response.count < 3 {
                    print("[LlamaService] WARNING: Response too short or empty, returning error message")
                    response = "I'm having trouble generating a response. Please try again."
                }

                continuation.yield(response)
                continuation.finish()
            }
        }
    }

    private func cleanResponse(_ response: String) -> String {
        var cleaned = response

        // Remove common artifacts from the response
        let patternsToRemove = [
            "assistant", "Assistant:", "Assistant",
            "user", "User:", "User",
            "Q:", "A:",
            "<|", "|>",
            "Human:", "AI:",
            "###", "```",
            "[INST]", "[/INST]",
            "<<SYS>>", "<</SYS>>"
        ]

        for pattern in patternsToRemove {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "")
        }

        // Remove lines that are just role labels
        let lines = cleaned.components(separatedBy: "\n")
        var cleanedLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip empty lines or lines that look like role markers
            if trimmed.isEmpty { continue }
            if trimmed.lowercased() == "assistant" { continue }
            if trimmed.lowercased() == "user" { continue }
            if trimmed.hasPrefix("Q:") || trimmed.hasPrefix("A:") { continue }

            cleanedLines.append(line)
        }

        cleaned = cleanedLines.joined(separator: "\n")

        // Final trim
        cleaned = cleaned.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // If response is repeating, take only the first unique part
        if let firstOccurrence = findRepeatingPattern(in: cleaned) {
            cleaned = firstOccurrence
        }

        return cleaned
    }

    private func findRepeatingPattern(in text: String) -> String? {
        let words = text.components(separatedBy: .whitespaces)
        guard words.count > 10 else { return nil }

        // Look for repetition by finding duplicate phrases
        let halfLength = words.count / 2
        let firstHalf = words.prefix(halfLength).joined(separator: " ")
        let secondHalf = words.suffix(halfLength).joined(separator: " ")

        // If first half appears in second half, likely repeating
        if secondHalf.contains(firstHalf.prefix(50)) {
            return firstHalf.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }

        return nil
    }

    // Simple non-streaming response (for one-off queries that don't need history)
    func getResponse(prompt: String, clearHistory: Bool = false) async throws -> String {
        guard let bot = bot else {
            throw LlamaError.modelNotLoaded
        }

        // Only clear history if explicitly requested (e.g., for utility queries)
        if clearHistory {
            bot.history.removeAll()
        }

        await bot.respond(to: prompt)

        var response = bot.output
        response = response.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        if response.isEmpty {
            throw LlamaError.generationFailed("Empty response from model")
        }

        return response
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
