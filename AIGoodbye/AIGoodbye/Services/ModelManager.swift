//
//  ModelManager.swift
//  AIGoodbye
//
//  Storage management for downloaded models.
//
//  v3.0: models are downloaded by the MLX library into the Hugging Face cache
//  inside the app's Documents folder. This manager knows where they live,
//  whether they are complete, how much space they use, and how to delete them.
//  (The old GGUF background-download machinery is gone.)
//

import Foundation
import Combine

@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    /// Bumped whenever installed models change so views refresh.
    @Published private(set) var revision: Int = 0

    private init() {}

    // MARK: - Locations

    /// Root of the Hugging Face download cache used by the MLX library.
    var hubModelsRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("huggingface/models", isDirectory: true)
    }

    func modelDirectory(for model: AIModel) -> URL? {
        guard let hfId = model.huggingFaceId else { return nil }
        return hubModelsRoot.appendingPathComponent(hfId, isDirectory: true)
    }

    // MARK: - State

    /// Name of the marker file written once a download is verified complete.
    private static let completeMarkerName = ".aig_download_complete"

    func isModelDownloaded(_ model: AIModel) -> Bool {
        guard let dir = modelDirectory(for: model) else { return false }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return false }
        // A complete model has at least one weights file and a config...
        let hasWeights = contents.contains { $0.pathExtension == "safetensors" }
        let hasConfig = contents.contains { $0.lastPathComponent == "config.json" }
        guard hasWeights && hasConfig else { return false }

        // ...but a download killed mid-flight can leave exactly that state.
        // Require the completion marker, or (for models downloaded before the
        // marker existed) an on-disk size close to the expected size.
        if FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(Self.completeMarkerName).path
        ) {
            return true
        }
        return downloadedSizeBytes(for: model) >= Int64(Double(model.sizeBytes) * 0.9)
    }

    /// Record that this model's files are verified complete (called after the
    /// model successfully loads).
    func markDownloadComplete(_ model: AIModel) {
        guard let dir = modelDirectory(for: model) else { return }
        let marker = dir.appendingPathComponent(Self.completeMarkerName)
        try? Data().write(to: marker)
        revision += 1
    }

    func downloadedSizeBytes(for model: AIModel) -> Int64 {
        guard let dir = modelDirectory(for: model) else { return 0 }
        return directorySize(dir)
    }

    var totalDownloadedBytes: Int64 {
        AIModel.allModels.reduce(0) { $0 + downloadedSizeBytes(for: $1) }
    }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalDownloadedBytes, countStyle: .file)
    }

    // MARK: - Mutations

    func deleteModel(_ model: AIModel) {
        guard let dir = modelDirectory(for: model) else { return }
        try? FileManager.default.removeItem(at: dir)
        revision += 1
    }

    func noteModelInstalled(_ model: AIModel) {
        revision += 1
    }

    // MARK: - Helpers

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            )
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
