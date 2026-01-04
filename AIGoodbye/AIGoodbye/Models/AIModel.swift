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
    // Single model - Llama 3.2 3B (well-tested with LLM.swift)
    static let llama32_3B = AIModel(
        id: "llama-3.2-3b",
        name: "Llama 3.2 3B",
        shortDescription: "Fast & efficient AI assistant",
        fullDescription: "Llama 3.2 3B Instruct is Meta's latest compact language model, optimized for mobile devices with excellent instruction following and reasoning capabilities.",
        size: "2.0 GB",
        sizeBytes: 2_000_000_000,
        downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
        fileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
        capabilities: [.chat, .coding, .reasoning, .multilingual, .fileAnalysis],
        memoryRequired: "4 GB RAM",
        templateType: .llama3
    )

    static let allModels: [AIModel] = [llama32_3B]

    static var defaultModel: AIModel {
        llama32_3B
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
