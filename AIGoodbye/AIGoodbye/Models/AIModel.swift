//
//  AIModel.swift
//  AIGoodbye
//
//  AI Model definitions for local inference with MLX
//

import Foundation

// MARK: - Model Backend

enum ModelBackend: String, Codable {
    case mlx       // Apple MLX framework (vision-capable)
    case llamacpp  // Legacy llama.cpp (text-only)
}

// MARK: - AI Model

struct AIModel: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let shortDescription: String
    let fullDescription: String
    let size: String
    let sizeBytes: Int64
    let downloadURL: URL
    let fileName: String
    let capabilities: [ModelCapability]
    let memoryRequired: String
    let templateType: TemplateType
    let backend: ModelBackend
    let supportsVision: Bool

    // For MLX models that require multiple files
    let additionalFiles: [ModelFile]?

    var isDownloaded: Bool {
        ModelManager.shared.isModelDownloaded(self)
    }

    // Check if this model can process images
    var canProcessImages: Bool {
        supportsVision && backend == .mlx
    }
}

// MARK: - Model File (for multi-file MLX models)

struct ModelFile: Codable, Equatable {
    let name: String
    let url: URL
    let sizeBytes: Int64
}

// MARK: - Model Capability

enum ModelCapability: String, Codable, CaseIterable {
    case chat = "Chat"
    case coding = "Coding"
    case reasoning = "Reasoning"
    case vision = "Vision"
    case multilingual = "Multilingual"
    case fast = "Fast"
    case fileAnalysis = "File Analysis"
    case documentAnalysis = "Document Analysis"
    case imageAnalysis = "Image Analysis"

    var icon: String {
        switch self {
        case .chat: return "bubble.left.fill"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .reasoning: return "brain.head.profile"
        case .vision: return "eye.fill"
        case .multilingual: return "globe"
        case .fast: return "bolt.fill"
        case .fileAnalysis: return "doc.text.magnifyingglass"
        case .documentAnalysis: return "doc.viewfinder"
        case .imageAnalysis: return "photo.badge.magnifyingglass"
        }
    }
}

// MARK: - Template Type

enum TemplateType: String, Codable {
    case mistral
    case llama3
    case gemma
    case phi
    case chatml
    case alpaca
    case qwen3vl  // Qwen3-VL specific template
}

// MARK: - Available Models

extension AIModel {
    // Qwen3-VL 4B - Vision-Language Model with MLX
    // 4-bit quantized for mobile deployment
    static let qwen3VL4B = AIModel(
        id: "qwen3-vl-4b",
        name: "Qwen3 Vision 4B",
        shortDescription: "Powerful vision + text AI assistant",
        fullDescription: "Qwen3-VL 4B with 4-bit quantization. Understands images, documents, screenshots, and text. Perfect for analyzing photos, reading documents, and intelligent conversations.",
        size: "2.8 GB",
        sizeBytes: 2_800_000_000,
        downloadURL: URL(string: "https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit/resolve/main/model.safetensors")!,
        fileName: "qwen3-vl-4b",  // Directory name for MLX models
        capabilities: [.chat, .vision, .coding, .reasoning, .multilingual, .imageAnalysis, .documentAnalysis],
        memoryRequired: "6 GB RAM",
        templateType: .qwen3vl,
        backend: .mlx,
        supportsVision: true,
        additionalFiles: [
            ModelFile(
                name: "config.json",
                url: URL(string: "https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit/resolve/main/config.json")!,
                sizeBytes: 2_000
            ),
            ModelFile(
                name: "tokenizer.json",
                url: URL(string: "https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit/resolve/main/tokenizer.json")!,
                sizeBytes: 7_000_000
            ),
            ModelFile(
                name: "tokenizer_config.json",
                url: URL(string: "https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit/resolve/main/tokenizer_config.json")!,
                sizeBytes: 5_000
            ),
            ModelFile(
                name: "special_tokens_map.json",
                url: URL(string: "https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit/resolve/main/special_tokens_map.json")!,
                sizeBytes: 1_000
            ),
            ModelFile(
                name: "preprocessor_config.json",
                url: URL(string: "https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit/resolve/main/preprocessor_config.json")!,
                sizeBytes: 500
            )
        ]
    )

    // Legacy Qwen2.5 7B (text-only, for fallback)
    static let qwen7B = AIModel(
        id: "qwen-7b",
        name: "Qwen 7B (Legacy)",
        shortDescription: "Text-only AI assistant",
        fullDescription: "Qwen2.5 7B Instruct with Q2_K quantization. Text-only model for devices that don't support vision.",
        size: "2.7 GB",
        sizeBytes: 2_700_000_000,
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q2_k.gguf")!,
        fileName: "qwen2.5-7b-instruct-q2_k.gguf",
        capabilities: [.chat, .coding, .reasoning, .multilingual, .fileAnalysis],
        memoryRequired: "4 GB RAM",
        templateType: .chatml,
        backend: .llamacpp,
        supportsVision: false,
        additionalFiles: nil
    )

    // Primary model is now Qwen3-VL
    static let allModels: [AIModel] = [qwen3VL4B, qwen7B]

    static var defaultModel: AIModel {
        qwen3VL4B  // Vision model is now default
    }

    static func model(withId id: String) -> AIModel? {
        allModels.first { $0.id == id }
    }

    // Get all vision-capable models
    static var visionModels: [AIModel] {
        allModels.filter { $0.supportsVision }
    }
}

// MARK: - Download State

enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed(String)
}
