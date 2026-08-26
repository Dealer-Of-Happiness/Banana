//
//  AIModel.swift
//  AIGoodbye
//
//  AI model catalog with device-aware recommendations.
//  Chat templates are applied by the MLX library (each model's own template),
//  so models no longer carry manual template definitions.
//

import Foundation

// MARK: - Model Backend

enum ModelBackend: String, Codable {
    case mlx                // Downloaded model running via Apple MLX
    case appleIntelligence  // Built-in Apple Foundation Models (iOS 26+, no download)
}

// MARK: - AI Model

struct AIModel: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let shortDescription: String
    let fullDescription: String
    let size: String
    let sizeBytes: Int64
    let capabilities: [ModelCapability]
    let memoryRequired: String
    let backend: ModelBackend
    let supportsVision: Bool

    /// HuggingFace model ID for MLX models (e.g. "mlx-community/Qwen3-VL-2B-Instruct-4bit")
    let huggingFaceId: String?

    /// Minimum device RAM (GB) at which this model is recommended
    let minRecommendedRAMGB: Int

    /// Longest image edge (points) fed to the vision encoder. Smaller = faster.
    let imageProcessingEdge: Double

    /// Legacy models are hidden from new users but kept working for users who
    /// already downloaded them.
    let isLegacy: Bool

    var isDownloaded: Bool {
        if backend == .appleIntelligence { return true }
        return ModelManager.shared.isModelDownloaded(self)
    }

    var canProcessImages: Bool { supportsVision }
}

// MARK: - Model Capability

enum ModelCapability: String, Codable, CaseIterable {
    case chat = "Chat"
    case vision = "Vision"
    case multilingual = "Multilingual"
    case fast = "Fast"
    case documentAnalysis = "Documents"

    var icon: String {
        switch self {
        case .chat: return "bubble.left.fill"
        case .vision: return "eye.fill"
        case .multilingual: return "globe"
        case .fast: return "bolt.fill"
        case .documentAnalysis: return "doc.text.magnifyingglass"
        }
    }
}

// MARK: - Catalog

extension AIModel {

    /// Qwen3-VL 2B: current-generation vision-language model. Default for devices
    /// with 6 GB of RAM or more.
    static let qwen3VL2B = AIModel(
        id: "qwen3-vl-2b",
        name: "Qwen3 Vision 2B",
        shortDescription: String(localized: "Best quality - vision, 30+ languages"),
        fullDescription: String(localized: "Qwen3-VL 2B (4-bit). The strongest small vision model available: sharper image understanding, better reasoning, and wide language coverage. Recommended for iPhone 14 Pro and newer."),
        size: "1.8 GB",
        sizeBytes: 1_780_000_000,
        capabilities: [.chat, .vision, .multilingual, .documentAnalysis],
        memoryRequired: String(localized: "3 GB RAM while active"),
        backend: .mlx,
        supportsVision: true,
        huggingFaceId: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
        minRecommendedRAMGB: 6,
        imageProcessingEdge: 768,
        isLegacy: false
    )

    /// Qwen3-VL 8B "Pro": the most powerful model we offer. Only for phones
    /// with 12 GB of RAM (iPhone 17 Pro / Pro Max class); hidden elsewhere.
    static let qwen3VL8BPro = AIModel(
        id: "qwen3-vl-8b",
        name: "Qwen3 Vision 8B Pro",
        shortDescription: String(localized: "Maximum intelligence - for Pro phones"),
        fullDescription: String(localized: "Qwen3-VL 8B (4-bit). Our most powerful model: noticeably deeper reasoning, richer answers, and the sharpest image understanding. Requires a phone with 12 GB of RAM, like iPhone 17 Pro Max. Responses are slower than the 2B model."),
        size: "5.8 GB",
        sizeBytes: 5_760_000_000,
        capabilities: [.chat, .vision, .multilingual, .documentAnalysis],
        memoryRequired: String(localized: "About 7 GB RAM while active"),
        backend: .mlx,
        supportsVision: true,
        huggingFaceId: "mlx-community/Qwen3-VL-8B-Instruct-4bit",
        minRecommendedRAMGB: 12,
        imageProcessingEdge: 768,
        isLegacy: false
    )

