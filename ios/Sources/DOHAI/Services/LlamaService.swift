//
//  LlamaService.swift
//  DOH AI
//
//  Local Llama 3.2 model inference service
//

import Foundation

actor LlamaService {
    private let settings: SettingsManager
    private var model: LlamaModel?

    private let modelFileName = "llama-3.2-3b-instruct-q4_k_m.gguf"
    private let modelURL = URL(string: "https://huggingface.co/lmstudio-community/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!

    init(settings: SettingsManager) {
        self.settings = settings
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

        model = try LlamaModel(
            path: modelPath.path,
            contextLength: settings.contextWindow
        )
    }

    func unloadModel() {
        model = nil
    }

    // MARK: - Text Generation

    func generate(
        prompt: String,
        history: [(role: String, content: String)] = []
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let fullPrompt = buildPrompt(userMessage: prompt, history: history)

                    guard let model = model else {
                        throw LlamaError.modelNotLoaded
                    }

                    try await model.generate(
                        prompt: fullPrompt,
                        temperature: Float(settings.temperature),
                        maxTokens: settings.contextWindow
                    ) { token in
                        continuation.yield(token)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func buildPrompt(userMessage: String, history: [(role: String, content: String)]) -> String {
        var prompt = """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>

        You are DOH AI, a helpful, harmless, and honest AI assistant created by Dealer Of Happiness.
        You run locally on the user's device for maximum privacy.
        Provide accurate, helpful, and concise responses.
        If you don't know something, say so honestly.
        Respect user privacy and never ask for personal information unnecessarily.
        <|eot_id|>
        """

        // Add conversation history
        for message in history.suffix(10) {
            let role = message.role == "user" ? "user" : "assistant"
            prompt += "<|start_header_id|>\(role)<|end_header_id|>\n\n\(message.content)<|eot_id|>"
        }

        // Add current message
        prompt += "<|start_header_id|>user<|end_header_id|>\n\n\(userMessage)<|eot_id|>"
        prompt += "<|start_header_id|>assistant<|end_header_id|>\n\n"

        return prompt
    }

    // MARK: - Vision Analysis

    func analyzeImage(_ imageData: Data, prompt: String) async throws -> String {
        // Llama 3.2 3B supports vision
        // In production, use the multimodal capabilities
        guard let model = model else {
            throw LlamaError.modelNotLoaded
        }

        var result = ""
        let visionPrompt = """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>
        You are analyzing an image. Describe what you see accurately.
        <|eot_id|>
        <|start_header_id|>user<|end_header_id|>
        [Image attached]
        \(prompt)
        <|eot_id|>
        <|start_header_id|>assistant<|end_header_id|>

        """

        try await model.generate(
            prompt: visionPrompt,
            temperature: Float(settings.temperature),
            maxTokens: 1024
        ) { token in
            result += token
        }

        return result
    }
}

// MARK: - Llama Model Wrapper

class LlamaModel {
    private let modelPath: String
    private let contextLength: Int

    init(path: String, contextLength: Int = 4096) throws {
        self.modelPath = path
        self.contextLength = contextLength

        // In production, initialize llama.cpp context here
        // llama_init_from_file(path, ...)
    }

    func generate(
        prompt: String,
        temperature: Float,
        maxTokens: Int,
        onToken: @escaping (String) -> Void
    ) async throws {
        // In production, this would use llama.cpp for inference
        // For now, placeholder implementation

        let sampleResponse = """
        I'm DOH AI, your local AI assistant running entirely on your device. \
        I can help you with questions, document analysis, and more - all while \
        keeping your data private. How can I assist you today?
        """

        for char in sampleResponse {
            try await Task.sleep(nanoseconds: 15_000_000) // 15ms per character
            onToken(String(char))
        }
    }

    deinit {
        // Clean up llama.cpp resources
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
