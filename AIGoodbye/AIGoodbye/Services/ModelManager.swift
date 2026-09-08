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
import Hub

@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    /// Bumped whenever installed models change so views refresh.
    @Published private(set) var revision: Int = 0

    private init() {}

    // MARK: - Locations

    /// Root of the Hugging Face download cache used by the MLX library.
    ///
    /// Excluded from backup: this is up to 6 GB per model of data that can be
    /// downloaded again at any time. Letting it into iCloud backups wastes
    /// the user's quota and violates Apple's Data Storage Guidelines.
    let hubModelsRoot: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("huggingface/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ConversationManager.excludeFromBackup(root)
        return root
    }()

    func modelDirectory(for model: AIModel) -> URL? {
        guard let hfId = model.huggingFaceId else { return nil }
        return hubModelsRoot.appendingPathComponent(hfId, isDirectory: true)
    }

    /// The Hub client the loader MUST be given.
    ///
    /// `HubApi` resolves a repository at `<downloadBase>/models/<id>`, and
    /// `hubModelsRoot` is exactly `<Documents>/huggingface/models`, so this
    /// points the library at the files the prefetcher wrote.
    ///
    /// Without it the library uses its own default, which moved to
    /// `Library/Caches` in mlx-swift-lm 2.25.5. The app then reported a model
    /// as downloaded, and the loader - looking in a different folder - quietly
    /// downloaded all 1.8 GB a second time behind "Preparing...", ignoring
    /// the Wi-Fi-only setting and the free-space check, and failed outright
    /// when offline with "Repository not available locally". That is what
    /// "the AI never answers" looked like from the user's side.
    nonisolated var hub: HubApi {
        HubApi(downloadBase: hubModelsRoot.deletingLastPathComponent())
    }

    // MARK: - State

    /// Name of the marker file written once a download is verified complete.
    private static let completeMarkerName = ".aig_download_complete"

    /// Cached answers for `isModelDownloaded` and `downloadedSizeBytes`.
    ///
    /// Both walk the filesystem, and both are reached from SwiftUI view
    /// bodies - `ChatEngine.status` is read on every streamed token, and the
    /// storage screen asks for every model on every render. Without a cache
    /// that is dozens of syscalls a second on the main thread, and for a
    /// model without its completion marker, a full recursive directory walk.
    private var downloadedCache: [String: Bool] = [:]
    private var sizeCache: [String: Int64] = [:]

    private func invalidateCaches() {
        downloadedCache.removeAll()
        sizeCache.removeAll()
    }

    func isModelDownloaded(_ model: AIModel) -> Bool {
        if let cached = downloadedCache[model.id] { return cached }
        let result = computeIsModelDownloaded(model)
        downloadedCache[model.id] = result
        return result
    }

    private func computeIsModelDownloaded(_ model: AIModel) -> Bool {
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
        invalidateCaches()
        revision += 1
    }

    func downloadedSizeBytes(for model: AIModel) -> Int64 {
        if let cached = sizeCache[model.id] { return cached }
        let size = currentSizeOnDisk(for: model)
        sizeCache[model.id] = size
        return size
    }

    /// Uncached, for progress polling during a download. Reading the cached
    /// value there would freeze the progress bar at whatever the size was
    /// when the download started - and then trip the "stalled" warning.
    func currentSizeOnDisk(for model: AIModel) -> Int64 {
        guard let dir = modelDirectory(for: model) else { return 0 }
        return directorySize(dir)
    }

    /// Recompute what is on disk. Call when a download finishes or the
    /// storage screen appears - not from a view body.
    func refreshDiskState() {
        invalidateCaches()
        revision += 1
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
        invalidateCaches()
        revision += 1
    }

    func noteModelInstalled(_ model: AIModel) {
        invalidateCaches()
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
