//
//  MLXService.swift
//  AIGoodbye
//
//  MLX-based inference service for vision-language models (SmolVLM, Qwen-VL)
//  Uses Apple's MLX framework for efficient on-device inference
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

    // Configuration
    private let temperature: Float
    private let maxTokens: Int

    // Conversation history for multi-turn
    private var conversationHistory: [[String: String]] = []
    private let historyLimit: Int = 30

    // Published state for ObservableObject conformance
    @Published var isLoading: Bool = false

    // Download state - @Published for SwiftUI observation
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0

    // System prompt
    private let systemPrompt = """
    You are AiGoodbye, a helpful AI assistant created by Dealer Of Happiness. \
    You run completely offline on the user's device, ensuring complete privacy. \
    Be concise, helpful, and friendly. \
    When analyzing images, describe what you see clearly and answer any questions about the visual content.
    """

    // Legacy static references (for backward compatibility)
    static var downloadedBytes: Int64 = 0
    static var totalBytes: Int64 = 0

    init(temperature: Double = 0.7, maxTokens: Int = 2048) {
        self.temperature = Float(temperature)
        self.maxTokens = maxTokens
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

        // Get the HuggingFace model ID for MLX models
        guard let hfModelId = model.huggingFaceId else {
            throw MLXError.modelLoadFailed("No HuggingFace model ID configured for \(model.name)")
        }

        print("[MLXService] Loading MLX VLM model: \(hfModelId)")

        // Create model configuration with HuggingFace model ID
        // VLMModelFactory handles download automatically using the Hub library
        let configuration = ModelConfiguration(id: hfModelId)

        // Mark as downloading
        self.isDownloading = true
        self.downloadProgress = 0

        // Load VLM model - it will download if needed
        modelContainer = try await VLMModelFactory.shared.loadContainer(
            configuration: configuration
        ) { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress.fractionCompleted
                if progress.isFinished {
                    self?.isDownloading = false
                }
            }
            print("[MLXService] Loading progress: \(Int(progress.fractionCompleted * 100))%")
        }

        // Ensure download state is cleared
        self.isDownloading = false

        currentModelId = model.id
        print("[MLXService] VLM Model loaded successfully: \(model.name)")
    }

    /// Load a specific model by ID
    func loadSpecificModel(_ model: AIModel) async throws {
        if currentModelId != model.id {
            modelContainer = nil
            currentModelId = nil
        }
        try await loadModelInternal(model)
    }

    func unloadModel() {
        modelContainer = nil
        currentModelId = nil
        conversationHistory.removeAll()
    }

    func isModelLoaded() -> Bool {
        modelContainer != nil && currentModelId != nil
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

        // Limit content size to prevent memory issues
        let maxContentLength = 2000

        for message in messages {
            let role = message.0.lowercased()
            if role == "user" || role == "assistant" {
                // Truncate long content (e.g., from document analysis)
                let content = message.1
                let truncatedContent: String
                if content.count > maxContentLength {
                    truncatedContent = String(content.prefix(maxContentLength)) + "\n[Content truncated]"
                } else {
                    truncatedContent = content
                }

                conversationHistory.append([
                    "role": role,
                    "content": truncatedContent
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
        let generateParameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: 0.9
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

        // Perform generation
        let output = try await container.perform { context in
            let input = try await context.processor.prepare(input: userInput)

            // Generate returns an AsyncSequence - collect all tokens
            var generatedText = ""
            let tokenStream = try MLXLMCommon.generate(
                input: input,
                parameters: generateParameters,
                context: context
            )

            for await part in tokenStream {
                if let chunk = part.chunk {
                    generatedText += chunk
                }
            }

            return generatedText
        }

        return output
    }

    // MARK: - Private Helpers

    private func buildPrompt(userMessage: String, image: UIImage?) -> String {
        let manager = getModelManager()
        let templateType = manager.activeModel.templateType

        switch templateType {
        case .smolvlm:
            return buildSmolVLMPrompt(userMessage: userMessage, image: image)
        case .qwenvl:
            return buildQwenVLPrompt(userMessage: userMessage, image: image)
        default:
            // Default to Qwen VL format for other MLX vision models
            return buildQwenVLPrompt(userMessage: userMessage, image: image)
        }
    }

    /// Build prompt for SmolVLM2 models
    private func buildSmolVLMPrompt(userMessage: String, image: UIImage?) -> String {
        var prompt = ""

        // SmolVLM2 uses simpler format - system message as first user turn
        if conversationHistory.isEmpty {
            // Add system context in first message
            prompt += "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
        }

        // Add conversation history
        for msg in conversationHistory.suffix(historyLimit * 2) {
            if let role = msg["role"], let content = msg["content"] {
                prompt += "<|im_start|>\(role)\n\(content)<|im_end|>\n"
            }
        }

        // Add current user message (SmolVLM uses <image> token for images)
        if image != nil {
            prompt += "<|im_start|>user\n<image>\(userMessage)<|im_end|>\n"
        } else {
            prompt += "<|im_start|>user\n\(userMessage)<|im_end|>\n"
        }

        // Add assistant start
        prompt += "<|im_start|>assistant\n"

        return prompt
    }

    /// Build prompt for Qwen VL models (Qwen2-VL, Qwen3-VL)
    /// Uses ChatML format with <|vision_start|><|image_pad|><|vision_end|> for images
    private func buildQwenVLPrompt(userMessage: String, image: UIImage?) -> String {
        var prompt = ""

        // Add system message
        prompt += "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"

        // Add conversation history
        for msg in conversationHistory.suffix(historyLimit * 2) {
            if let role = msg["role"], let content = msg["content"] {
                prompt += "<|im_start|>\(role)\n\(content)<|im_end|>\n"
            }
        }

        // Add current user message with vision tokens if image present
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
        // Resize image if too large (max 1024px on longest side)
        let maxDimension: CGFloat = 1024
        let size = image.size

        if size.width <= maxDimension && size.height <= maxDimension {
            return image
        }

        let ratio = min(maxDimension / size.width, maxDimension / size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return resized ?? image
    }

    private func addToHistory(role: String, content: String) {
        // Limit content size to prevent memory issues with large documents
        // Truncate content if it's too long (e.g., from document analysis)
        let maxContentLength = 2000
        let truncatedContent: String
        if content.count > maxContentLength {
            truncatedContent = String(content.prefix(maxContentLength)) + "\n[Content truncated for memory efficiency]"
        } else {
            truncatedContent = content
        }

        conversationHistory.append([
            "role": role,
            "content": truncatedContent
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
            "<image>", "</image>",
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
