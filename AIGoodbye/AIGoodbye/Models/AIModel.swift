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
    // Single model - Mistral 7B Instruct v0.2 (proven with LLM.swift, multilingual)
    static let mistral7B = AIModel(
        id: "mistral-7b",
        name: "Mistral 7B",
        shortDescription: "Powerful multilingual AI assistant",
        fullDescription: "Mistral 7B Instruct v0.2 is a highly capable language model with excellent multilingual support, optimized for instruction following and reasoning.",
        size: "4.1 GB",
        sizeBytes: 4_370_000_000,
        downloadURL: URL(string: "https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_K_M.gguf")!,
        fileName: "mistral-7b-instruct-v0.2.Q4_K_M.gguf",
        capabilities: [.chat, .coding, .reasoning, .multilingual, .fileAnalysis],
        memoryRequired: "6 GB RAM",
        templateType: .mistral
    )

    static let allModels: [AIModel] = [mistral7B]

    static var defaultModel: AIModel {
        mistral7B
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
