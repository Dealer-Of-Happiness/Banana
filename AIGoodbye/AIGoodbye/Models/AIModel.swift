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
    // SmolVLM2 500M - Compact Vision-Language Model optimized for mobile
    // Only 1 GB - fits perfectly on iPhone with 3GB memory limit
    static let smolVLM2_500M = AIModel(
        id: "smolvlm2-500m",
        name: "SmolVLM2 500M",
        shortDescription: "Fast & compact vision AI for mobile",
        fullDescription: "SmolVLM2 500M - A highly efficient vision-language model designed specifically for mobile devices. Only 1 GB download, runs smoothly on iPhone. Understands images, screenshots, and documents with excellent performance.",
        size: "1.0 GB",
        sizeBytes: 1_020_000_000,
        downloadURL: URL(string: "https://huggingface.co/mlx-community/SmolVLM2-500M-Video-Instruct-mlx/resolve/main/model.safetensors")!,
        fileName: "smolvlm2-500m",
        capabilities: [.chat, .vision, .fast, .imageAnalysis, .documentAnalysis],
        memoryRequired: "2 GB RAM",
        templateType: .smolvlm,
        backend: .mlx,
        supportsVision: true,
        huggingFaceId: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
        additionalFiles: nil
    )

    // SmolVLM2 256M - Ultra-compact for older devices
    static let smolVLM2_256M = AIModel(
        id: "smolvlm2-256m",
        name: "SmolVLM2 256M (Ultra-Light)",
        shortDescription: "Ultra-compact vision AI",
        fullDescription: "SmolVLM2 256M - The smallest vision-language model available. Only 513 MB, perfect for older iPhones or devices with limited memory. Good for basic image understanding.",
        size: "513 MB",
        sizeBytes: 513_000_000,
        downloadURL: URL(string: "https://huggingface.co/mlx-community/SmolVLM2-256M-Video-Instruct-mlx/resolve/main/model.safetensors")!,
        fileName: "smolvlm2-256m",
        capabilities: [.chat, .vision, .fast, .imageAnalysis],
        memoryRequired: "1 GB RAM",
        templateType: .smolvlm,
        backend: .mlx,
        supportsVision: true,
        huggingFaceId: "mlx-community/SmolVLM2-256M-Video-Instruct-mlx",
        additionalFiles: nil
    )

    // Qwen2-VL 2B - Multilingual Vision-Language Model
    // 4-bit quantized - Good multilingual support, borderline memory for iPhone
    static let qwen2VL2B = AIModel(
        id: "qwen2-vl-2b",
        name: "Qwen2 Vision 2B (Multilingual)",
        shortDescription: "Multilingual vision AI - 29+ languages",
        fullDescription: "Qwen2-VL 2B with 4-bit quantization. Excellent multilingual support including Chinese, Japanese, Korean, Arabic, and European languages. 1.25 GB download. May work on newer iPhones but memory is borderline.",
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

    // Qwen3-VL 4B - Vision-Language Model with MLX (iPad/Mac only - requires 6GB RAM)
    // 4-bit quantized - TOO LARGE for iPhone (3GB limit)
    static let qwen3VL4B = AIModel(
        id: "qwen3-vl-4b",
        name: "Qwen3 Vision 4B (iPad/Mac)",
        shortDescription: "Most powerful vision AI (requires 6GB RAM)",
        fullDescription: "Qwen3-VL 4B with 4-bit quantization. Most capable model but requires 6 GB RAM - only works on iPad Pro or Mac. Will crash on iPhone due to memory limits.",
        size: "2.8 GB",
        sizeBytes: 2_800_000_000,
        downloadURL: URL(string: "https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit/resolve/main/model.safetensors")!,
        fileName: "qwen3-vl-4b",
        capabilities: [.chat, .vision, .coding, .reasoning, .multilingual, .imageAnalysis, .documentAnalysis],
        memoryRequired: "6 GB RAM (iPad/Mac only)",
        templateType: .qwenvl,
        backend: .mlx,
        supportsVision: true,
        huggingFaceId: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
        additionalFiles: nil
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
        huggingFaceId: nil,
        additionalFiles: nil
    )

    // Available models - SmolVLM2-500M is default (works on all devices including iPhone)
    // Order: Safe iPhone models first, then larger/riskier models
    static let allModels: [AIModel] = [smolVLM2_500M, qwen2VL2B, smolVLM2_256M, qwen3VL4B, qwen7B]

    static var defaultModel: AIModel {
        smolVLM2_500M  // SmolVLM2-500M is default - works on iPhone (1GB, fits in 3GB limit)
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
