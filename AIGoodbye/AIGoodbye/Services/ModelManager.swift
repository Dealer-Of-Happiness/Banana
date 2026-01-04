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
    private var downloadDelegate: DownloadDelegate?
    private var downloadTask: URLSessionDownloadTask?

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

        let destinationURL = modelPath(for: model)

        // Delete any existing partial file
        try? FileManager.default.removeItem(at: destinationURL)

        // Create download delegate for progress tracking
        downloadDelegate = DownloadDelegate { [weak self] bytesWritten, totalBytesWritten, totalBytesExpected in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.downloadedBytes = totalBytesWritten
                if totalBytesExpected > 0 {
                    self.totalBytes = totalBytesExpected
                    self.downloadProgress = Double(totalBytesWritten) / Double(totalBytesExpected)
                } else {
                    // Use model's expected size if server doesn't provide content-length
                    self.downloadProgress = Double(totalBytesWritten) / Double(model.sizeBytes)
                }
                self.downloadStates[model.id] = .downloading(progress: self.downloadProgress)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = URLSession(configuration: .default, delegate: downloadDelegate, delegateQueue: nil)
            let task = session.downloadTask(with: model.downloadURL) { [weak self] tempURL, response, error in
                Task { @MainActor [weak self] in
                    guard let self = self else {
                        continuation.resume(throwing: ModelManagerError.downloadFailed("Manager deallocated"))
                        return
                    }

                    if let error = error {
                        try? FileManager.default.removeItem(at: destinationURL)
                        self.downloadStates[model.id] = .failed(error.localizedDescription)
                        self.isDownloading = false
                        self.downloadingModelId = nil
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                        self.downloadStates[model.id] = .failed("Server error: \(statusCode)")
                        self.isDownloading = false
                        self.downloadingModelId = nil
                        continuation.resume(throwing: ModelManagerError.downloadFailed("Server error: \(statusCode)"))
                        return
                    }

                    guard let tempURL = tempURL else {
                        self.downloadStates[model.id] = .failed("No file received")
                        self.isDownloading = false
                        self.downloadingModelId = nil
                        continuation.resume(throwing: ModelManagerError.downloadFailed("No file received"))
                        return
                    }

                    do {
                        // Move to destination
                        try FileManager.default.moveItem(at: tempURL, to: destinationURL)

                        // Verify file size
                        if let attributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
                           let fileSize = attributes[.size] as? Int64,
                           fileSize < model.sizeBytes / 2 {
                            try? FileManager.default.removeItem(at: destinationURL)
                            self.downloadStates[model.id] = .failed("Download incomplete")
                            self.isDownloading = false
                            self.downloadingModelId = nil
                            continuation.resume(throwing: ModelManagerError.downloadFailed("Download incomplete - file too small"))
                            return
                        }

                        self.downloadStates[model.id] = .downloaded
                        self.isDownloading = false
                        self.downloadingModelId = nil
                        self.downloadProgress = 1.0
                        continuation.resume()

                    } catch {
                        try? FileManager.default.removeItem(at: destinationURL)
                        self.downloadStates[model.id] = .failed(error.localizedDescription)
                        self.isDownloading = false
                        self.downloadingModelId = nil
                        continuation.resume(throwing: error)
                    }
                }
            }

            self.downloadTask = task
            task.resume()
        }
    }

    // MARK: - Cancel Download

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadDelegate = nil

        if let modelId = downloadingModelId {
            downloadStates[modelId] = .notDownloaded
        }

        isDownloading = false
        downloadingModelId = nil
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

    var currentModel: AIModel {
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

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Int64, Int64, Int64) -> Void

    init(progressHandler: @escaping (Int64, Int64, Int64) -> Void) {
        self.progressHandler = progressHandler
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled in completion handler
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
