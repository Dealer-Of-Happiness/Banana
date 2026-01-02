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
        template: .llama()
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
        progress(0.1)
        guard let llm = await LLM(from: huggingFaceModel) else {
            throw LlamaError.downloadFailed("Failed to download model from HuggingFace")
        }
        bot = llm
        progress(1.0)
    }

    func loadModel() async throws {
        if bot != nil {
            return
        }

        guard let llm = await LLM(from: huggingFaceModel) else {
            throw LlamaError.modelNotLoaded
        }

        llm.maxTokenCount = maxTokens
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

                    // LLM.swift respond updates bot.output property
                    await bot.respond(to: prompt)
                    continuation.yield(bot.output)
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

        await bot.respond(to: prompt)
        return bot.output
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
