//
//  LlamaService.swift
//  AI goodbye
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

    // Expected model size in bytes (approximately 900MB for Q4_K_M)
    private let expectedModelSize: Int64 = 900_000_000

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
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: modelPath.path) else {
            return false
        }

        // Verify file size is at least 50% of expected size
        if let attributes = try? fileManager.attributesOfItem(atPath: modelPath.path),
           let fileSize = attributes[.size] as? Int64 {
            return fileSize >= expectedModelSize / 2
        }

        return false
    }

    func loadModel() async throws {
        if bot != nil {
            return
        }

        // Check if model already exists locally and is valid
        if !isModelDownloaded() {
            // Remove any corrupted/incomplete file before downloading
            try? FileManager.default.removeItem(at: modelPath)
            try await downloadModelWithProgress()
            // Wait for filesystem to sync after download
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }

        // Store the path for later use
        modelPathURL = modelPath
        let pathForLoading = modelPath
        let expectedSize = expectedModelSize

        print("[LlamaService] Loading model on background thread (non-blocking)...")

        // CRITICAL FIX: Use withCheckedThrowingContinuation for TRUE async suspension
        // This allows the calling context to remain responsive while waiting for model load
        let loadedLLM = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LLM, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // 1. Verify file on background thread (was blocking before!)
                let verifyResult = Self.verifyFileOnBackgroundThread(at: pathForLoading, expectedSize: expectedSize)
                if case .failure(let error) = verifyResult {
                    continuation.resume(throwing: error)
                    return
                }

                // 2. Initialize LLM with retries - all on background thread
                let maxRetries = 3
                let retryDelays: [TimeInterval] = [0.5, 1.0, 2.0]

                for attempt in 1...maxRetries {
                    print("[LlamaService] Attempt \(attempt): Initializing LLM on background thread...")

                    if let llm = LLM(from: pathForLoading, template: .chatML()) {
                        print("[LlamaService] Model loaded successfully on attempt \(attempt)")
                        continuation.resume(returning: llm)
                        return
                    }

                    if attempt < maxRetries {
                        print("[LlamaService] Attempt \(attempt) failed, retrying in \(retryDelays[attempt - 1])s...")
                        Thread.sleep(forTimeInterval: retryDelays[attempt - 1])
                    }
                }

                // All retries failed
                let diagnosis = Self.diagnoseLoadFailureOnBackgroundThread(at: pathForLoading, expectedSize: expectedSize)
                continuation.resume(throwing: LlamaError.modelLoadFailed(diagnosis))
            }
        }

        bot = loadedLLM
        print("[LlamaService] Model assigned and ready for use")
    }

    // MARK: - Background Thread Helpers (Static to avoid actor isolation issues)

    /// Verify file on background thread - static to avoid actor isolation
    private static func verifyFileOnBackgroundThread(at url: URL, expectedSize: Int64) -> Result<Void, Error> {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: url.path) else {
            return .failure(LlamaError.modelNotFound)
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            return .failure(LlamaError.modelLoadFailed("Cannot read model file attributes"))
        }

        if fileSize < expectedSize / 2 {
            try? fileManager.removeItem(at: url)
            return .failure(LlamaError.modelLoadFailed("Model file is incomplete (\(fileSize / 1_000_000) MB). Please download again."))
        }

        // Verify GGUF magic header
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            guard let headerData = try handle.read(upToCount: 4),
                  headerData.count == 4 else {
                return .failure(LlamaError.modelLoadFailed("Cannot read model file header"))
            }

            let magic = headerData.withUnsafeBytes { $0.load(as: UInt32.self) }
            if magic != 0x46554747 { // "GGUF"
                try? fileManager.removeItem(at: url)
                return .failure(LlamaError.modelLoadFailed("Model file is corrupted. Please download again."))
            }
        } catch {
            return .failure(LlamaError.modelLoadFailed("Cannot verify model file: \(error.localizedDescription)"))
        }

        print("[LlamaService] File verification passed: \(fileSize / 1_000_000) MB, valid GGUF")
        return .success(())
    }

    /// Diagnose load failure on background thread - static to avoid actor isolation
    private static func diagnoseLoadFailureOnBackgroundThread(at url: URL, expectedSize: Int64) -> String {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: url.path) else {
            return "Model file not found. Please download again."
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? Int64 {

            if fileSize < expectedSize / 2 {
                try? fileManager.removeItem(at: url)
                let percentComplete = Int((Double(fileSize) / Double(expectedSize)) * 100)
                return "Download incomplete (\(percentComplete)%). Please download again."
            }
        }

        return "Could not initialize AI model. Try restarting the app."
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

        // Download to temp file first for atomic write
        let tempPath = modelsDir.appendingPathComponent("download_\(UUID().uuidString).tmp")

        // Remove any existing file at destination
        try? FileManager.default.removeItem(at: modelPath)

        // Create temp file and write
        FileManager.default.createFile(atPath: tempPath.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempPath)

        var buffer = Data()
        let bufferSize = 1024 * 1024 // 1MB buffer

        do {
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

            // Ensure data is flushed to disk
            try handle.synchronize()
            try handle.close()

            // Verify downloaded file before moving
            if let attributes = try? FileManager.default.attributesOfItem(atPath: tempPath.path),
               let fileSize = attributes[.size] as? Int64,
               fileSize < expectedModelSize / 2 {
                try? FileManager.default.removeItem(at: tempPath)
                LlamaService.isDownloading = false
                throw LlamaError.downloadFailed("Downloaded file is incomplete")
            }

            // Verify GGUF header
            let verifyHandle = try FileHandle(forReadingFrom: tempPath)
            guard let headerData = try verifyHandle.read(upToCount: 4),
                  headerData.count == 4 else {
                try? verifyHandle.close()
                try? FileManager.default.removeItem(at: tempPath)
                LlamaService.isDownloading = false
                throw LlamaError.downloadFailed("Downloaded file is invalid")
            }
            try verifyHandle.close()

            let magic = headerData.withUnsafeBytes { $0.load(as: UInt32.self) }
            if magic != 0x46554747 { // "GGUF"
                try? FileManager.default.removeItem(at: tempPath)
                LlamaService.isDownloading = false
                throw LlamaError.downloadFailed("Downloaded file is not a valid GGUF model")
            }

            // Atomic move to final destination
            try FileManager.default.moveItem(at: tempPath, to: modelPath)

            print("[LlamaService] Download completed successfully")
            LlamaService.isDownloading = false

        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tempPath)
            LlamaService.isDownloading = false
            throw error
        }
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

                    // Build simple prompt for Llama 3 format
                    let fullPrompt = self.buildLlama3Prompt(prompt: prompt, history: history)

                    // Clear any previous output
                    bot.output = ""

                    // Generate response
                    await bot.respond(to: fullPrompt)
                    var response = bot.output

                    // Clean up the response
                    response = response.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Remove any stop tokens that might appear
                    if let range = response.range(of: "<|") {
                        response = String(response[..<range.lowerBound])
                    }
                    response = response.trimmingCharacters(in: .whitespacesAndNewlines)

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

    // Llama 3 chat format
    private func buildLlama3Prompt(prompt: String, history: [(role: String, content: String)]) -> String {
        var fullPrompt = "<|begin_of_text|>"

        // System message
        fullPrompt += "<|start_header_id|>system<|end_header_id|>\n\n"
        fullPrompt += "You are AI goodbye, a helpful and friendly assistant. Be concise.<|eot_id|>"

        // Add conversation history (keep last 4 exchanges for context window)
        for message in history.suffix(4) {
            if message.role == "user" {
                fullPrompt += "<|start_header_id|>user<|end_header_id|>\n\n"
                fullPrompt += "\(message.content)<|eot_id|>"
            } else if message.role == "assistant" {
                fullPrompt += "<|start_header_id|>assistant<|end_header_id|>\n\n"
                fullPrompt += "\(message.content)<|eot_id|>"
            }
        }

        // Current user message
        fullPrompt += "<|start_header_id|>user<|end_header_id|>\n\n"
        fullPrompt += "\(prompt)<|eot_id|>"

        // Start assistant response
        fullPrompt += "<|start_header_id|>assistant<|end_header_id|>\n\n"

        return fullPrompt
    }

    // Simple non-streaming response
    func getResponse(prompt: String) async throws -> String {
        guard let bot = bot else {
            throw LlamaError.modelNotLoaded
        }

        let fullPrompt = buildLlama3Prompt(prompt: prompt, history: [])
        bot.output = ""
        await bot.respond(to: fullPrompt)
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
