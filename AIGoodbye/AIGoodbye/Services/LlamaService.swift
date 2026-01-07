//
//  LlamaService.swift
//  AIGoodbye
//
//  Local Llama model inference service using LLM.swift
//  Multi-turn workaround: Pass full conversation history in each prompt
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
        let url = manager.modelPath(for: model)
        let fileManager = FileManager.default

        // Check if model is downloaded and valid
        var needsDownload = !fileManager.fileExists(atPath: url.path)

        if !needsDownload {
            // Check file size - if too small, the download was incomplete
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

        // Get template for the model
        let template = templateForModel(model)

        // Verify file exists after potential download
        guard fileManager.fileExists(atPath: url.path) else {
            throw LlamaError.modelNotFound
        }

        // Try to load the model with settings from user preferences
        let tokenLimit = getMaxTokenCount()

        // Try loading with retry - LLM might fail due to memory pressure, not corrupted file
        for attempt in 1...3 {
            print("[LlamaService] Loading model attempt \(attempt)/3...")

            // Give memory time to settle between attempts
            if attempt > 1 {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second
            }

            if let llm = LLM(
                from: url,
                template: template,
                maxTokenCount: tokenLimit
            ) {
                bot = llm
                modelURL = url
                currentModelId = model.id
                print("[LlamaService] Model loaded successfully on attempt \(attempt)")
                return
            }

            print("[LlamaService] LLM init failed on attempt \(attempt)")
        }

        // All attempts failed - but DON'T delete the file, it might be memory issues
        throw LlamaError.modelLoadFailed("Could not initialize AI model. Try closing other apps to free memory, then restart.")
    }

    private func templateForModel(_ model: AIModel) -> Template {
        // Use basic templates without system prompt - we handle system prompt in the manual prompt building
        switch model.templateType {
        case .mistral:
            return .mistral
        case .llama3:
            return .llama("")  // Empty system prompt - we add it in the prompt
        case .gemma:
            return .gemma
        case .phi:
            return .chatML()  // No system prompt - we add it in the prompt
        case .chatml:
            return .chatML()  // No system prompt - we add it in the prompt
        case .alpaca:
            return .alpaca("")
        }
    }

    func loadSpecificModel(_ model: AIModel) async throws {
        bot = nil
        currentModelId = nil

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
        let tokenLimit = getMaxTokenCount()

        guard let llm = LLM(from: url, template: template, maxTokenCount: tokenLimit) else {
            try? fileManager.removeItem(at: url)
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
        // Check modelURL since bot may be nil between generations
        modelURL != nil && currentModelId != nil
    }

    /// Reload the model with current settings (e.g., after context window change)
    func reloadModel() async throws {
        guard let modelId = currentModelId,
              let model = AIModel.model(withId: modelId) else {
            throw LlamaError.modelNotLoaded
        }

        print("[LlamaService] Reloading model with new settings...")

        // Unload current model
        bot = nil

        // Reload with current settings
        try await loadModelInternal(model)

        print("[LlamaService] Model reloaded successfully")
    }

    /// Reset conversation - clears the bot's internal conversation history
    func resetConversation() {
        print("[LlamaService] resetConversation called - clearing bot history")
        bot?.history.removeAll()
    }

    /// Restore history - no-op since we pass history in each prompt
    func restoreHistory(_ messages: [(role: String, content: String)]) {
        print("[LlamaService] restoreHistory called - history passed in generate() instead")
    }

    // MARK: - Text Generation

    /// Generate response with full conversation history in prompt
    /// Key: Clear bot.output before each respond() call
    func generate(prompt: String, conversationHistory: [(role: String, content: String)] = []) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                guard let modelId = self.currentModelId,
                      let model = AIModel.model(withId: modelId) else {
                    print("[LlamaService] ERROR: Model not configured")
                    continuation.yield("Error: AI model is not loaded. Please restart the app.")
                    continuation.finish()
                    return
                }

                // Ensure we have a bot instance
                if self.bot == nil {
                    print("[LlamaService] Bot is nil, reloading model...")
                    do {
                        try await self.loadModel()
                    } catch {
                        print("[LlamaService] Failed to reload model: \(error)")
                        continuation.yield("Error: Could not load AI model. Please restart the app.")
                        continuation.finish()
                        return
                    }
                }

                guard let bot = self.bot else {
                    continuation.yield("Error: AI model is not loaded.")
                    continuation.finish()
                    return
                }

                // Build full conversation prompt with history
                let fullPrompt = self.buildConversationPrompt(
                    currentMessage: prompt,
                    history: conversationHistory,
                    model: model
                )

                print("[LlamaService] Generating response...")
                print("[LlamaService] History messages: \(conversationHistory.count)")
                print("[LlamaService] Prompt length: \(fullPrompt.count) chars")

                // CRITICAL: Clear output before calling respond
                bot.output = ""

                // Generate response
                await bot.respond(to: fullPrompt)

                let rawOutput = bot.output
                print("[LlamaService] Raw output length: \(rawOutput.count)")

                var response = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                response = self.cleanResponse(response)

                if response.isEmpty || response == "..." || response.count < 3 {
                    print("[LlamaService] WARNING: Empty response, retrying with fresh bot...")
                    // Try recreating the bot for a fresh start
                    self.bot = nil
                    do {
                        try await self.loadModel()
                        if let freshBot = self.bot {
                            freshBot.output = ""
                            await freshBot.respond(to: fullPrompt)
                            response = self.cleanResponse(freshBot.output.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    } catch {
                        print("[LlamaService] Failed to recreate bot: \(error)")
                    }

                    if response.isEmpty || response.count < 3 {
                        response = "I'm having trouble generating a response. Please try again."
                    }
                }

                continuation.yield(response)
                continuation.finish()
            }
        }
    }

    /// Build a complete conversation prompt with history
    private func buildConversationPrompt(currentMessage: String, history: [(role: String, content: String)], model: AIModel) -> String {
        // For chatML format (Qwen), build proper conversation structure
        if model.templateType == .chatml {
            return buildChatMLPrompt(currentMessage: currentMessage, history: history)
        }

        // For other formats, use a simpler approach
        return buildSimplePrompt(currentMessage: currentMessage, history: history)
    }

    private func buildChatMLPrompt(currentMessage: String, history: [(role: String, content: String)]) -> String {
        var prompt = ""

        // System message with full AI identity
        let systemMessage = "You are AiGoodbye, a helpful AI assistant created by Dealer Of Happiness. You run completely offline on the user's device. Be concise, helpful, and friendly."
        prompt += "<|im_start|>system\n\(systemMessage)<|im_end|>\n"

        // Add conversation history (last 4 exchanges to keep context manageable)
        for msg in history.suffix(4) {
            let role = msg.role.lowercased() == "user" ? "user" : "assistant"
            prompt += "<|im_start|>\(role)\n\(msg.content)<|im_end|>\n"
        }

        // Add current user message
        prompt += "<|im_start|>user\n\(currentMessage)<|im_end|>\n"

        // Start assistant response
        prompt += "<|im_start|>assistant\n"

        return prompt
    }

    private func buildSimplePrompt(currentMessage: String, history: [(role: String, content: String)]) -> String {
        var prompt = "You are AiGoodbye, a helpful AI assistant.\n\n"

        // Add conversation history
        if !history.isEmpty {
            prompt += "Previous conversation:\n"
            for msg in history.suffix(6) {
                let role = msg.role.lowercased() == "user" ? "Human" : "Assistant"
                prompt += "\(role): \(msg.content)\n"
            }
            prompt += "\n"
        }

        prompt += "Human: \(currentMessage)\nAssistant:"

        return prompt
    }

    private func cleanResponse(_ response: String) -> String {
        var cleaned = response

        // Remove common artifacts
        let patternsToRemove = [
            "<|im_end|>", "<|im_start|>",
            "<|endoftext|>", "<|end|>",
            "assistant", "Assistant:", "Assistant",
            "<|", "|>",
            "Human:", "AI:",
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
            if trimmed.isEmpty { continue }
            if trimmed.lowercased() == "assistant" { continue }
            if trimmed.lowercased() == "user" { continue }
            if trimmed.lowercased() == "system" { continue }
            if trimmed.hasPrefix("Q:") || trimmed.hasPrefix("A:") { continue }

            cleanedLines.append(line)
        }

        cleaned = cleanedLines.joined(separator: "\n")
        cleaned = cleaned.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // If response is repeating, take only first unique part
        if let firstOccurrence = findRepeatingPattern(in: cleaned) {
            cleaned = firstOccurrence
        }

        return cleaned
    }

    private func findRepeatingPattern(in text: String) -> String? {
        let words = text.components(separatedBy: .whitespaces)
        guard words.count > 10 else { return nil }

        let halfLength = words.count / 2
        let firstHalf = words.prefix(halfLength).joined(separator: " ")
        let secondHalf = words.suffix(halfLength).joined(separator: " ")

        if secondHalf.contains(firstHalf.prefix(50)) {
            return firstHalf.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }

        return nil
    }

    // Simple non-streaming response
    func getResponse(prompt: String, clearHistory: Bool = false) async throws -> String {
        guard let modelId = currentModelId,
              let model = AIModel.model(withId: modelId),
              let url = modelURL else {
            throw LlamaError.modelNotLoaded
        }

        // Create fresh instance
        let template = templateForModel(model)
        let tokenLimit = getMaxTokenCount()

        guard let freshBot = LLM(from: url, template: template, maxTokenCount: tokenLimit) else {
            throw LlamaError.modelLoadFailed("Could not create LLM instance")
        }

        await freshBot.respond(to: prompt)

        let response = freshBot.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if response.isEmpty {
            throw LlamaError.generationFailed("Empty response from model")
        }

        return cleanResponse(response)
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
