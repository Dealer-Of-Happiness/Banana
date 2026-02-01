//
//  ModelManager.swift
//  AIGoodbye
//
//  Manages AI model downloads and storage with background download support
//

import Foundation
import Combine

@MainActor
class ModelManager: ObservableObject {
    static let shared = ModelManager()

    // Background session identifier
    static let backgroundSessionIdentifier = "com.aigoodbye.modeldownload"

    @Published var downloadStates: [String: ModelDownloadState] = [:]
    @Published var currentModelId: String = "qwen2-vl-2b"
    @Published var downloadProgress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var isDownloading = false
    @Published var downloadingModelId: String?

    private let modelsDirectory: URL
    private var backgroundSession: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    private var downloadContinuation: CheckedContinuation<Void, Error>?
    private var currentDestinationURL: URL?
    private var currentModel: AIModel?

    // Background completion handler from AppDelegate
    var backgroundCompletionHandler: (() -> Void)?

    private init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        modelsDirectory = documentsPath.appendingPathComponent("models")

        // Create models directory if needed
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        // Load saved model preference
        if let savedModelId = UserDefaults.standard.string(forKey: "selectedModelId") {
            currentModelId = savedModelId
        }

        // Migration: Switch to Qwen2-VL-2B (the only available model now)
        if currentModelId != "qwen2-vl-2b" {
            currentModelId = "qwen2-vl-2b"
            UserDefaults.standard.set(currentModelId, forKey: "selectedModelId")
            print("[ModelManager] Migrated to Qwen2-VL-2B model")
        }

        // Check for any in-progress download that was interrupted
        if let downloadingId = UserDefaults.standard.string(forKey: "downloadingModelId") {
            downloadingModelId = downloadingId
            // Will be resumed when background session reconnects
        }

        // Create background session (must be done before any downloads)
        setupBackgroundSession()

