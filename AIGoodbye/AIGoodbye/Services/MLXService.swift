//
//  MLXService.swift
//  AIGoodbye
//
//  MLX-based inference service for Qwen3-VL vision-language model
//  Replaces LlamaService with Apple's MLX framework for better A-series chip support
//

import Foundation
import UIKit
import Combine
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Hub

@MainActor
class MLXService: ObservableObject {
    // Model container for VLM
    private var modelContainer: ModelContainer?
    private var currentModelId: String?
    private var modelDirectory: URL?

    // Configuration
    private let temperature: Float
    private let maxTokens: Int

    // Conversation history for multi-turn (limited to reduce memory usage)
    private var conversationHistory: [[String: String]] = []
    private let historyLimit = 10  // Keep limited history to prevent memory issues

    // System prompt
    private let systemPrompt = """
    You are AiGoodbye, a helpful AI assistant created by Dealer Of Happiness. \
    You run completely offline on the user's device, ensuring complete privacy. \
    Be concise, helpful, and friendly. \
    When analyzing images, describe what you see clearly and answer any questions about the visual content.
    """

    // Download state - observable from outside
    static var downloadedBytes: Int64 = 0
    static var totalBytes: Int64 = 0
    static var isDownloading: Bool = false

    // Constants (inlined to avoid actor isolation warnings in Swift 6)
    private static let defaultTemp: Float = 0.7
    private static let defaultMaxTokens: Int = 256
    private static let gpuCacheLimitBytes: Int = 20 * 1024 * 1024  // 20 MB
    private static let topP: Float = 0.9
    private static let imageMaxDimension: CGFloat = 512

    init(temperature: Double = 0.7, maxTokens: Int = 256) {
        self.temperature = Float(temperature)
        self.maxTokens = maxTokens

        // Set GPU cache limit to prevent memory accumulation during inference
        // This is critical for iOS devices with limited memory (3GB limit)
        GPU.set(cacheLimit: Self.gpuCacheLimitBytes)
        print("[MLXService] GPU cache limit set to \(Self.gpuCacheLimitBytes / 1024 / 1024)MB")
    }

    // MARK: - Model Management

    private func getModelManager() -> ModelManager {
        ModelManager.shared
    }

    /// Load the active model
    func loadModel() async throws {
        let manager = getModelManager()
        let model = manager.activeModel

        // If already loaded with same model, skip
        if modelContainer != nil && currentModelId == model.id {
            print("[MLXService] Model already loaded, reusing existing instance")
            return
        }

        // Unload previous model if switching
        if currentModelId != nil && currentModelId != model.id {
            print("[MLXService] Switching models, unloading previous")
            modelContainer = nil
        }
        currentModelId = nil

        try await loadModelInternal(model)
    }

    private func loadModelInternal(_ model: AIModel) async throws {
        guard model.backend == .mlx else {
            throw MLXError.unsupportedBackend("Model requires MLX backend but uses \(model.backend)")
        }

        let manager = getModelManager()
        let modelPath = manager.modelPath(for: model)

        // Check if model needs download
        if !manager.isModelDownloaded(model) {
            try await downloadModel(model)
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms for filesystem sync
        }

        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw MLXError.modelNotFound
        }

        print("[MLXService] Loading MLX VLM model from: \(modelPath.path)")