    /// SmolVLM2 500M: compact vision model for devices with 4 GB of RAM.
    static let smolVLM2 = AIModel(
        id: "smolvlm2-500m",
        name: "Smol Vision 500M",
        shortDescription: String(localized: "Light and fast - great for older iPhones"),
        fullDescription: String(localized: "SmolVLM2 500M. A compact vision model that runs comfortably on older devices (iPhone 11-13). Faster responses and lower memory use, with simpler answers than the larger models."),
        size: "1.0 GB",
        sizeBytes: 1_020_000_000,
        capabilities: [.chat, .vision, .fast],
        memoryRequired: String(localized: "1.5 GB RAM while active"),
        backend: .mlx,
        supportsVision: true,
        huggingFaceId: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
        minRecommendedRAMGB: 3,
        imageProcessingEdge: 512,
        isLegacy: false
    )

    /// Qwen2-VL 2B: previous default. Kept so existing users' downloads keep working.
    static let qwen2VL2B = AIModel(
        id: "qwen2-vl-2b",
        name: "Qwen2 Vision 2B",
        shortDescription: String(localized: "Previous generation vision model"),
        fullDescription: String(localized: "Qwen2-VL 2B (4-bit). The previous default model. Still works well; Qwen3 Vision 2B gives better answers at the same size."),
        size: "1.25 GB",
        sizeBytes: 1_250_000_000,
        capabilities: [.chat, .vision, .multilingual],
        memoryRequired: String(localized: "2.5 GB RAM while active"),
        backend: .mlx,
        supportsVision: true,
        huggingFaceId: "mlx-community/Qwen2-VL-2B-Instruct-4bit",
        minRecommendedRAMGB: 6,
        imageProcessingEdge: 768,
        isLegacy: true
    )

    /// Apple Intelligence: the built-in on-device model. Instant, no download,
    /// text-only. Availability is checked at runtime.
    static let appleIntelligence = AIModel(
        id: "apple-intelligence",
        name: "Apple Intelligence",
        shortDescription: String(localized: "Built into your iPhone - instant, no download"),
        fullDescription: String(localized: "Apple's on-device model, built into iOS. Starts instantly with no download and handles everyday questions well. Image analysis uses a downloaded vision model."),
        size: String(localized: "Built in"),
        sizeBytes: 0,
        capabilities: [.chat, .fast, .multilingual],
        memoryRequired: String(localized: "Managed by iOS"),
        backend: .appleIntelligence,
        supportsVision: false,
        huggingFaceId: nil,
        minRecommendedRAMGB: 0,
        imageProcessingEdge: 768,
        isLegacy: false
    )

    /// All downloadable models (legacy ones included; pickers decide visibility).
    static let allModels: [AIModel] = [qwen3VL8BPro, qwen3VL2B, smolVLM2, qwen2VL2B]

    /// True when this device can offer the model. RAM figures up to 6 GB are
    /// soft recommendations (every supported iPhone may still choose those
    /// models); larger figures are hard requirements that hide the model on
    /// lesser devices to prevent out-of-memory crashes.
    func fitsThisDevice() -> Bool {
        minRecommendedRAMGB <= max(DeviceCapability.physicalMemoryGB, 6)
    }

    static func model(withId id: String) -> AIModel? {
        if id == appleIntelligence.id { return appleIntelligence }
        return allModels.first { $0.id == id }
    }

    /// The downloadable model recommended for this device.
    static var recommendedDownloadModel: AIModel {
        DeviceCapability.physicalMemoryGB >= 6 ? qwen3VL2B : smolVLM2
    }
}

// MARK: - Device Capability

enum DeviceCapability {

    /// Physical memory in whole gigabytes (e.g. 4, 6, 8).
    static var physicalMemoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0).rounded())
    }

    /// True when the device has limited RAM and should prefer the light model.
    static var isLowMemoryDevice: Bool {
        physicalMemoryGB < 6
    }
}

// MARK: - Download State

enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed(String)
}
