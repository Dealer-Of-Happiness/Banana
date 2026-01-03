//
//  AIModel.swift
//  AIGoodbye
//
//  AI Model definitions for local inference
//

import Foundation

// MARK: - AI Model

struct AIModel: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let shortDescription: String
    let fullDescription: String
    let size: String // e.g., "800 MB"
    let sizeBytes: Int64
    let downloadURL: URL
    let fileName: String
    let capabilities: [ModelCapability]
    let memoryRequired: String // e.g., "2 GB RAM"
    let templateType: TemplateType

    var isDownloaded: Bool {
        ModelManager.shared.isModelDownloaded(self)
    }
}

// MARK: - Model Capability

enum ModelCapability: String, Codable, CaseIterable {
    case chat = "Chat"
    case coding = "Coding"
    case reasoning = "Reasoning"
    case vision = "Vision"
    case medical = "Medical"
    case multilingual = "Multilingual"
    case fast = "Fast"
    case lowMemory = "Low Memory"

    var icon: String {
        switch self {
        case .chat: return "bubble.left.fill"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .reasoning: return "brain.head.profile"
        case .vision: return "eye.fill"
        case .medical: return "cross.case.fill"
        case .multilingual: return "globe"
        case .fast: return "bolt.fill"
        case .lowMemory: return "memorychip"
        }
    }
}

// MARK: - Template Type

enum TemplateType: String, Codable {
    case llama3
    case gemma
    case phi
    case chatml
    case alpaca
}

// MARK: - Available Models

extension AIModel {
    static let allModels: [AIModel] = [
        // Llama 3.2 1B - Default, fast and efficient
        AIModel(
            id: "llama-3.2-1b",
            name: "Llama 3.2 1B",
            shortDescription: "Fast & efficient general assistant",
            fullDescription: "Meta's Llama 3.2 1B is a compact yet capable model perfect for everyday conversations. It offers quick responses while maintaining good quality, ideal for devices with limited memory.",
            size: "800 MB",
            sizeBytes: 800_000_000,
            downloadURL: URL(string: "https://huggingface.co/lmstudio-community/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!,
            fileName: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            capabilities: [.chat, .fast, .lowMemory],
            memoryRequired: "2 GB RAM",
            templateType: .llama3
        ),

        // Llama 3.2 3B - Higher quality
        AIModel(
            id: "llama-3.2-3b",
            name: "Llama 3.2 3B",
            shortDescription: "Higher quality conversations",
            fullDescription: "Meta's Llama 3.2 3B provides significantly better response quality than the 1B version. Better at following complex instructions and reasoning tasks.",
            size: "2.0 GB",
            sizeBytes: 2_000_000_000,
            downloadURL: URL(string: "https://huggingface.co/lmstudio-community/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
            fileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            capabilities: [.chat, .reasoning, .multilingual],
            memoryRequired: "4 GB RAM",
            templateType: .llama3
        ),

        // Gemma 2 2B - Google's model
        AIModel(
            id: "gemma-2-2b",
            name: "Gemma 2 2B",
            shortDescription: "Google's efficient model",
            fullDescription: "Google's Gemma 2 2B offers excellent performance for its size. Known for being helpful, harmless, and honest with strong instruction following.",
            size: "1.6 GB",
            sizeBytes: 1_600_000_000,
            downloadURL: URL(string: "https://huggingface.co/lmstudio-community/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf")!,
            fileName: "gemma-2-2b-it-Q4_K_M.gguf",
            capabilities: [.chat, .coding, .reasoning],
            memoryRequired: "3 GB RAM",
            templateType: .gemma
        ),

        // Phi-3 Mini - Microsoft's model
        AIModel(
            id: "phi-3-mini",
            name: "Phi-3 Mini",
            shortDescription: "Microsoft's reasoning model",
            fullDescription: "Microsoft's Phi-3 Mini excels at reasoning and coding tasks. Despite its small size, it performs remarkably well on benchmarks.",
            size: "2.2 GB",
            sizeBytes: 2_200_000_000,
            downloadURL: URL(string: "https://huggingface.co/lmstudio-community/Phi-3.1-mini-4k-instruct-GGUF/resolve/main/Phi-3.1-mini-4k-instruct-Q4_K_M.gguf")!,
            fileName: "Phi-3.1-mini-4k-instruct-Q4_K_M.gguf",
            capabilities: [.chat, .coding, .reasoning],
            memoryRequired: "4 GB RAM",
            templateType: .phi
        ),

        // TinyLlama - Ultra lightweight
        AIModel(
            id: "tinyllama",
            name: "TinyLlama",
            shortDescription: "Ultra-fast, minimal memory",
            fullDescription: "TinyLlama is an extremely compact model that runs on almost any device. Perfect for quick responses when speed matters more than depth.",
            size: "600 MB",
            sizeBytes: 600_000_000,
            downloadURL: URL(string: "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf")!,
            fileName: "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
            capabilities: [.chat, .fast, .lowMemory],
            memoryRequired: "1.5 GB RAM",
            templateType: .chatml
        )
    ]

    static var defaultModel: AIModel {
        // TinyLlama is smaller and more compatible
        allModels.first { $0.id == "tinyllama" }!
    }

    static func model(withId id: String) -> AIModel? {
        allModels.first { $0.id == id }
    }
}

// MARK: - Download State

enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed(String)
}