        do {
            // Create model configuration for local path
            // Use the full HuggingFace model ID for proper path resolution
            let configuration = ModelConfiguration(
                id: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
                defaultPrompt: "You are a helpful assistant."
            )

            // HubApi expects downloadBase to be the root where models/{id} structure exists
            // Our structure: Documents/models/qwen3-vl-4b/
            // HubApi looks for: downloadBase/models/{id}/config.json
            // So downloadBase should be Documents (parent of models directory)
            let documentsDir = modelPath.deletingLastPathComponent().deletingLastPathComponent()

            // Load VLM model using VLMModelFactory
            modelContainer = try await VLMModelFactory.shared.loadContainer(
                hub: HubApi(downloadBase: documentsDir),
                configuration: configuration
            ) { progress in
                print("[MLXService] Loading progress: \(Int(progress.fractionCompleted * 100))%")
            }

            modelDirectory = modelPath
            currentModelId = model.id
            print("[MLXService] VLM Model loaded successfully: \(model.name)")

        } catch {
            print("[MLXService] Failed to load MLX model: \(error)")
            throw MLXError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Load a specific model by ID
    func loadSpecificModel(_ model: AIModel) async throws {
        if currentModelId != model.id {
            modelContainer = nil
            currentModelId = nil
        }
        try await loadModelInternal(model)
    }

    private func downloadModel(_ model: AIModel) async throws {
        let manager = getModelManager()

        MLXService.isDownloading = true
        MLXService.downloadedBytes = 0
        MLXService.totalBytes = model.sizeBytes

        do {
            try await manager.downloadModel(model)
            MLXService.isDownloading = false
        } catch {
            MLXService.isDownloading = false
            throw error
        }
    }

    func unloadModel() {
        modelContainer = nil
        currentModelId = nil
        modelDirectory = nil
        conversationHistory.removeAll()
    }

    func isModelLoaded() -> Bool {
        modelContainer != nil && currentModelId != nil
    }

    /// Clear GPU cache to free memory before memory-intensive operations (e.g., camera)
    func clearGPUCache() {
        GPU.clearCache()
        print("[MLXService] GPU cache cleared")
    }

    /// Reload the model with current settings
    func reloadModel() async throws {
        guard let modelId = currentModelId,
              let model = AIModel.model(withId: modelId) else {
            throw MLXError.modelNotLoaded
        }

        print("[MLXService] Reloading model with new settings...")
        modelContainer = nil
        try await loadModelInternal(model)
        print("[MLXService] Model reloaded successfully")
    }

    // MARK: - Conversation History

    /// Reset conversation - clears internal conversation history
    func resetConversation() {
        print("[MLXService] resetConversation called - clearing history")
        conversationHistory.removeAll()
    }

    /// Restore history from saved conversation
    func restoreHistory(_ messages: [(role: String, content: String)]) {
        conversationHistory.removeAll()

        for message in messages {
            let role = message.0.lowercased()
            if role == "user" || role == "assistant" {
                conversationHistory.append([
                    "role": role,
                    "content": message.1
                ])
            }
        }

        // Trim to history limit
        if conversationHistory.count > historyLimit * 2 {
            conversationHistory = Array(conversationHistory.suffix(historyLimit * 2))
        }

        print("[MLXService] restoreHistory: restored \(conversationHistory.count) messages")
    }

    /// Force reset
    func forceReset() async throws {
        print("[MLXService] Force reset initiated...")
        modelContainer = nil
        currentModelId = nil
        conversationHistory.removeAll()

        try? await Task.sleep(nanoseconds: 500_000_000)
        try await loadModel()
        print("[MLXService] Force reset completed successfully")
    }

    // MARK: - Text Generation (no image)

    /// Generate response for text-only input
    func generate(prompt: String, conversationHistory existingHistory: [(role: String, content: String)] = []) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    if self.modelContainer == nil {
                        print("[MLXService] Model not loaded, loading...")
                        try await self.loadModel()
                    }

                    guard let container = self.modelContainer else {
                        throw MLXError.modelNotLoaded
                    }

                    // Build the full prompt with history
                    let fullPrompt = self.buildPrompt(userMessage: prompt, image: nil)

                    print("[MLXService] Generating text response...")
                    print("[MLXService] History count: \(self.conversationHistory.count)")

                    // Generate response using MLX
                    let response = try await self.generateWithContainer(
                        container: container,
                        prompt: fullPrompt,
                        image: nil
                    )

                    // Add to history
                    self.addToHistory(role: "user", content: prompt)
                    self.addToHistory(role: "assistant", content: response)

                    let cleanedResponse = self.cleanResponse(response)

                    if cleanedResponse.isEmpty {
                        continuation.yield("I couldn't generate a response. Please try again.")
                    } else {
                        continuation.yield(cleanedResponse)
                    }
                    continuation.finish()

                } catch {
                    print("[MLXService] Generate error: \(error)")
                    continuation.yield("Error: \(error.localizedDescription)")
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Vision Generation (with image)

    /// Generate response for image + text input
    func generateWithVision(prompt: String, image: UIImage) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    if self.modelContainer == nil {
                        print("[MLXService] Model not loaded, loading...")
                        try await self.loadModel()
                    }

                    guard let container = self.modelContainer else {
                        throw MLXError.modelNotLoaded
                    }

                    // Prepare image
                    let processedImage = self.prepareImageForModel(image)

                    // Build prompt
                    let fullPrompt = self.buildPrompt(userMessage: prompt, image: processedImage)

                    print("[MLXService] Generating vision response...")
                    print("[MLXService] Image size: \(processedImage.size)")

                    // Generate response with vision
                    let response = try await self.generateWithContainer(
                        container: container,
                        prompt: fullPrompt,
                        image: processedImage
                    )

                    // Add to history (text only - images not stored in history)
                    self.addToHistory(role: "user", content: "[Image attached] \(prompt)")
                    self.addToHistory(role: "assistant", content: response)

                    let cleanedResponse = self.cleanResponse(response)

                    if cleanedResponse.isEmpty {
                        continuation.yield("I couldn't analyze the image. Please try again.")
                    } else {
                        continuation.yield(cleanedResponse)
                    }
                    continuation.finish()

                } catch {
                    print("[MLXService] Vision generate error: \(error)")
                    continuation.yield("Error analyzing image: \(error.localizedDescription)")
                    continuation.finish()
                }
            }
        }
    }

    /// Analyze an image with a specific prompt
    func analyzeImage(_ imageData: Data, prompt: String) async throws -> String {
        guard let image = UIImage(data: imageData) else {
            throw MLXError.invalidImage
        }

        var result = ""
        for try await chunk in generateWithVision(prompt: prompt, image: image) {
            result = chunk
        }
        return result
    }

    // MARK: - Core Generation

    private func generateWithContainer(container: ModelContainer, prompt: String, image: UIImage?) async throws -> String {
        // Clear GPU cache before generation to free up memory
        GPU.clearCache()

        let generateParameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: Self.topP
        )

        // Create user input
        let userInput: UserInput
        if let image = image, let cgImage = image.cgImage {
            // Vision input with image
            userInput = UserInput(
                prompt: .text(prompt),
                images: [.ciImage(CIImage(cgImage: cgImage))]
            )
        } else {
            // Text-only input
            userInput = UserInput(prompt: .text(prompt))
        }

        // Perform generation using helper to avoid type inference issues
        let output = try await performGeneration(
            container: container,
            userInput: userInput,
            parameters: generateParameters
        )

        // Clear cache after generation to release memory
        GPU.clearCache()

        return output
    }

    private func performGeneration(
        container: ModelContainer,
        userInput: UserInput,
        parameters: GenerateParameters
    ) async throws -> String {
        let result: String = try await container.perform { context in
            let input = try await context.processor.prepare(input: userInput)
            var output = ""
            for try await item in try MLXLMCommon.generate(
                input: input,
                parameters: parameters,
                context: context
            ) {
                switch item {
                case .chunk(let text):
                    output += text
                case .info:
                    break
                case .toolCall:
                    break
                @unknown default:
                    break
                }
            }
            return output
        }
        return result
    }

    // MARK: - Private Helpers

    private func buildPrompt(userMessage: String, image: UIImage?) -> String {
        var prompt = ""

        // Add system message
        prompt += "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"

        // Add conversation history
        for msg in conversationHistory.suffix(historyLimit * 2) {
            if let role = msg["role"], let content = msg["content"] {
                prompt += "<|im_start|>\(role)\n\(content)<|im_end|>\n"
            }
        }

        // Add current user message
        if image != nil {
            prompt += "<|im_start|>user\n<|vision_start|><|image_pad|><|vision_end|>\(userMessage)<|im_end|>\n"
        } else {
            prompt += "<|im_start|>user\n\(userMessage)<|im_end|>\n"
        }

        // Add assistant start
        prompt += "<|im_start|>assistant\n"

        return prompt
    }

    private func prepareImageForModel(_ image: UIImage) -> UIImage {
        // Resize image aggressively to prevent memory issues
        // Reduced from 1024 to stay within iOS 3GB memory limit with model loaded
        let maxDimension: CGFloat = Self.imageMaxDimension
        let size = image.size

        if size.width <= maxDimension && size.height <= maxDimension {
            return image
        }

        let ratio = min(maxDimension / size.width, maxDimension / size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)

        // Use autoreleasepool to ensure immediate memory cleanup
        return autoreleasepool {
            UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)  // opaque=true saves memory
            image.draw(in: CGRect(origin: .zero, size: newSize))
            let resized = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            return resized ?? image
        }
    }

    private func addToHistory(role: String, content: String) {
        conversationHistory.append([
            "role": role,
            "content": content
        ])

        // Trim old history
        if conversationHistory.count > historyLimit * 2 {
            conversationHistory = Array(conversationHistory.suffix(historyLimit * 2))
        }
    }

    private func cleanResponse(_ response: String) -> String {
        var cleaned = response

        // Remove common artifacts
        let patternsToRemove = [
            "<|im_end|>", "<|im_start|>",
            "<|endoftext|>", "<|end|>",
            "<|vision_start|>", "<|vision_end|>",
            "<|vision_pad|>", "<|image_pad|>",
            "<|", "|>",
            "[INST]", "[/INST]",
            "<<SYS>>", "<</SYS>>",
            "assistant\n"
        ]

        for pattern in patternsToRemove {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "")
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

enum MLXError: LocalizedError {
    case modelNotFound
    case modelNotLoaded
    case downloadFailed(String)
    case generationFailed(String)
    case modelLoadFailed(String)
    case unsupportedBackend(String)
    case invalidImage
    case visionNotSupported

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
        case .unsupportedBackend(let reason):
            return "Unsupported model backend: \(reason)"
        case .invalidImage:
            return "Invalid or corrupted image."
        case .visionNotSupported:
            return "This model does not support image analysis."
        }
    }
}
