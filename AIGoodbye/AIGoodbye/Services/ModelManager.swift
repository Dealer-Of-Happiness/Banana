//
//  ModelManager.swift
//  AIGoodbye
//
//  Manages AI model downloads and storage
//

import Foundation
import Combine

@MainActor
class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published var downloadStates: [String: ModelDownloadState] = [:]
    @Published var currentModelId: String = "ministral-8b"
    @Published var downloadProgress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var isDownloading = false
    @Published var downloadingModelId: String?

    private let modelsDirectory: URL
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadContinuation: CheckedContinuation<Void, Error>?
    private var currentDestinationURL: URL?
    private var currentModel: AIModel?

    private init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        modelsDirectory = documentsPath.appendingPathComponent("models")

        // Create models directory if needed
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        // Load saved model preference
        if let savedModelId = UserDefaults.standard.string(forKey: "selectedModelId") {
            currentModelId = savedModelId
        }

        // Initialize download states
        refreshDownloadStates()
    }

    // MARK: - Model Path

    func modelPath(for model: AIModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    func isModelDownloaded(_ model: AIModel) -> Bool {
        let path = modelPath(for: model)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return false
        }

        // Also check file size to detect incomplete downloads
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
           let fileSize = attributes[.size] as? Int64 {
            // File should be at least 50% of expected size
            let minimumSize = model.sizeBytes / 2
            return fileSize >= minimumSize
        }

        return false
    }

    // MARK: - Refresh States

    func refreshDownloadStates() {
        for model in AIModel.allModels {
            if isModelDownloaded(model) {
                downloadStates[model.id] = .downloaded
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

        isDownloading = true
        downloadingModelId = model.id
        downloadProgress = 0
        downloadedBytes = 0
        totalBytes = model.sizeBytes
        downloadStates[model.id] = .downloading(progress: 0)
        currentModel = model

        let destinationURL = modelPath(for: model)
        currentDestinationURL = destinationURL

        // Delete any existing partial file
        try? FileManager.default.removeItem(at: destinationURL)

        // Create delegate and session
        let delegate = DownloadSessionDelegate(manager: self)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600 // 1 hour for large files
        downloadSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        return try await withCheckedThrowingContinuation { continuation in
            self.downloadContinuation = continuation
            let task = downloadSession!.downloadTask(with: model.downloadURL)
            self.downloadTask = task
            task.resume()
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
            guard let destinationURL = self.currentDestinationURL,
                  let model = self.currentModel else {
                self.downloadContinuation?.resume(throwing: ModelManagerError.downloadFailed("No destination set"))
                self.cleanupDownload()
                return
            }

            do {
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

                self.downloadStates[model.id] = .downloaded
                self.downloadProgress = 1.0
                self.downloadContinuation?.resume()
                self.cleanupDownload()

            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                self.downloadStates[model.id] = .failed(error.localizedDescription)
                self.downloadContinuation?.resume(throwing: error)
                self.cleanupDownload()
            }
        }
    }

    // Called by delegate when download fails
    nonisolated func downloadFailed(error: Error) {
        Task { @MainActor in
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

    private func cleanupDownload() {
        isDownloading = false
        downloadingModelId = nil
        downloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        downloadContinuation = nil
        currentDestinationURL = nil
        currentModel = nil
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

// MARK: - Download Session Delegate

private class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
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
        try? FileManager.default.copyItem(at: location, to: tempURL)
        manager?.downloadCompleted(location: tempURL)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            manager?.downloadFailed(error: error)
        }
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