        // Initialize download states
        refreshDownloadStates()
    }

    private func setupBackgroundSession() {
        let config = URLSessionConfiguration.background(withIdentifier: ModelManager.backgroundSessionIdentifier)
        config.sessionSendsLaunchEvents = true  // Wake app when download completes
        config.isDiscretionary = false  // Don't delay downloads
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 7200  // 2 hours for large files

        // Allow downloads on cellular if user prefers
        config.allowsCellularAccess = true

        let delegate = BackgroundDownloadDelegate(manager: self)
        backgroundSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Model Path

    func modelPath(for model: AIModel) -> URL {
        // MLX models use a directory, GGUF models use a single file
        if model.backend == .mlx {
            return modelsDirectory.appendingPathComponent(model.fileName, isDirectory: true)
        }
        return modelsDirectory.appendingPathComponent(model.fileName)
    }

    func isModelDownloaded(_ model: AIModel) -> Bool {
        if model.backend == .mlx {
            // MLX models are downloaded automatically by VLMModelFactory on first use
            // Check HuggingFace cache directory for the model
            return isMLXModelInHFCache(model)
        }

        // GGUF models: Check single file in Documents/models
        let path = modelPath(for: model)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return false
        }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
           let fileSize = attributes[.size] as? Int64 {
            let minimumSize = model.sizeBytes / 2
            return fileSize >= minimumSize
        }

        return false
    }

    private func isMLXModelInHFCache(_ model: AIModel) -> Bool {
        guard let hfId = model.huggingFaceId else { return false }

        // HuggingFace cache is typically at ~/.cache/huggingface/hub/models--{org}--{model}
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let hfCacheDir = cacheDir?.appendingPathComponent("huggingface/hub")

        // Convert model ID to cache directory format (e.g., "mlx-community/Qwen3-VL-4B-Instruct-4bit" -> "models--mlx-community--Qwen3-VL-4B-Instruct-4bit")
        let sanitizedId = hfId.replacingOccurrences(of: "/", with: "--")
        let modelCacheDir = hfCacheDir?.appendingPathComponent("models--\(sanitizedId)")

        if let path = modelCacheDir {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue
            }
        }

        return false
    }

    // MARK: - Refresh States

    func refreshDownloadStates() {
        for model in AIModel.allModels {
            if isModelDownloaded(model) {
                downloadStates[model.id] = .downloaded
            } else if downloadingModelId == model.id {
                // Download was in progress
                downloadStates[model.id] = .downloading(progress: downloadProgress)
            } else {
                downloadStates[model.id] = .notDownloaded
            }
        }
    }

    // MARK: - Download Model

    func downloadModel(_ model: AIModel) async throws {
        guard !isDownloading else {
            throw ModelManagerError.downloadInProgress
        }

        guard !isModelDownloaded(model) else {
            downloadStates[model.id] = .downloaded
            return
        }

        if model.backend == .mlx {
            // MLX models are downloaded automatically by VLMModelFactory on first use
            // Mark as ready - actual download happens when model is loaded
            downloadStates[model.id] = .downloaded
            print("[ModelManager] MLX model '\(model.name)' will download automatically on first use")
            return
        } else {
            try await downloadGGUFModel(model)
        }
    }

    // Download GGUF model (single file) - uses background session
    private func downloadGGUFModel(_ model: AIModel) async throws {
        isDownloading = true
        downloadingModelId = model.id
        downloadProgress = 0
        downloadedBytes = 0
        totalBytes = model.sizeBytes
        downloadStates[model.id] = .downloading(progress: 0)
        currentModel = model

        UserDefaults.standard.set(model.id, forKey: "downloadingModelId")

        let destinationURL = modelPath(for: model)
        currentDestinationURL = destinationURL

        try? FileManager.default.removeItem(at: destinationURL)

        return try await withCheckedThrowingContinuation { continuation in
            self.downloadContinuation = continuation
            let task = backgroundSession.downloadTask(with: model.downloadURL)
            self.downloadTask = task
            task.resume()
            print("[ModelManager] Started background download for \(model.name)")
        }
    }

    // Called by delegate when progress updates
    nonisolated func updateProgress(bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpected: Int64) {
        Task { @MainActor in
            self.downloadedBytes = totalBytesWritten
            if totalBytesExpected > 0 {
                self.totalBytes = totalBytesExpected
                self.downloadProgress = Double(totalBytesWritten) / Double(totalBytesExpected)
            } else if let model = self.currentModel {
                self.downloadProgress = Double(totalBytesWritten) / Double(model.sizeBytes)
            }
            if let modelId = self.downloadingModelId {
                self.downloadStates[modelId] = .downloading(progress: self.downloadProgress)
            }
        }
    }

    // Called by delegate when download completes
    nonisolated func downloadCompleted(location: URL) {
        Task { @MainActor in
            guard let destinationURL = self.currentDestinationURL else {
                // Try to determine destination from downloading model
                guard let modelId = self.downloadingModelId,
                      let model = AIModel.model(withId: modelId) else {
                    self.downloadContinuation?.resume(throwing: ModelManagerError.downloadFailed("No destination set"))
                    self.cleanupDownload()
                    return
                }
                let destURL = self.modelPath(for: model)
                self.finishDownload(from: location, to: destURL, model: model)
                return
            }

            let model = self.currentModel ?? AIModel.allModels.first { self.modelPath(for: $0) == destinationURL }
            guard let model = model else {
                self.downloadContinuation?.resume(throwing: ModelManagerError.downloadFailed("Model not found"))
                self.cleanupDownload()
                return
            }

            self.finishDownload(from: location, to: destinationURL, model: model)
        }
    }

    private func finishDownload(from location: URL, to destinationURL: URL, model: AIModel) {
        do {
            // Remove existing file if any
            try? FileManager.default.removeItem(at: destinationURL)

            // Move to destination
            try FileManager.default.moveItem(at: location, to: destinationURL)

            // Verify file size
            if let attributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
               let fileSize = attributes[.size] as? Int64,
               fileSize < model.sizeBytes / 2 {
                try? FileManager.default.removeItem(at: destinationURL)
                self.downloadStates[model.id] = .failed("Download incomplete")
                self.downloadContinuation?.resume(throwing: ModelManagerError.downloadFailed("Download incomplete - file too small"))
                self.cleanupDownload()
                return
            }

            // Verify file is readable before declaring success
            // This ensures filesystem has fully synced the file
            guard self.verifyFileReadable(at: destinationURL) else {
                print("[ModelManager] File verification failed after move")
                try? FileManager.default.removeItem(at: destinationURL)
                self.downloadStates[model.id] = .failed("File verification failed")
                self.downloadContinuation?.resume(throwing: ModelManagerError.downloadFailed("File verification failed after download"))
                self.cleanupDownload()
                return
            }

            print("[ModelManager] Download completed successfully: \(model.name)")
            self.downloadStates[model.id] = .downloaded
            self.downloadProgress = 1.0
            self.downloadContinuation?.resume()
            self.cleanupDownload()

        } catch {
            print("[ModelManager] Error moving download: \(error)")
            try? FileManager.default.removeItem(at: destinationURL)
            self.downloadStates[model.id] = .failed(error.localizedDescription)
            self.downloadContinuation?.resume(throwing: error)
            self.cleanupDownload()
        }
    }

    /// Verify that a file is readable by attempting to read its header
    /// This ensures the filesystem has fully synced the file after a move operation
    private func verifyFileReadable(at url: URL) -> Bool {
        do {
            // Open file for reading to verify it's accessible
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            // Read first 4KB to verify file is readable (GGUF header check)
            let headerData = try handle.read(upToCount: 4096)
            guard let data = headerData, data.count >= 4 else {
                print("[ModelManager] File header too small or unreadable")
                return false
            }

            // Check GGUF magic number: "GGUF" = 0x46554747
            let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            if magic != 0x46554747 {
                print("[ModelManager] Invalid GGUF magic number: \(String(format: "0x%08X", magic))")
                return false
            }

            print("[ModelManager] File verification passed - valid GGUF file")
            return true
        } catch {
            print("[ModelManager] File verification error: \(error)")
            return false
        }
    }

    // Called by delegate when download fails
    nonisolated func downloadFailed(error: Error) {
        Task { @MainActor in
            print("[ModelManager] Download failed: \(error.localizedDescription)")
            if let destinationURL = self.currentDestinationURL {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            if let modelId = self.downloadingModelId {
                self.downloadStates[modelId] = .failed(error.localizedDescription)
            }
            self.downloadContinuation?.resume(throwing: error)
            self.cleanupDownload()
        }
    }

    // Called when background events are completed
    nonisolated func backgroundSessionDidComplete() {
        Task { @MainActor in
            print("[ModelManager] Background session events completed")
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    private func cleanupDownload() {
        isDownloading = false
        downloadingModelId = nil
        downloadTask = nil
        downloadContinuation = nil
        currentDestinationURL = nil
        currentModel = nil

        // Clear saved downloading state
        UserDefaults.standard.removeObject(forKey: "downloadingModelId")
    }

    // MARK: - Cancel Download

    func cancelDownload() {
        downloadTask?.cancel()
        if let modelId = downloadingModelId {
            downloadStates[modelId] = .notDownloaded
        }
        downloadContinuation?.resume(throwing: CancellationError())
        cleanupDownload()
        downloadProgress = 0
        downloadedBytes = 0
    }

    // MARK: - Delete Model

    func deleteModel(_ model: AIModel) throws {
        let path = modelPath(for: model)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
        downloadStates[model.id] = .notDownloaded

        // If deleting current model, switch to default
        if currentModelId == model.id {
            if let defaultModel = AIModel.allModels.first(where: { isModelDownloaded($0) }) {
                selectModel(defaultModel)
            }
        }
    }

    // Delete all downloaded models
    func clearAllModels() {
        for model in AIModel.allModels {
            let path = modelPath(for: model)
            try? FileManager.default.removeItem(at: path)
            downloadStates[model.id] = .notDownloaded
        }
    }

    // Force delete a specific model file (even if it appears valid)
    func forceDeleteModel(_ model: AIModel) {
        let path = modelPath(for: model)
        try? FileManager.default.removeItem(at: path)
        downloadStates[model.id] = .notDownloaded
    }

    // MARK: - Select Model

    func selectModel(_ model: AIModel) {
        guard isModelDownloaded(model) else { return }
        currentModelId = model.id
        UserDefaults.standard.set(model.id, forKey: "selectedModelId")
    }

    var activeModel: AIModel {
        AIModel.model(withId: currentModelId) ?? AIModel.defaultModel
    }

    // MARK: - Storage Info

    var totalDownloadedSize: Int64 {
        AIModel.allModels.reduce(0) { total, model in
            if isModelDownloaded(model) {
                return total + model.sizeBytes
            }
            return total
        }
    }

    var formattedTotalSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalDownloadedSize)
    }

    var formattedDownloadedBytes: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: downloadedBytes)
    }

    var formattedTotalBytes: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalBytes)
    }
}

// MARK: - Background Download Session Delegate

private class BackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var manager: ModelManager?

    init(manager: ModelManager) {
        self.manager = manager
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        manager?.updateProgress(bytesWritten: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpected: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Copy to a temp location we control since the original will be deleted
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        do {
            try FileManager.default.copyItem(at: location, to: tempURL)
            manager?.downloadCompleted(location: tempURL)
        } catch {
            print("[ModelManager] Error copying downloaded file: \(error)")
            manager?.downloadFailed(error: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            // Check if this is a cancellation
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                print("[ModelManager] Download was cancelled")
            } else {
                manager?.downloadFailed(error: error)
            }
        }
    }

    // Called when all background events have been delivered
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        manager?.backgroundSessionDidComplete()
    }
}

// MARK: - Errors

enum ModelManagerError: LocalizedError {
    case downloadInProgress
    case downloadFailed(String)
    case modelNotFound

    var errorDescription: String? {
        switch self {
        case .downloadInProgress:
            return "A download is already in progress"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .modelNotFound:
            return "Model not found"
        }
    }
}
