//
//  ModelManager.swift
//  AIGoodbye
//
//  Manages AI model downloads and storage
//

import Foundation
import Combine

// Download delegate for progress tracking
class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var onComplete: ((URL) -> Void)?
    var onError: ((Error) -> Void)?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        DispatchQueue.main.async {
            self.onProgress?(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        onComplete?(location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.onError?(error)
            }
        }
    }
}

@MainActor
class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published var downloadStates: [String: ModelDownloadState] = [:]
    @Published var currentModelId: String = "tinyllama"
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var downloadingModelId: String?

    private var downloadTask: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    private let modelsDirectory: URL

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

    private var downloadDelegate: DownloadDelegate?
    private var activeSession: URLSession?

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
        downloadStates[model.id] = .downloading(progress: 0)

        let destinationURL = modelPath(for: model)

        // Delete any existing partial file
        try? FileManager.default.removeItem(at: destinationURL)

        // Use continuation to bridge delegate-based API with async/await
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate()
            self.downloadDelegate = delegate

            delegate.onProgress = { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                    self?.downloadStates[model.id] = .downloading(progress: progress)
                }
            }

            var didComplete = false

            delegate.onComplete = { [weak self] tempURL in
                guard !didComplete else { return }
                didComplete = true

                do {
                    // Move to destination
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)

                    // Verify file size
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
                       let fileSize = attributes[.size] as? Int64,
                       fileSize < model.sizeBytes / 2 {
                        try? FileManager.default.removeItem(at: destinationURL)
                        continuation.resume(throwing: ModelManagerError.downloadFailed("Download incomplete"))
                        return
                    }

                    Task { @MainActor in
                        self?.downloadStates[model.id] = .downloaded
                        self?.isDownloading = false
                        self?.downloadingModelId = nil
                        self?.downloadProgress = 1.0
                    }
                    continuation.resume()
                } catch {
                    Task { @MainActor in
                        self?.downloadStates[model.id] = .failed(error.localizedDescription)
                        self?.isDownloading = false
                        self?.downloadingModelId = nil
                    }
                    continuation.resume(throwing: error)
                }
            }

            delegate.onError = { [weak self] error in
                guard !didComplete else { return }
                didComplete = true

                Task { @MainActor in
                    self?.downloadStates[model.id] = .failed(error.localizedDescription)
                    self?.isDownloading = false
                    self?.downloadingModelId = nil
                }
                continuation.resume(throwing: error)
            }

            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 7200 // 2 hours for large files

            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
            self.activeSession = session

            let task = session.downloadTask(with: model.downloadURL)
            self.downloadTask = task
            task.resume()
        }
    }

    // MARK: - Cancel Download

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        activeSession?.invalidateAndCancel()
        activeSession = nil
        downloadDelegate = nil
        observation?.invalidate()
        observation = nil

        if let modelId = downloadingModelId {
            downloadStates[modelId] = .notDownloaded
        }

        isDownloading = false
        downloadingModelId = nil
        downloadProgress = 0
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
