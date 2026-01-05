//
//  LlamaService.swift
//  AIGoodbye
//
//  Local Llama model inference service using llmfarm_core.swift
//

import Foundation
import llmfarm_core

@MainActor
class LlamaService {
    private var ai: AI?
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
        if ai != nil && currentModelId == model.id {
            return
        }

        // Unload previous model
        ai = nil
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

        // Verify file exists after potential download
        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw LlamaError.modelNotFound
        }

        // Try to load the model with settings from user preferences
        do {
            try await loadAIModel(modelPath: modelURL.path, model: model)
            currentModelId = model.id
        } catch {
            // Mark this model as failed so we delete it next time
            UserDefaults.standard.set(model.id, forKey: lastFailedKey)
            // Delete the file
            try? fileManager.removeItem(at: modelURL)
            throw LlamaError.modelLoadFailed("Model failed to initialize. File deleted - restart app to re-download.")
        }
    }

    private func loadAIModel(modelPath: String, model: AIModel) async throws {
        // Create AI instance
        let chatName = "aigoodbye_chat"
        let newAI = AI(_modelPath: modelPath, _chatName: chatName)

        // Configure context parameters
        var contextParams: ModelAndContextParams = .default
        contextParams.context = getMaxTokenCount()
        contextParams.use_metal = true
        contextParams.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))

        // Set temperature
        contextParams.temp = temperature

        // Determine inference type based on model
        let inferenceType = inferenceTypeForModel(model)

        // Load model on background thread
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try newAI.loadModel(inferenceType, contextParams: contextParams)

                    // Set prompt format based on model template
                    if let llmModel = newAI.model {
                        llmModel.promptFormat = self.promptFormatForModel(model)
                        llmModel.contextParams.system_prompt = "You are AiGoodbye, a helpful, friendly AI assistant. Be concise and helpful in your responses."
                    }

                    DispatchQueue.main.async {
                        self.ai = newAI
                        print("[LlamaService] Model loaded successfully with llmfarm_core")
                        continuation.resume()
                    }
                } catch {
                    DispatchQueue.main.async {
                        print("[LlamaService] Failed to load model: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func inferenceTypeForModel(_ model: AIModel) -> ModelInference {
        // Most GGUF models use LLama inference
        return .LLama_gguf
    }

    private func promptFormatForModel(_ model: AIModel) -> ModelPromptStyle {
        switch model.templateType {
        case .mistral:
            return .Mistral
        case .llama3:
            return .LLaMa
        case .gemma:
            return .Gemma
        case .phi:
            return .Phi3
        case .chatml:
            return .ChatML
        case .alpaca:
            return .Alpaca
        }
    }

    func loadSpecificModel(_ model: AIModel) async throws {
        // Unload previous model
        ai = nil
        currentModelId = nil

        let manager = getModelManager()
        let modelURL = manager.modelPath(for: model)
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

        do {
            try await loadAIModel(modelPath: modelURL.path, model: model)
            currentModelId = model.id
        } catch {
            try? fileManager.removeItem(at: modelURL)
            throw LlamaError.modelLoadFailed("Model file may be corrupted. Please download again.")
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
        ai = nil
        currentModelId = nil
    }

    func isModelLoaded() -> Bool {
        ai != nil && ai?.model != nil
    }

    /// Reset conversation history for starting a new chat
    /// With llmfarm_core, we need to reset the AI to clear KV cache
    func resetConversation() {
        guard let currentAI = ai, let modelId = currentModelId, let model = AIModel.model(withId: modelId) else {
            print("[LlamaService] resetConversation: No AI loaded")
            return
        }

        // Save model path before resetting
        let modelPath = getModelManager().modelPath(for: model).path

        print("[LlamaService] Resetting conversation - will recreate AI on next message")

        // For llmfarm_core, setting ai = nil will clear the context
        // The model will be reloaded on the next generate call if needed
        // This is a clean way to reset the KV cache
        ai = nil

        // Immediately reload the model to avoid delay on first message
        Task {
            do {
                try await loadAIModel(modelPath: modelPath, model: model)
                print("[LlamaService] Model reloaded after conversation reset")
            } catch {
                print("[LlamaService] Failed to reload model after reset: \(error)")
            }
        }
    }

    /// Restore conversation history from saved messages (for resuming conversations)
    func restoreHistory(_ messages: [(role: String, content: String)]) {
        // llmfarm_core handles history internally through its context
        // For resuming, we would need to replay the conversation
        // For now, we log this - the context will build up naturally
        print("[LlamaService] Note: History restore requested for \(messages.count) messages")
        print("[LlamaService] Context will build up naturally through conversation")
    }

    // MARK: - Text Generation

    func generate(prompt: String, conversationHistory: [(role: String, content: String)] = []) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                guard let ai = self.ai, let model = ai.model else {
                    print("[LlamaService] ERROR: AI or model is nil")
                    continuation.yield("Error: AI model is not loaded. Please restart the app.")
                    continuation.finish()
                    return
                }

                print("[LlamaService] Generating response with llmfarm_core...")
                print("[LlamaService] Current nPast: \(model.nPast)")

                // Build the input - llmfarm_core handles history via nPast
                // For context, include recent history in the prompt if this is a new context
                var fullPrompt = prompt
                if model.nPast == 0 && !conversationHistory.isEmpty {
                    // Only include history if we're starting fresh
                    let recent = conversationHistory.suffix(4)
                    var context = ""
                    for msg in recent {
                        let role = msg.role.lowercased() == "user" ? "User" : "Assistant"
                        context += "\(role): \(msg.content)\n"
                    }
                    fullPrompt = context + "User: \(prompt)"
                }

                var responseText = ""
                var tokenCount = 0
                let maxTokens = 512

                // Use conversation method for streaming
                ai.conversation(
                    fullPrompt,
                    { token, time in
                        // Token callback - called for each generated token
                        responseText += token
                        tokenCount += 1

                        // Check for max tokens
                        if tokenCount >= maxTokens {
                            return true // Stop generation
                        }
                        return false
                    },
                    { info, value in
                        // Info callback - can be used for debugging
                        print("[LlamaService] Info: \(info)")
                    },
                    { finalOutput in
                        // Completion callback
                        DispatchQueue.main.async {
                            var response = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                            response = self.cleanResponse(response)

                            if response.isEmpty || response == "..." || response.count < 3 {
                                print("[LlamaService] WARNING: Empty response")
                                response = "I'm having trouble generating a response. Please try again."
                            }

                            print("[LlamaService] Generated \(tokenCount) tokens, response length: \(response.count)")
                            continuation.yield(response)
                            continuation.finish()
                        }
                    },
                    system_prompt: nil, // System prompt already set in model
                    img_path: nil
                )
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
        guard let ai = ai, let model = ai.model else {
            throw LlamaError.modelNotLoaded
        }

        // If clearHistory is requested, reset the context
        if clearHistory {
            // For llmfarm_core, we would need to recreate the model to clear context
            // For now, just proceed - the caller should use resetConversation() before this
            print("[LlamaService] Note: clearHistory requested but context persists in llmfarm_core")
        }

        var responseText = ""
        var tokenCount = 0
        let maxTokens = 256

        return try await withCheckedThrowingContinuation { continuation in
            ai.conversation(
                prompt,
                { token, time in
                    responseText += token
                    tokenCount += 1
                    return tokenCount >= maxTokens
                },
                nil,
                { _ in
                    let response = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if response.isEmpty {
                        continuation.resume(throwing: LlamaError.generationFailed("Empty response from model"))
                    } else {
                        continuation.resume(returning: response)
                    }
                },
                system_prompt: nil,
                img_path: nil
            )
        }
    }

    // MARK: - Vision Analysis

    func analyzeImage(_ imageData: Data, prompt: String) async throws -> String {
        guard ai != nil else {
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
