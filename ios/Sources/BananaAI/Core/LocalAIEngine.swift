//
//  LocalAIEngine.swift
//  BananaAI
//
//  Core engine for running LLMs locally on iOS using llama.cpp
//

import Foundation

/// Main engine for local AI inference
actor LocalAIEngine {
    private var model: LlamaModel?
    private let knowledgeBase: KnowledgeBase
    private let settings: SettingsManager

    private let modelFileName = "llama-3.2-3b-q4_k_m.gguf"
    private let modelURL = URL(string: "https://huggingface.co/lmstudio-community/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!

    init(knowledgeBase: KnowledgeBase, settings: SettingsManager) {
        self.knowledgeBase = knowledgeBase
        self.settings = settings
    }

    // MARK: - Model Management

    func isModelDownloaded() -> Bool {
        FileManager.default.fileExists(atPath: modelPath.path)
    }

    private var modelPath: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("models/\(modelFileName)")
    }

    func downloadModel(progress: @escaping (Double) -> Void) async throws {
        // Create models directory
        let modelsDir = modelPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        // Download with progress tracking
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: modelURL)

        let totalBytes = response.expectedContentLength
        var downloadedBytes: Int64 = 0

        let fileHandle = try FileHandle(forWritingTo: modelPath)
        defer { try? fileHandle.close() }

        // Create empty file
        FileManager.default.createFile(atPath: modelPath.path, contents: nil)
        let handle = try FileHandle(forWritingTo: modelPath)

        for try await byte in asyncBytes {
            try handle.write(contentsOf: [byte])
            downloadedBytes += 1

            if downloadedBytes % 1_000_000 == 0 { // Update every 1MB
                progress(Double(downloadedBytes) / Double(totalBytes))
            }
        }

        try handle.close()
        progress(1.0)
    }

    func loadModel() async throws {
        guard isModelDownloaded() else {
            throw AIError.modelNotFound
        }

        // Initialize llama.cpp model
        model = try LlamaModel(path: modelPath.path)
    }

    // MARK: - Text Generation

    func generate(
        prompt: String,
        history: some Sequence<ChatMessage>
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Get relevant context from knowledge base
                    let context = await getRelevantContext(for: prompt)

                    // Build full prompt with context and history
                    let fullPrompt = buildPrompt(
                        userMessage: prompt,
                        history: Array(history),
                        context: context
                    )

                    // Generate response
                    guard let model = model else {
                        throw AIError.modelNotLoaded
                    }

                    try await model.generate(prompt: fullPrompt) { token in
                        continuation.yield(token)
                    }

                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - RAG (Retrieval Augmented Generation)

    private func getRelevantContext(for query: String) async -> String {
        let chunks = await knowledgeBase.search(query: query, topK: 3)

        if chunks.isEmpty {
            return ""
        }

        var context = "Use the following information to help answer the question:\n\n"
        for (i, chunk) in chunks.enumerated() {
            context += "[\(i + 1)] \(chunk)\n\n"
        }
        return context
    }

    private func buildPrompt(userMessage: String, history: [ChatMessage], context: String) -> String {
        var prompt = """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>

        You are Banana AI, a helpful assistant running locally on the user's iPhone.
        You provide accurate, helpful responses. If you don't know something, say so.
        Keep responses concise but informative.

        """

        if !context.isEmpty {
            prompt += "\n\(context)\n"
        }

        prompt += "<|eot_id|>"

        // Add conversation history
        for message in history.suffix(10) { // Keep last 10 messages for context
            let role = message.role == .user ? "user" : "assistant"
            prompt += "<|start_header_id|>\(role)<|end_header_id|>\n\n\(message.content)<|eot_id|>"
        }

        // Add current user message
        prompt += "<|start_header_id|>user<|end_header_id|>\n\n\(userMessage)<|eot_id|>"
        prompt += "<|start_header_id|>assistant<|end_header_id|>\n\n"

        return prompt
    }
}

// MARK: - Errors

enum AIError: LocalizedError {
    case modelNotFound
    case modelNotLoaded
    case generationFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "AI model not found. Please download it first."
        case .modelNotLoaded:
            return "AI model is not loaded."
        case .generationFailed(let reason):
            return "Failed to generate response: \(reason)"
        case .downloadFailed(let reason):
            return "Failed to download model: \(reason)"
        }
    }
}

// MARK: - LlamaModel Wrapper

/// Wrapper around llama.cpp for iOS
/// In production, this would use the actual llama.cpp Swift bindings
class LlamaModel {
    private let modelPath: String
    private var context: OpaquePointer?

    init(path: String) throws {
        self.modelPath = path
        // In real implementation:
        // self.context = llama_load_model_from_file(path, llama_context_default_params())
    }

    func generate(prompt: String, onToken: @escaping (String) -> Void) async throws {
        // In real implementation, this would:
        // 1. Tokenize the prompt
        // 2. Run inference
        // 3. Decode tokens and stream them via onToken callback

        // Placeholder implementation for demonstration
        let response = "I'm your local AI assistant. In a production build, I would use llama.cpp to generate responses entirely on your device."

        for char in response {
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms delay for streaming effect
            onToken(String(char))
        }
    }

    deinit {
        // Clean up: llama_free(context)
    }
}
