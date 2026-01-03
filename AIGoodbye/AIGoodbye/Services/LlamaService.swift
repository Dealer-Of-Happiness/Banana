//
//  LlamaService.swift
//  AIGoodbye
//
//  Local Llama model inference service using LLM.swift
//

import Foundation
import LLM

actor LlamaService {
    private var bot: LLM?
    private let temperature: Float
    private let maxTokens: Int
    private var currentModelId: String?

    // Download state - observable from outside
    nonisolated(unsafe) static var downloadedBytes: Int64 = 0
    nonisolated(unsafe) static var totalBytes: Int64 = 0
    nonisolated(unsafe) static var isDownloading: Bool = false

    init(temperature: Double = 0.7, contextWindow: Int = 2048) {
        self.temperature = Float(temperature)
        self.maxTokens = contextWindow
    }

    // MARK: - Model Management

    @MainActor
    private func getModelManager() -> ModelManager {
        ModelManager.shared
    }

    func loadModel() async throws {
        let manager = await getModelManager()
        let model = await manager.currentModel

        // If already loaded with same model, skip
        if bot != nil && currentModelId == model.id {
            return
        }

        // Unload previous model
        bot = nil
        currentModelId = nil

        // Check if model is downloaded
        let isDownloaded = await manager.isModelDownloaded(model)
        if !isDownloaded {
            // Download the default model
            try await downloadModel(model)
        }

        // Get model path and load
        let modelURL = await manager.modelPath(for: model)
        let template = templateForModel(model)

        // Verify file exists
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LlamaError.modelNotFound
        }

        guard let llm = LLM(from: modelURL, template: template) else {
            throw LlamaError.modelLoadFailed("Failed to initialize LLM from: \(modelURL.path)")
        }

        bot = llm
        currentModelId = model.id
    }

    func loadSpecificModel(_ model: AIModel) async throws {
        // Unload previous model
        bot = nil
        currentModelId = nil

        let manager = await getModelManager()
        let modelURL = await manager.modelPath(for: model)
        let template = templateForModel(model)

        // Verify file exists
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LlamaError.modelNotFound
        }

        guard let llm = LLM(from: modelURL, template: template) else {
            throw LlamaError.modelLoadFailed("Failed to initialize LLM from: \(modelURL.path)")
        }

        bot = llm
        currentModelId = model.id
    }

    private func templateForModel(_ model: AIModel) -> Template {
        switch model.templateType {
        case .llama3:
            // Use chatML as fallback for llama3
            return .chatML()
        case .gemma:
            return .gemma
        case .phi:
            // Use chatML as fallback for phi
            return .chatML()
        case .chatml:
            return .chatML()
        case .alpaca:
            return .alpaca()
        }
    }

    private func downloadModel(_ model: AIModel) async throws {
        let manager = await getModelManager()

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

    // MARK: - Text Generation

    func generate(
        prompt: String,
        history: [(role: String, content: String)] = []
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let bot = self.bot else {
                        throw LlamaError.modelNotLoaded
                    }

                    // Clear previous history
                    bot.history.removeAll()

                    // Build a simple prompt without role labels
                    var contextPrompt = ""

                    // Add minimal context
                    if !history.isEmpty {
                        for message in history.suffix(2) {
                            if message.role == "user" {
                                contextPrompt += "Q: \(message.content)\n"
                            } else if message.role == "assistant" {
                                contextPrompt += "A: \(message.content)\n"
                            }
                        }
                    }

                    // Add current question
                    contextPrompt += "Q: \(prompt)\nA:"

                    // Generate response
                    await bot.respond(to: contextPrompt)

                    // Get the response from bot's output
                    var response = bot.output

                    // Aggressive cleanup of response
                    response = self.cleanResponse(response)

                    // Return the response
                    if response.isEmpty || response == "..." || response.count < 2 {
                        continuation.yield("I couldn't generate a response. Please try again.")
                    } else {
                        continuation.yield(response)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
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

    // Simple non-streaming response
    func getResponse(prompt: String) async throws -> String {
        guard let bot = bot else {
            throw LlamaError.modelNotLoaded
        }

        bot.history.removeAll()

        let contextPrompt = "You are AI goodbye, a helpful assistant. Be concise.\n\nUser: \(prompt)\nAssistant:"
        await bot.respond(to: contextPrompt)

        var response = bot.output
        response = response.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        if let range = response.range(of: "User:") {
            response = String(response[..<range.lowerBound])
        }

        return response.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
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
