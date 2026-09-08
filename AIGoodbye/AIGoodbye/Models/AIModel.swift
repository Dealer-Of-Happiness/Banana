//
//  AIModel.swift
//  AIGoodbye
//
//  AI model catalog with device-aware recommendations.
//  Chat templates are applied by the MLX library (each model's own template),
//  so models no longer carry manual template definitions.
//

import Foundation
import os

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
    static var qwen3VL2B: AIModel { AIModel(
        id: "qwen3-vl-2b",
        name: "Qwen3 Vision 2B",
        shortDescription: L10n.text("Best quality - vision, 30+ languages"),
        fullDescription: L10n.text("Qwen3-VL 2B (4-bit). The strongest small vision model available: sharper image understanding, better reasoning, and wide language coverage. Recommended for iPhone 14 Pro and newer."),
        size: "1.8 GB",
        sizeBytes: 1_780_000_000,
        capabilities: [.chat, .vision, .multilingual, .documentAnalysis],
        memoryRequired: L10n.text("3 GB RAM while active"),
        backend: .mlx,
        supportsVision: true,
        huggingFaceId: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
        minRecommendedRAMGB: 6,
        imageProcessingEdge: 768,
        isLegacy: false
    ) }

    /// Qwen3-VL 8B "Pro": the most powerful model we offer. Only for phones
    /// with 12 GB of RAM (iPhone 17 Pro / Pro Max class); hidden elsewhere.
    static var qwen3VL8BPro: AIModel { AIModel(
        id: "qwen3-vl-8b",
        name: "Qwen3 Vision 8B Pro",
        shortDescription: L10n.text("Maximum intelligence - for Pro phones"),
        fullDescription: L10n.text("Qwen3-VL 8B (4-bit). Our most powerful model: noticeably deeper reasoning, richer answers, and the sharpest image understanding. Requires a phone with 12 GB of RAM, like iPhone 17 Pro Max. Responses are slower than the 2B model."),
        size: "5.8 GB",
        sizeBytes: 5_760_000_000,
        capabilities: [.chat, .vision, .multilingual, .documentAnalysis],
        memoryRequired: L10n.text("About 7 GB RAM while active"),
        backend: .mlx,
        supportsVision: true,
        huggingFaceId: "mlx-community/Qwen3-VL-8B-Instruct-4bit",
        minRecommendedRAMGB: 12,
        imageProcessingEdge: 768,
        isLegacy: false
    ) }

    /// SmolVLM2 500M: compact vision model for devices with 4 GB of RAM.
    static var smolVLM2: AIModel { AIModel(
        id: "smolvlm2-500m",
        name: "Smol Vision 500M",
        shortDescription: L10n.text("Light and fast - great for older iPhones"),
        fullDescription: L10n.text("SmolVLM2 500M. A compact vision model that runs comfortably on older devices (iPhone 11-13). Faster responses and lower memory use, with simpler answers than the larger models."),
        size: "1.0 GB",
        sizeBytes: 1_020_000_000,
        capabilities: [.chat, .vision, .fast],
        memoryRequired: L10n.text("1.5 GB RAM while active"),
        backend: .mlx,
        supportsVision: true,
        huggingFaceId: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
        minRecommendedRAMGB: 3,
        imageProcessingEdge: 512,
        isLegacy: false
    ) }

    /// Qwen2-VL 2B: previous default. Kept so existing users' downloads keep working.
    static var qwen2VL2B: AIModel { AIModel(
        id: "qwen2-vl-2b",
        name: "Qwen2 Vision 2B",
        shortDescription: L10n.text("Previous generation vision model"),
        fullDescription: L10n.text("Qwen2-VL 2B (4-bit). The previous default model. Still works well; Qwen3 Vision 2B gives better answers at the same size."),
        size: "1.25 GB",
        sizeBytes: 1_250_000_000,
        capabilities: [.chat, .vision, .multilingual],
        memoryRequired: L10n.text("2.5 GB RAM while active"),
        backend: .mlx,
        supportsVision: true,
        huggingFaceId: "mlx-community/Qwen2-VL-2B-Instruct-4bit",
        minRecommendedRAMGB: 6,
        imageProcessingEdge: 768,
        isLegacy: true
    ) }

    /// Apple Intelligence: the built-in on-device model. Instant, no download,
    /// text-only. Availability is checked at runtime.
    static var appleIntelligence: AIModel { AIModel(
        id: "apple-intelligence",
        name: "Apple Intelligence",
        shortDescription: L10n.text("Built into your device - instant, no download"),
        fullDescription: L10n.text("Apple's on-device model, built into iOS. Starts instantly with no download and handles everyday questions well. Image analysis uses a downloaded vision model."),
        size: L10n.text("Built in"),
        sizeBytes: 0,
        capabilities: [.chat, .fast, .multilingual],
        memoryRequired: L10n.text("Managed by iOS"),
        backend: .appleIntelligence,
        supportsVision: false,
        huggingFaceId: nil,
        minRecommendedRAMGB: 0,
        imageProcessingEdge: 768,
        isLegacy: false
    ) }

    /// The models we ship and test ourselves.
    static var builtInModels: [AIModel] { [qwen3VL8BPro, qwen3VL2B, smolVLM2, qwen2VL2B] }

    /// All downloadable models, including any the user added from Hugging
    /// Face (legacy ones included; pickers decide visibility).
    static var allModels: [AIModel] {
        builtInModels + CustomModelRegistry.specs.map(AIModel.init(custom:))
    }

    /// True when this model was added by the user rather than shipped by us.
    var isCustom: Bool { id.hasPrefix(CustomModelSpec.idPrefix) }

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

