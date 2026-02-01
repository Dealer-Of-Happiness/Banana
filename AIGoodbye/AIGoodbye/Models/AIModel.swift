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

    // HuggingFace model ID for MLX models (e.g., "mlx-community/Qwen3-VL-4B-Instruct-4bit")
    let huggingFaceId: String?

    // For MLX models that require multiple files (legacy - no longer needed for MLX)
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
    case qwenvl    // Qwen VL models (Qwen2-VL, Qwen3-VL) - uses <|vision_start|><|image_pad|><|vision_end|>
    case smolvlm   // SmolVLM2 template format
}

// MARK: - Available Models

extension AIModel {
    // Qwen2-VL 2B - Multilingual Vision-Language Model
    // 4-bit quantized - Excellent multilingual support
    static let qwen2VL2B = AIModel(
        id: "qwen2-vl-2b",
        name: "Qwen2 Vision 2B",
        shortDescription: "Multilingual vision AI - 29+ languages",
        fullDescription: "Qwen2-VL 2B with 4-bit quantization. Excellent multilingual support including Chinese, Japanese, Korean, Arabic, and European languages.",
        size: "1.25 GB",
        sizeBytes: 1_250_000_000,
        downloadURL: URL(string: "https://huggingface.co/mlx-community/Qwen2-VL-2B-Instruct-4bit/resolve/main/model.safetensors")!,
        fileName: "qwen2-vl-2b",
        capabilities: [.chat, .vision, .multilingual, .imageAnalysis, .documentAnalysis],
        memoryRequired: "2.5-3 GB RAM",
        templateType: .qwenvl,
        backend: .mlx,
        supportsVision: true,
        huggingFaceId: "mlx-community/Qwen2-VL-2B-Instruct-4bit",
        additionalFiles: nil
    )

    // Single model - Qwen2-VL-2B is the only available model
    static let allModels: [AIModel] = [qwen2VL2B]

    static var defaultModel: AIModel {
        qwen2VL2B
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
