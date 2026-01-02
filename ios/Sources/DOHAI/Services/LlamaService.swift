//
//  LlamaService.swift
//  DOH AI
//
//  Local Llama 3.2 model inference service
//

import Foundation
import llmfarm_core

actor LlamaService {
    private var ai: AI?
    private var temperature: Float = 0.7
    private var contextWindow: Int32 = 4096

    private let modelFileName = "llama-3.2-3b-instruct-q4_k_m.gguf"
    private let modelURL = URL(string: "https://huggingface.co/lmstudio-community/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!

    init(settings: SettingsManager) {
        self.temperature = Float(settings.temperature)
        self.contextWindow = Int32(settings.contextWindow)
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
        // Create models directory
        let modelsDir = modelPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        // Download with progress
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: modelURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw LlamaError.downloadFailed("Invalid response")
        }

        let totalBytes = response.expectedContentLength
        var downloadedBytes: Int64 = 0

        // Create file
        FileManager.default.createFile(atPath: modelPath.path, contents: nil)
        let handle = try FileHandle(forWritingTo: modelPath)

        var buffer = Data()
        let bufferSize = 1024 * 1024 // 1MB buffer

        for try await byte in asyncBytes {
            buffer.append(byte)
            downloadedBytes += 1

            if buffer.count >= bufferSize {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                progress(Double(downloadedBytes) / Double(totalBytes))
            }
        }

        // Write remaining buffer
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }

        try handle.close()
        progress(1.0)
    }

    func loadModel() async throws {
        guard isModelDownloaded() else {
            throw LlamaError.modelNotFound
        }

        // Initialize llmfarm_core AI
        ai = AI(_modelPath: modelPath.path, _chatName: "DOH AI Chat")

        guard let ai = ai else {
            throw LlamaError.modelNotLoaded
        }

        // Configure context parameters
        var contextParams = ModelAndContextParams.default
        contextParams.use_metal = true

        // Load model with correct API
        try ai.loadModel(ModelInference.LLama_gguf, contextParams: contextParams)

        // Configure sampling parameters
        if let model = ai.model {
            model.sampleParams.temp = temperature
        }
    }

    func unloadModel() {
        ai = nil
    }

    // MARK: - Text Generation

    func generate(
        prompt: String,
        history: [(role: String, content: String)] = []
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let ai = self.ai, let model = ai.model else {
                        throw LlamaError.modelNotLoaded
                    }

                    let fullPrompt = self.buildPrompt(userMessage: prompt, history: history)

                    // Use llmfarm_core model.predict for generation
                    // Callback returns Bool: true = stop, false = continue
                    let _ = try model.predict(fullPrompt) { str, time in
                        continuation.yield(str)
                        return false // false = continue generating
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func buildPrompt(userMessage: String, history: [(role: String, content: String)]) -> String {
        // For llmfarm_core, we use a simpler prompt format
        // The library handles conversation context internally
        return userMessage
    }

    // MARK: - Vision Analysis

    func analyzeImage(_ imageData: Data, prompt: String) async throws -> String {
        guard ai != nil else {
            throw LlamaError.modelNotLoaded
        }

        // For vision, we'd need a vision-capable model
        // For now, return a placeholder
        return "Image analysis requires a vision-capable model. Please describe what you'd like to know about the image."
    }
}

// MARK: - Errors

enum LlamaError: LocalizedError {
    case modelNotFound
    case modelNotLoaded
    case downloadFailed(String)
    case generationFailed(String)

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
        }
    }
}