/// Deliberately `nonisolated` throughout: these read process-wide values that
/// are safe from any thread, and they are consulted from background work -
/// model loading, download sizing - where hopping to the main actor just to
/// read a number would be absurd.
enum DeviceCapability {

    /// Physical memory in whole gigabytes (e.g. 4, 6, 8).
    ///
    /// Decimal gigabytes, deliberately. iOS reports somewhat less than the
    /// nominal figure (a "6 GB" phone shows about 5.5 GiB), and dividing by
    /// 2^30 put such a phone on the wrong side of the rounding: it became a
    /// 5 GB, "low memory" device, was steered to the smallest model, and had
    /// its budget cut - on hardware that runs the recommended one fine.
    nonisolated static var physicalMemoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000_000.0).rounded())
    }

    /// True when the device has limited RAM and should prefer the light model.
    nonisolated static var isLowMemoryDevice: Bool {
        physicalMemoryGB < 6
    }

    /// Memory this app can realistically use, in whole gigabytes. iOS gives
    /// an app far less than the device's physical RAM, so sizing a model
    /// against `physicalMemoryGB` is how you get killed mid-answer.
    nonisolated static var usableMemoryGB: Int {
        Int(usableMemoryGBExact.rounded(.down))
    }

    /// The same figure without rounding. Whole-gigabyte comparisons are a
    /// cliff: a phone reporting 2.99 GB free floored to 2 and was refused a
    /// model whose working set is 3, when it would have run fine.
    nonisolated static var usableMemoryGBExact: Double {
        let available = Double(os_proc_available_memory()) / 1_073_741_824.0
        guard available > 0 else {
            return max(2, Double(physicalMemoryGB) * 0.6)
        }
        return max(1, available)
    }

    /// Whether a model with this working set can be loaded right now.
    ///
    /// Allows a small shortfall: the working-set estimate is deliberately
    /// conservative, and iOS reclaims caches under pressure, so a model that
    /// is 10% over what is free at this instant still loads in practice.
    nonisolated static func canLoad(workingSetGB: Int) -> Bool {
        Double(workingSetGB) <= usableMemoryGBExact * 1.1
    }

    /// The app's memory budget, independent of what is resident right now.
    ///
    /// `usableMemoryGB` reports what is available *at this instant*, which
    /// collapses the moment a model is loaded. Using it for sizing decisions
    /// meant the same setting produced a different answer every session - a
    /// context window that silently shrank once the weights were in, and a
    /// custom model refused on a 12 GB phone with the message "this device
    /// has 12 GB". This is the stable figure those decisions want.
    nonisolated static var memoryBudgetGB: Int {
        max(2, Int((Double(physicalMemoryGB) * 0.55).rounded(.down)))
    }
}
