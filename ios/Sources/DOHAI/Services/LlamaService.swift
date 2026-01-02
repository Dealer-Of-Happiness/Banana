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
    private var modelPathURL: URL?

    private let modelFileName = "Llama-3.2-1B-Instruct-Q4_K_M.gguf"
    private let modelDownloadURL = URL(string: "https://huggingface.co/lmstudio-community/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!

    // Download state - observable from outside
    nonisolated(unsafe) static var downloadedBytes: Int64 = 0
    nonisolated(unsafe) static var totalBytes: Int64 = 0
    nonisolated(unsafe) static var isDownloading: Bool = false

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

    func loadModel() async throws {
        if bot != nil {
            return
        }

        // Check if model already exists locally
        if !isModelDownloaded() {
            try await downloadModelWithProgress()
        }

        // Store the path for later use
        modelPathURL = modelPath

        // Load from local file
        guard let llm = LLM(from: modelPath, template: .chatML()) else {
            throw LlamaError.modelNotLoaded
        }

        bot = llm
    }

    private func downloadModelWithProgress() async throws {
        // Create models directory
        let modelsDir = modelPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        LlamaService.isDownloading = true
        LlamaService.downloadedBytes = 0
        LlamaService.totalBytes = 0

        // Download with progress tracking
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: modelDownloadURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            LlamaService.isDownloading = false
            throw LlamaError.downloadFailed("Server returned error")
        }

        LlamaService.totalBytes = response.expectedContentLength

        // Create file and write
        FileManager.default.createFile(atPath: modelPath.path, contents: nil)
        let handle = try FileHandle(forWritingTo: modelPath)

        var buffer = Data()
        let bufferSize = 1024 * 1024 // 1MB buffer

        for try await byte in asyncBytes {
            buffer.append(byte)
            LlamaService.downloadedBytes += 1

            if buffer.count >= bufferSize {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        // Write remaining buffer
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }

        try handle.close()
        LlamaService.isDownloading = false
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
                    // Create a fresh LLM instance for each request to avoid state issues
                    guard let path = self.modelPathURL else {
                        throw LlamaError.modelNotLoaded
                    }

                    guard let freshBot = LLM(from: path, template: .chatML()) else {
                        throw LlamaError.modelNotLoaded
                    }

                    // Build the prompt with context
                    let fullPrompt = self.buildPrompt(prompt: prompt, history: history)

                    // Use respond method - the standard LLM.swift API
                    await freshBot.respond(to: fullPrompt)
                    var response = freshBot.output

                    // Clean up the response - remove any trailing artifacts
                    response = response.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Return the response
                    if response.isEmpty || response == "..." || response.count < 3 {
                        continuation.yield("I'm still learning. Could you try asking your question differently?")
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

    private func buildPrompt(prompt: String, history: [(role: String, content: String)]) -> String {
        var fullPrompt = "You are DOH AI, a helpful assistant. Answer questions clearly and concisely.\n\n"

        // Add conversation history (keep last 6 messages)
        for message in history.suffix(6) {
            if message.role == "user" {
                fullPrompt += "User: \(message.content)\n"
            } else if message.role == "assistant" {
                fullPrompt += "Assistant: \(message.content)\n"
            }
        }

        // Add current prompt
        fullPrompt += "User: \(prompt)\nAssistant:"

        return fullPrompt
    }

    // Simple non-streaming response
    func getResponse(prompt: String) async throws -> String {
        guard let path = modelPathURL else {
            throw LlamaError.modelNotLoaded
        }

        guard let freshBot = LLM(from: path, template: .chatML()) else {
            throw LlamaError.modelNotLoaded
        }

        await freshBot.respond(to: prompt)
        return freshBot.output
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
