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

    // Failure tracking for auto-recovery
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 2

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

        // Try loading with retry - LLM might fail due to memory pressure, not corrupted file
        for attempt in 1...3 {
            print("[LlamaService] Loading model attempt \(attempt)/3...")

            // Give memory time to settle between attempts
            if attempt > 1 {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second
            }

            // Initialize with proper history limit for long conversations
            // historyLimit controls how many messages the library keeps (default is 8)
            // Setting to 30 allows ~15 conversation exchanges before auto-pruning
            if let llm = LLM(from: url, template: template, historyLimit: 30) {
                bot = llm
                modelURL = url
                currentModelId = model.id
                print("[LlamaService] Model loaded successfully on attempt \(attempt) with historyLimit: 30")
                return
            }

            print("[LlamaService] LLM init failed on attempt \(attempt)")
        }

        // All attempts failed - but DON'T delete the file, it might be memory issues
        throw LlamaError.modelLoadFailed("Could not initialize AI model. Try closing other apps to free memory, then restart.")
    }

    private func templateForModel(_ model: AIModel) -> Template {
        // Include system prompt in template - library will use this for all messages
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

        guard let llm = LLM(from: url, template: template, historyLimit: 30) else {
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
        consecutiveFailures = 0
    }

    /// Restore history from saved conversation
    /// Called when loading an existing conversation to sync bot's internal state
    func restoreHistory(_ messages: [(role: String, content: String)]) {
        guard let bot = bot else {
            print("[LlamaService] restoreHistory called but bot is nil")
            return
        }

        // Clear existing history first
        bot.history.removeAll()

        // Add each message to bot's history
        // The library's history format expects (role, content) tuples
        for message in messages {
            let role = message.0.lowercased()
            let content = message.1

            // Add to history in the format the library expects
            if role == "user" {
                bot.history.append(.user(content))
            } else if role == "assistant" {
                bot.history.append(.bot(content))
            }
        }

        print("[LlamaService] restoreHistory: restored \(bot.history.count) messages")
    }

    /// Force reset - completely destroys and recreates the bot instance
    /// Use this when the model gets into a bad state
    func forceReset() async throws {
        print("[LlamaService] Force reset initiated...")
        bot = nil
        currentModelId = nil
        consecutiveFailures = 0

        // Small delay to let memory settle
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Reload model fresh
        try await loadModel()
        print("[LlamaService] Force reset completed successfully")
    }

    // MARK: - Text Generation

    /// Generate response using LLM.swift's native history management
    /// Key insight: Clear bot.output but NOT bot.history - let library manage conversation state
    func generate(prompt: String, conversationHistory: [(role: String, content: String)] = []) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    guard self.currentModelId != nil else {
                        print("[LlamaService] ERROR: Model not configured")
                        throw LlamaError.modelNotLoaded
                    }

                    // Check if too many consecutive failures - force reset
                    if self.consecutiveFailures >= self.maxConsecutiveFailures {
                        print("[LlamaService] Too many failures (\(self.consecutiveFailures)), forcing reset...")
                        try await self.forceReset()
                    }

                    // Ensure we have a bot instance
                    if self.bot == nil {
                        print("[LlamaService] Bot is nil, reloading model...")
                        try await self.loadModel()
                    }

                    guard let bot = self.bot else {
                        throw LlamaError.modelNotLoaded
                    }

                    print("[LlamaService] Generating response...")
                    print("[LlamaService] Bot history count: \(bot.history.count)")
                    print("[LlamaService] User prompt: \(prompt.prefix(50))...")

                    // CRITICAL FIX: Only clear output, NOT history!
                    // The library appends to output, so we must clear it before each call
                    // But history should be preserved for multi-turn conversations
                    bot.output = ""

                    // Just pass the user message - library handles ChatML formatting and history
                    await bot.respond(to: prompt)

                    var response = bot.output
                    print("[LlamaService] Raw output length: \(response.count)")
                    print("[LlamaService] Bot history count after: \(bot.history.count)")

                    // Clean up response
                    response = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    response = self.cleanResponse(response)

                    if response.isEmpty || response == "..." || response.count < 3 {
                        print("[LlamaService] WARNING: Empty response, retrying with fresh bot...")
                        self.consecutiveFailures += 1

                        // Recreate bot completely - this resets everything
                        self.bot = nil
                        try await self.loadModel()

                        if let freshBot = self.bot {
                            freshBot.output = ""
                            await freshBot.respond(to: prompt)
                            response = self.cleanResponse(freshBot.output.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }

                    if response.isEmpty || response.count < 3 {
                        self.consecutiveFailures += 1
                        continuation.yield("I'm having trouble generating a response. Please try again.")
                    } else {
                        // Success! Reset failure counter
                        self.consecutiveFailures = 0
                        continuation.yield(response)
                    }
                    continuation.finish()

                } catch {
                    print("[LlamaService] Generate error: \(error)")
                    self.consecutiveFailures += 1
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

        guard let freshBot = LLM(from: url, template: template) else {
            throw LlamaError.modelLoadFailed("Could not create LLM instance")
        }

        freshBot.output = ""
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
