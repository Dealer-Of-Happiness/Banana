//
//  AIModel.swift
//  AIGoodbye
//
//  AI model catalog with device-aware recommendations.
//  Chat templates are applied by the MLX library (each model's own template),
//  so models no longer carry manual template definitions.
//

import Foundation
import UIKit
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

    /// Repetition penalty for this model's answers. 1.15 keeps the small
    /// Qwen3-VL and SmolVLM models from looping. The Qwen3.5 family was less
    /// accurate with it - it pushed words a sentence needs, like "blue" and
    /// "wavelength" in an answer about why the sky is blue, out of the
    /// sentence - and in long answers it doesn't loop at 1.05.
    var repetitionPenalty: Float {
        (huggingFaceId ?? "").localizedCaseInsensitiveContains("qwen3.5") ? 1.05 : 1.15
    }
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

    /// Qwen3-VL 2B: the default for devices with 6 GB of RAM or more.
    static var qwen3VL2B: AIModel {
        let bytes: Int64 = 1_780_000_000
        return AIModel(
            id: "qwen3-vl-2b",
            name: "Qwen3 Vision 2B",
            shortDescription: L10n.text("Proven vision model - 30+ languages"),
            fullDescription: L10n.text("Qwen3-VL 2B (4-bit). A proven small vision model with sharp image understanding and wide language coverage. Qwen3.5 Vision 2B is the newer model at about the same size."),
            size: AIModel.formattedCatalogSize(bytes),
            sizeBytes: bytes,
            capabilities: [.chat, .vision, .multilingual, .documentAnalysis],
            memoryRequired: L10n.text("3 GB RAM while active"),
            backend: .mlx,
            supportsVision: true,
            huggingFaceId: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
            minRecommendedRAMGB: 6,
            imageProcessingEdge: 768,
            isLegacy: false
        )
    }

    /// Qwen3-VL 8B: the previous large model, kept for people who already
    /// use it. Only for phones with 12 GB of RAM. The id is unchanged so
    /// existing downloads keep working; "Pro" moved to Qwen3.5 9B.
    static var qwen3VL8BPro: AIModel {
        let bytes: Int64 = 5_760_000_000
        return AIModel(
            id: "qwen3-vl-8b",
            name: "Qwen3 Vision 8B",
            shortDescription: L10n.text("Previous-generation large model"),
            fullDescription: L10n.text("Qwen3-VL 8B (4-bit). Deep reasoning and sharp image understanding from the previous Qwen generation. It needs more memory than iOS lets one app use on iPhone, so AiGoodbye offers it on iPads and Macs that can run it. Qwen3.5 Vision 9B Pro is newer and usually gives better answers."),
            size: AIModel.formattedCatalogSize(bytes),
            sizeBytes: bytes,
            capabilities: [.chat, .vision, .multilingual, .documentAnalysis],
            memoryRequired: L10n.text("About 7 GB RAM while active"),
            backend: .mlx,
            supportsVision: true,
            huggingFaceId: "mlx-community/Qwen3-VL-8B-Instruct-4bit",
            minRecommendedRAMGB: 16,
            imageProcessingEdge: 768,
            isLegacy: false
        )
    }

    /// SmolVLM2 500M: compact vision model for devices with 4 GB of RAM.
    static var smolVLM2: AIModel {
        let bytes: Int64 = 1_020_000_000
        return AIModel(
            id: "smolvlm2-500m",
            name: "Smol Vision 500M",
            shortDescription: L10n.text("Compact vision model - simple answers"),
            fullDescription: L10n.text("SmolVLM2 500M. A compact model that describes photos quickly. It often gets sums and reasoning wrong; Qwen3.5 Vision 0.8B answers better and needs less memory."),
            size: AIModel.formattedCatalogSize(bytes),
            sizeBytes: bytes,
            capabilities: [.chat, .vision, .fast],
            memoryRequired: L10n.text("About 2 GB RAM while active"),
            backend: .mlx,
            supportsVision: true,
            huggingFaceId: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
            minRecommendedRAMGB: 3,
            imageProcessingEdge: 512,
            isLegacy: false
        )
    }

    /// Qwen2-VL 2B: previous default. Kept so existing users' downloads keep working.
    static var qwen2VL2B: AIModel {
        let bytes: Int64 = 1_250_000_000
        return AIModel(
            id: "qwen2-vl-2b",
            name: "Qwen2 Vision 2B",
            shortDescription: L10n.text("Previous generation vision model"),
            fullDescription: L10n.text("Qwen2-VL 2B (4-bit). The previous default model. Still works well; Qwen3 Vision 2B gives better answers at the same size."),
            size: AIModel.formattedCatalogSize(bytes),
            sizeBytes: bytes,
            capabilities: [.chat, .vision, .multilingual],
            memoryRequired: L10n.text("2.5 GB RAM while active"),
            backend: .mlx,
            supportsVision: true,
            huggingFaceId: "mlx-community/Qwen2-VL-2B-Instruct-4bit",
            minRecommendedRAMGB: 6,
            imageProcessingEdge: 768,
            isLegacy: true
        )
    }

    // MARK: Qwen3.5 (natively multimodal: every size sees images)
    //
    // Sizes are the bytes the prefetcher downloads (weights, JSON, chat
    // template) from the Hugging Face listing, so the picker's "0.7 GB" is
    // what actually lands on the phone. Thinking stays off: the chat
    // template closes an empty think block unless asked to think.

    /// Qwen3.5 0.8B at 8 bits: the default for 4 GB devices.
    ///
    /// The same model as `qwen35_08B` with twice the bits per weight, and on
    /// a small model that is the difference between getting simple sums
    /// right or not. On 87 test questions with the app's settings (Mac,
    /// same engine): 26 of 27 sums right, where the 4-bit one with the old
    /// prompt got 20 (it said "3 + 1 + 4 = 7 apples" to "I have 3, give 1
    /// away, buy 4"); 69 of 87 in all against 62. It also reads text in
    /// photos the 4-bit one could not. Both still get world facts wrong
    /// (the German flag, the Italian one): that is what 0.8 billion
    /// parameters hold, at any precision - full 16-bit weights answer the
    /// same, and so does Gemma 3 1B.
    static var qwen35_08B8: AIModel {
        let bytes: Int64 = 1_027_974_615
        return AIModel(
            id: "qwen3.5-0.8b-8bit",
            name: "Qwen3.5 Vision 0.8B",
            shortDescription: L10n.text("Small and careful - for older iPhones"),
            fullDescription: L10n.text("Qwen3.5 0.8B (8-bit). The smallest Qwen3.5 at full quality: much better at sums and at reading text in photos than the Lite version, and it understands many languages. Like every model this small it often gets facts wrong, so check anything important."),
            size: AIModel.formattedCatalogSize(bytes),
            sizeBytes: bytes,
            capabilities: [.chat, .vision, .multilingual, .fast],
            memoryRequired: L10n.text("About 2 GB RAM while active"),
            backend: .mlx,
            supportsVision: true,
            huggingFaceId: "mlx-community/Qwen3.5-0.8B-8bit",
            minRecommendedRAMGB: 4,
            imageProcessingEdge: 640,
            isLegacy: false
        )
    }

    /// Qwen3.5 0.8B at 4 bits: the lightest, for devices the 8-bit one
    /// does not fit.
    static var qwen35_08B: AIModel {
        let bytes: Int64 = 652_027_143
        return AIModel(
            id: "qwen3.5-0.8b",
            name: "Qwen3.5 Vision 0.8B Lite",
            shortDescription: L10n.text("Lightest - for iPhones with the least memory"),
            fullDescription: L10n.text("Qwen3.5 0.8B (4-bit). The lightest version of the smallest Qwen3.5, for devices that can't run the full one. It understands photos and many languages, but it often gets sums and facts wrong."),
            size: AIModel.formattedCatalogSize(bytes),
            sizeBytes: bytes,
            capabilities: [.chat, .vision, .multilingual, .fast],
            memoryRequired: L10n.text("About 1.7 GB RAM while active"),
            backend: .mlx,
            supportsVision: true,
            huggingFaceId: "mlx-community/Qwen3.5-0.8B-4bit",
            minRecommendedRAMGB: 4,
            imageProcessingEdge: 640,
            isLegacy: false
        )
    }

    /// Qwen3.5 2B: newest-generation all-rounder for 6 GB devices.
    static var qwen35_2B: AIModel {
        let bytes: Int64 = 1_749_079_691
        return AIModel(
            id: "qwen3.5-2b",
            name: "Qwen3.5 Vision 2B",
            shortDescription: L10n.text("Fast all-rounder - newest generation"),
            fullDescription: L10n.text("Qwen3.5 2B (4-bit). The newest Qwen generation at about the same size as Qwen3 Vision 2B: quick, keeps track of the conversation well, and works in many languages. Needs a device with 6 GB of RAM or more."),
            size: AIModel.formattedCatalogSize(bytes),
            sizeBytes: bytes,
            capabilities: [.chat, .vision, .multilingual, .documentAnalysis],
            memoryRequired: L10n.text("About 2.5 GB RAM while active"),
            backend: .mlx,
            supportsVision: true,
            huggingFaceId: "mlx-community/Qwen3.5-2B-4bit",
            minRecommendedRAMGB: 6,
            imageProcessingEdge: 768,
            isLegacy: false
        )
    }

    /// Qwen3.5 4B: the most capable model an iPhone can run (8 GB and up,
    /// including the 12 GB iPhone 17 Pro, 18 Pro and Duo).
    static var qwen35_4B: AIModel {
        let bytes: Int64 = 3_061_129_077
        return AIModel(
            id: "qwen3.5-4b",
            name: "Qwen3.5 Vision 4B",
            shortDescription: L10n.text("Smartest for iPhone - 8 GB and up"),
            fullDescription: L10n.text("Qwen3.5 4B (4-bit). Noticeably smarter than the 2B models, with strong image understanding and reasoning. The most capable model iOS lets an app run on iPhone. Needs 8 GB of RAM or more: iPhone 15 Pro, iPhone 16 and newer, including iPhone 17 Pro, iPhone 18 Pro and iPhone Duo."),
            size: AIModel.formattedCatalogSize(bytes),
            sizeBytes: bytes,
            capabilities: [.chat, .vision, .multilingual, .documentAnalysis],
            memoryRequired: L10n.text("About 4.5 GB RAM while active"),
            backend: .mlx,
            supportsVision: true,
            huggingFaceId: "mlx-community/Qwen3.5-4B-4bit",
            minRecommendedRAMGB: 8,
            imageProcessingEdge: 768,
            isLegacy: false
        )
    }

    /// Qwen3.5 9B "Pro": the most capable model we offer. Needs more memory
    /// than iOS gives one app on any iPhone (about 6.3 GB on 12 GB models),
    /// so it is for iPads and Macs; shown disabled elsewhere.
    static var qwen35_9BPro: AIModel {
        let bytes: Int64 = 5_977_071_067
        return AIModel(
            id: "qwen3.5-9b",
            name: "Qwen3.5 Vision 9B Pro",
            shortDescription: L10n.text("Our most capable model - for iPad and Mac"),
            fullDescription: L10n.text("Qwen3.5 9B (4-bit). The most capable model we offer: deeper reasoning, richer answers and the sharpest image understanding. It needs about 7.4 GB of memory while answering, more than iOS lets one app use on iPhone, so AiGoodbye offers it on iPads and Macs that can run it."),
            size: AIModel.formattedCatalogSize(bytes),
            sizeBytes: bytes,
            capabilities: [.chat, .vision, .multilingual, .documentAnalysis],
            memoryRequired: L10n.text("About 7 GB RAM while active"),
            backend: .mlx,
            supportsVision: true,
            huggingFaceId: "mlx-community/Qwen3.5-9B-4bit",
            minRecommendedRAMGB: 16,
            imageProcessingEdge: 768,
            isLegacy: false
        )
    }

    // MARK: Gemma 4 (Google)

    /// Gemma 4 E2B: Google's efficient model for 8 GB devices.
    static var gemma4E2B: AIModel {
        let bytes: Int64 = 3_583_086_498
        return AIModel(
            id: "gemma4-e2b",
            name: "Gemma 4 E2B",
            shortDescription: L10n.text("Google's Gemma 4 - efficient and multilingual"),
            fullDescription: L10n.text("Gemma 4 E2B (4-bit) from Google. Strong multilingual chat and image understanding in an efficient design. Needs a device with 8 GB of RAM or more. Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms."),
            size: AIModel.formattedCatalogSize(bytes),
            sizeBytes: bytes,
            capabilities: [.chat, .vision, .multilingual],
            memoryRequired: L10n.text("About 4.5 GB RAM while active"),
            backend: .mlx,
            supportsVision: true,
            huggingFaceId: "mlx-community/gemma-4-e2b-it-4bit",
            minRecommendedRAMGB: 8,
            imageProcessingEdge: 768,
            isLegacy: false
        )
    }

    /// Gemma 4 E4B: the larger efficient Gemma, for iPads and Macs.
    static var gemma4E4B: AIModel {
        let bytes: Int64 = 5_179_239_349
        return AIModel(
            id: "gemma4-e4b",
            name: "Gemma 4 E4B",
            shortDescription: L10n.text("Google's Gemma 4 - richer answers, for iPad and Mac"),
            fullDescription: L10n.text("Gemma 4 E4B (4-bit) from Google. Richer answers and sharper image understanding than E2B. It needs about 6.3 GB of memory while answering, more than iOS lets one app use on iPhone, so AiGoodbye offers it on iPads and Macs that can run it. Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms."),
            size: AIModel.formattedCatalogSize(bytes),
            sizeBytes: bytes,
            capabilities: [.chat, .vision, .multilingual, .documentAnalysis],
            memoryRequired: L10n.text("About 6 GB RAM while active"),
            backend: .mlx,
            supportsVision: true,
            huggingFaceId: "mlx-community/gemma-4-e4b-it-4bit",
            minRecommendedRAMGB: 16,
            imageProcessingEdge: 768,
            isLegacy: false
        )
    }

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

    /// The models we ship and test ourselves, most capable first within
    /// each generation: the pickers show them in this order (Recommended
    /// first, models too large for the device last).
    static var builtInModels: [AIModel] {
        [qwen35_9BPro, gemma4E4B, qwen3VL8BPro,
         qwen35_4B, gemma4E2B,
         qwen35_2B, qwen3VL2B,
         qwen35_08B8, qwen35_08B, smolVLM2,
         qwen2VL2B]
    }

    /// All downloadable models, including any the user added from Hugging
    /// Face (legacy ones included; pickers decide visibility).
    static var allModels: [AIModel] {
        builtInModels + CustomModelRegistry.specs.map(AIModel.init(custom:))
    }

    /// True when this model was added by the user rather than shipped by us.
    var isCustom: Bool { id.hasPrefix(CustomModelSpec.idPrefix) }

    /// The one memory gate: whether this device can ever run the model.
    /// The picker, Setup, the custom-model check and the load preflight all
    /// ask this, so none of them can offer what another refuses.
    ///
    /// It compares what the model needs while answering with the memory
    /// iOS actually gives this app on this device (`DeviceCapability
    /// .modelMemoryBudgetGB`, measured at run time), not with what happens
    /// to be free this instant - that transient question is answered at load
    /// time. A model that has already loaded and answered on this device
    /// keeps its place whatever the estimate says: that is better evidence.
    func fitsThisDevice(budgetGB: Double = DeviceCapability.modelMemoryBudgetGB) -> Bool {
        guard backend == .mlx else { return true }
        if memoryNeededGB <= budgetGB { return true }
        return ModelManager.shared.hasLoadedBefore(self)
    }

    /// Peak memory while answering, a photo included, in decimal GB.
    ///
    /// Measured for the models we ship: MLX's peak with the app's own
    /// settings on a Mac running the same engine, plus 5% and 0.1 GB for
    /// tokenizer and image buffers. The file size alone misleads: Smol
    /// Vision's 1 GB file peaks higher than Qwen3.5's 0.65 GB one, and the
    /// 9B's 6 GB file peaks at nearly 7 GB. Models people add themselves
    /// fall back to the size-based estimate.
    var memoryNeededGB: Double {
        Self.measuredMemoryGB[id] ?? Double(AIModel.workingSetGB(forModelBytes: sizeBytes))
    }

    nonisolated static let measuredMemoryGB: [String: Double] = [
        "qwen3.5-0.8b": 1.7,
        // 1.87 GB peak with a photo at the 640-point edge it uses.
        "qwen3.5-0.8b-8bit": 2.1,
        "smolvlm2-500m": 2.0,
        "qwen3.5-2b": 2.8,
        "qwen3-vl-2b": 2.9,
        "qwen2-vl-2b": 2.4,
        "qwen3.5-4b": 4.5,
        "gemma4-e2b": 4.7,
        "gemma4-e4b": 6.3,
        "qwen3-vl-8b": 7.1,
        "qwen3.5-9b": 7.4,
    ]

    /// How much of the Creativity setting a model gets. The smallest models
    /// answer simple questions far more reliably with little randomness: at
    /// the default 0.7 the 0.8B model got "3 apples, give 1 away, buy 4" right
    /// in 2 runs of 5; at 0.1, in 4 of 5 (and every time with none). The
    /// 2B and larger models were right either way, so they keep the setting.
    var temperatureScale: Double {
        sizeBytes < 1_100_000_000 ? 0.15 : 1.0
    }

    static func model(withId id: String) -> AIModel? {
        if id == appleIntelligence.id { return appleIntelligence }
        return allModels.first { $0.id == id }
    }

    /// The downloadable model recommended for this device: a quick first
    /// download that answers well. Bigger models are a choice in the picker,
    /// not the default - on a 12 GB phone the 9B Pro is a 6 GB download
    /// and noticeably slower, which is the wrong first impression.
    /// Still Qwen3-VL 2B, not Qwen3.5 2B: side by side they were even (the
    /// newer one followed the conversation better, the older one got facts
    /// right more often), and only the older one has run on real phones.
    ///
    /// Below 6 GB, Qwen3.5 0.8B rather than Smol Vision: Smol could not say
    /// how many apples are left after giving one away and buying four, at
    /// any setting, while the 0.8B usually could - and it needs less memory.
    ///
    /// The 8-bit 0.8B before the 4-bit one: on sums it went from wrong a
    /// third of the time to right every time. The 4-bit one remains for
    /// devices where only it fits.
    static var recommendedDownloadModel: AIModel {
        if DeviceCapability.physicalMemoryGB >= 6, qwen3VL2B.fitsThisDevice() { return qwen3VL2B }
        if qwen35_08B8.fitsThisDevice() { return qwen35_08B8 }
        if qwen35_08B.fitsThisDevice() { return qwen35_08B }
        return smolVLM2
    }

    /// Small enough that the full system prompt costs it accuracy.
    ///
    /// The app's usual prompt (who made AiGoodbye, its website, Markdown,
    /// images) made the 0.8B models introduce themselves, then invent a
    /// biography for a name they had never seen, and spend the words a sum
    /// needs. A short prompt that asks for care with facts and for the steps
    /// of a calculation raised the 8-bit model from 64 to 69 of 87 test
    /// questions, and its sums from 21 to 26 of 27. The same brand prompt
    /// with the step instruction added got 63: the prompt's length is the
    /// problem, not a missing sentence.
    var prefersCompactPrompt: Bool {
        sizeBytes < 1_100_000_000
            && (huggingFaceId ?? "").localizedCaseInsensitiveContains("qwen3.5")
    }

    // MARK: - Sizes

    /// The one formatter for every byte count the app shows - catalog sizes,
    /// download progress, storage totals - so a size reads the same in the
    /// picker, the chip and the storage screen. Never "Zero KB": zero is
    /// "0 bytes", like every other number.
    /// `nonisolated(unsafe)`: Foundation formatters are safe to use from any
    /// thread once configured, and this one is never mutated after creation.
    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    nonisolated static func formattedBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    /// A catalog size, rounded to the nearest 100 MB first: "1.8 GB" is a
    /// size people remember and compare; the formatter's own "1.78 GB" is
    /// precision nobody asked for. Progress and storage keep exact bytes.
    nonisolated static func formattedCatalogSize(_ bytes: Int64) -> String {
        let step: Int64 = 100_000_000
        let rounded = bytes >= step ? ((bytes + step / 2) / step) * step : bytes
        return formattedBytes(rounded)
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

    // MARK: Measured app memory limit

    /// This process's physical footprint: the number iOS compares with the
    /// app's memory limit before ending it.
    nonisolated static var footprintBytes: UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// The most memory iOS lets this app use, in bytes, as the device itself
    /// reports it: what is still available plus what the app already uses.
    /// That sum is the same at any moment, model loaded or not. Nil where
    /// iOS reports no limit (Simulator, Mac).
    ///
    /// Measured, not guessed. The old rule assumed an app gets about 70% of
    /// the RAM, which offered the 8B model to 12 GB iPhones; an iPhone 18
    /// Pro Max reported about 6.3 GB for the whole app, so the model could
    /// never load there and people were told to close other apps.
    nonisolated static var appMemoryLimitBytes: UInt64? {
        #if DEBUG
        // Lets the Simulator stand in for a real phone's limit (store
        // screenshots, picker checks): AIG_MEMORY_LIMIT_GB=6.3 is an iPhone
        // 18 Pro Max, 2.5 a 4 GB iPhone. Debug builds only.
        if let value = ProcessInfo.processInfo.environment["AIG_MEMORY_LIMIT_GB"].flatMap(Double.init) {
            return UInt64(value * 1_000_000_000)
        }
        #endif
        #if targetEnvironment(simulator)
        return nil
        #else
        let available = os_proc_available_memory()
        guard available > 0, let footprint = footprintBytes else { return nil }
        return UInt64(available) + footprint
        #endif
    }

    /// "Too large for this iPhone", naming the device it is running on: the
    /// same app runs on iPad and Mac, where "iPhone" was simply wrong.
    @MainActor
    static var tooLargeText: String {
        if ProcessInfo.processInfo.isiOSAppOnMac { return L10n.text("Too large for this Mac") }
        if UIDevice.current.userInterfaceIdiom == .pad { return L10n.text("Too large for this iPad") }
        return L10n.text("Too large for this iPhone")
    }

    /// What the app needs for itself while a model answers: interface,
    /// conversations, speech, the photo being looked at.
    nonisolated static let appOverheadGB = 0.3

    /// Memory a model may use on this device, in decimal GB: the measured
    /// limit minus the app's own share. Falls back to the old 70%-of-RAM
    /// rule only where iOS reports no limit (Simulator, Mac, where memory is
    /// plentiful anyway).
    nonisolated static var modelMemoryBudgetGB: Double {
        if let limit = appMemoryLimitBytes {
            return Double(limit) / 1_000_000_000 - appOverheadGB
        }
        return Double(physicalMemoryGB) * 0.7 - appOverheadGB
    }

    /// Kept for the custom-model check, which speaks in whole gigabytes.
    nonisolated static var memoryCeilingGB: Int {
        max(1, Int(modelMemoryBudgetGB.rounded(.down)))
    }

    /// Whether a model needing `neededGB` can load right now, with what is
    /// actually free at this moment (after the previous model is released).
    nonisolated static func canLoad(neededGB: Double) -> Bool {
        neededGB <= usableMemoryGBExactDecimal - 0.1
    }

    /// What is free right now in decimal GB (`usableMemoryGBExact` is GiB).
    nonisolated static var usableMemoryGBExactDecimal: Double {
        let available = Double(os_proc_available_memory()) / 1_000_000_000
        guard available > 0 else { return Double(physicalMemoryGB) * 0.6 }
        return available
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
        if let limit = appMemoryLimitBytes {
            return max(1, Int((Double(limit) / 1_000_000_000 * 0.55).rounded(.down)))
        }
        return max(2, Int((Double(physicalMemoryGB) * 0.55).rounded(.down)))
    }
}
