//
//  CustomModelStore.swift
//  AIGoodbye
//
//  Bring your own model. Anyone can point AiGoodbye at an MLX model on
//  Hugging Face and run it on their own phone - no waiting for us to add it,
//  and still completely offline once downloaded.
//
//  The repo is checked before anything is downloaded: the files MLX needs
//  have to be there, and the model has to fit in this device's memory.
//

import Foundation
import Combine

/// Plain data, deliberately `nonisolated`: specs are decoded and turned into
/// `AIModel`s from background work as well as from the UI.
nonisolated struct CustomModelSpec: Codable, Equatable, Identifiable {
    /// Hugging Face repo, e.g. "mlx-community/Llama-3.2-3B-Instruct-4bit".
    var repoId: String
    var displayName: String
    var sizeBytes: Int64
    var supportsVision: Bool
    var addedAt: Date = Date()

    /// Prefixed so a custom model can never collide with a built-in id.
    var id: String { CustomModelSpec.idPrefix + repoId }

    static let idPrefix = "custom:"
}

/// Thread-safe storage. `AIModel.allModels` is read from non-isolated code,
/// so the list cannot live behind the main actor.
enum CustomModelRegistry {
    private static let defaultsKey = "customModelSpecs"
    private static let lock = NSLock()
    private static var cache: [CustomModelSpec]?

    static var specs: [CustomModelSpec] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let loaded: [CustomModelSpec]
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([CustomModelSpec].self, from: data) {
            loaded = decoded
        } else {
            loaded = []
        }
        cache = loaded
        return loaded
    }

    static func replace(with specs: [CustomModelSpec]) {
        lock.lock()
        cache = specs
        lock.unlock()
        if let data = try? JSONEncoder().encode(specs) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

@MainActor
final class CustomModelStore: ObservableObject {
    static let shared = CustomModelStore()

    @Published private(set) var specs: [CustomModelSpec] = CustomModelRegistry.specs

    /// A hard cap: each of these is gigabytes on disk.
    static let maximumCount = 5

    private init() {}

    var canAddMore: Bool { specs.count < Self.maximumCount }

    func add(_ spec: CustomModelSpec) {
        guard !specs.contains(where: { $0.repoId.lowercased() == spec.repoId.lowercased() }) else { return }
        specs.append(spec)
        CustomModelRegistry.replace(with: specs)
    }

    /// Remove a model completely: free its RAM, drop the selection if it was
    /// the active one, delete the download, and forget the entry. All of it
    /// lives here so no caller can do half the job.
    func remove(_ spec: CustomModelSpec, engine: ChatEngine?) {
        if let model = AIModel.model(withId: spec.id) {
            engine?.modelWasDeleted(model)
            // Free the download too: these are the biggest files the app keeps.
            ModelManager.shared.deleteModel(model)
        }
        if let engine, engine.selectedModel.id == spec.id {
            // Never leave the app pointing at a model that no longer exists.
            engine.select(AIModel.recommendedDownloadModel)
        }
        specs.removeAll { $0.id == spec.id }
        CustomModelRegistry.replace(with: specs)
    }

    func contains(repoId: String) -> Bool {
        specs.contains { $0.repoId.lowercased() == repoId.lowercased() }
    }
}

// MARK: - Turning a spec into a model

extension AIModel {

    nonisolated init(custom spec: CustomModelSpec) {
        let sizeText = ByteCountFormatter.string(fromByteCount: spec.sizeBytes, countStyle: .file)
        let ramGB = AIModel.recommendedRAMGB(forModelBytes: spec.sizeBytes)
        self.init(
            id: spec.id,
            name: spec.displayName,
            shortDescription: L10n.text("Added by you from Hugging Face"),
            fullDescription: L10n.text("\(spec.repoId), added by you from Hugging Face. Community models are not tested by us: quality, speed and language support vary, and some may not load at all."),
            size: sizeText,
            sizeBytes: spec.sizeBytes,
            capabilities: spec.supportsVision ? [.chat, .vision] : [.chat],
            memoryRequired: L10n.text("About \(ramGB) GB RAM while active"),
            backend: .mlx,
            supportsVision: spec.supportsVision,
            huggingFaceId: spec.repoId,
            minRecommendedRAMGB: ramGB,
            imageProcessingEdge: 768,
            isLegacy: false
        )
    }

    /// The device tier a model of this size belongs to, matching how the
    /// built-in catalog is rated (the 5.8 GB Pro model is a 12 GB phone).
    nonisolated static func recommendedRAMGB(forModelBytes bytes: Int64) -> Int {
        let gigabytes = Double(bytes) / 1_000_000_000
        return max(4, Int((gigabytes * 2.0).rounded(.up)))
    }

    /// What the model actually occupies while answering: the weights plus
    /// the key-value cache and working buffers. This is what has to fit in
    /// the memory iOS gives the app.
    nonisolated static func workingSetGB(forModelBytes bytes: Int64) -> Int {
        let gigabytes = Double(bytes) / 1_000_000_000
        return max(2, Int((gigabytes * 1.2 + 0.5).rounded(.up)))
    }
}
