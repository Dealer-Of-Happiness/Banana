//
//  LlamaService.swift
//  DOH AI
//
//  Local Llama model inference service using LLM.swift
//

import Foundation
import LLM

actor LlamaService {
    private var bot: LLM?
    private let temperature: Float
    private let maxTokens: Int

    private let modelFileName = "Llama-3.2-1B-Instruct-Q4_K_M.gguf"

    // Using smaller 1B model for better mobile performance
    private let huggingFaceModel = HuggingFaceModel(
        "lmstudio-community/Llama-3.2-1B-Instruct-GGUF",
        .Q4_K_M,
        template: .llama3
    )

    init(temperature: Double = 0.7, contextWindow: Int = 2048) {
        self.temperature = Float(temperature)
        self.maxTokens = contextWindow
    }

    // MARK: - Model Management

    var modelPath: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("models/\(modelFileName)")
    }

    func isModelDownloaded() -> Bool {
        FileManager.default.fileExists(atPath: modelPath.path)
    }

    func downloadModel(progress: @escaping (Double) -> Void) async throws {
        // LLM.swift handles downloading automatically when initializing from HuggingFace
        // We'll use this to show progress indication
        progress(0.1)

        // Initialize from HuggingFace - this downloads the model
        guard let llm = await LLM(from: huggingFaceModel) else {
            throw LlamaError.downloadFailed("Failed to download model from HuggingFace")
        }

        bot = llm
        progress(1.0)
    }

    func loadModel() async throws {
        // If bot is already loaded, we're done
        if bot != nil {
            return
        }

        // Try to load from HuggingFace (handles caching internally)
        guard let llm = await LLM(from: huggingFaceModel) else {
            throw LlamaError.modelNotLoaded
        }

        // Configure parameters
        llm.maxTokenCount = maxTokens
        llm.topP = 0.9

        bot = llm
    }

    func unloadModel() {
        bot = nil
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

                    // Build conversation history for context
                    var messages: [Chat.Message] = history.map { msg in
                        Chat.Message(
                            role: msg.role == "user" ? .user : .bot,
                            content: msg.content
                        )
                    }

                    // Preprocess with history
                    let processedPrompt = bot.preprocess(prompt, messages)

                    // Get completion with streaming
                    // LLM.swift's respond method handles streaming internally
                    await bot.respond(to: prompt, with: messages) { delta in
                        continuation.yield(delta)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // Simple non-streaming response
    func getResponse(prompt: String) async throws -> String {
        guard let bot = bot else {
            throw LlamaError.modelNotLoaded
        }

        return await bot.respond(to: prompt)
    }

    // MARK: - Vision Analysis

    func analyzeImage(_ imageData: Data, prompt: String) async throws -> String {
        guard bot != nil else {
            throw LlamaError.modelNotLoaded
        }

        // Vision requires a multimodal model
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
            return "Local AI requires a physical iPhone device. The iOS Simulator doesn't support Metal GPU acceleration needed for AI inference. Please run on a real device."
        }
    }
}
