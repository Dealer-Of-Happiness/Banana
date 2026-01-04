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
    let size: String
    let sizeBytes: Int64
    let downloadURL: URL
    let fileName: String
    let capabilities: [ModelCapability]
    let memoryRequired: String
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
    case multilingual = "Multilingual"
    case fast = "Fast"
    case fileAnalysis = "File Analysis"

    var icon: String {
        switch self {
        case .chat: return "bubble.left.fill"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .reasoning: return "brain.head.profile"
        case .vision: return "eye.fill"
        case .multilingual: return "globe"
        case .fast: return "bolt.fill"
        case .fileAnalysis: return "doc.text.magnifyingglass"
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
}

// MARK: - Available Models

extension AIModel {
    // Qwen2.5 7B - tested with LLM.swift, excellent multilingual support
    static let qwen7B = AIModel(
        id: "qwen-7b",
        name: "Qwen 7B",
        shortDescription: "Powerful multilingual AI assistant",
        fullDescription: "Qwen2.5 7B Instruct offers excellent multilingual support including Chinese, Japanese, Korean, and European languages with strong reasoning capabilities.",
        size: "4.7 GB",
        sizeBytes: 4_680_000_000,
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m.gguf")!,
        fileName: "qwen2.5-7b-instruct-q4_k_m.gguf",
        capabilities: [.chat, .coding, .reasoning, .multilingual, .fileAnalysis],
        memoryRequired: "6 GB RAM",
        templateType: .chatml
    )

    static let allModels: [AIModel] = [qwen7B]

    static var defaultModel: AIModel {
        qwen7B
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
