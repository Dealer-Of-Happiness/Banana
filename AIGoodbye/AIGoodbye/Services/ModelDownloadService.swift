//
//  ModelDownloadService.swift
//  AIGoodbye
//
//  Custom background download service for HuggingFace MLX models
//  Uses background URLSession with resume support for reliable downloads
//

import Foundation
import Combine

/// Custom download service for MLX models that provides:
/// - Background URLSession (survives app switching)
/// - Resume support for interrupted downloads
/// - Better progress reporting
/// - Faster download speeds
@MainActor
class ModelDownloadService: NSObject, ObservableObject {
    static let shared = ModelDownloadService()

    // Background session identifier
    static let backgroundSessionIdentifier = "com.aigoodbye.mlxmodeldownload"

    // Published state
    @Published var downloadProgress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var isDownloading = false
    @Published var downloadSpeed: String = ""
    @Published var currentModelId: String?
    @Published var downloadError: String?

    // Download state
    private var backgroundSession: URLSession!
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    private var downloadContinuations: [String: CheckedContinuation<URL, Error>] = [:]
    private var lastProgressUpdate: Date = Date()
    private var lastBytesWritten: Int64 = 0

    // HuggingFace model files to download
    private let requiredFiles = [
        "config.json",
        "model.safetensors",
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "preprocessor_config.json"  // For VLM models
    ]

    // Background completion handler from AppDelegate
    var backgroundCompletionHandler: (() -> Void)?

    override private init() {
        super.init()
        setupBackgroundSession()
        loadResumeData()
    }

    private func setupBackgroundSession() {
        let config = URLSessionConfiguration.background(withIdentifier: ModelDownloadService.backgroundSessionIdentifier)
        config.sessionSendsLaunchEvents = true  // Wake app when download completes
        config.isDiscretionary = false  // Don't delay downloads
        config.timeoutIntervalForRequest = 300  // 5 minutes
        config.timeoutIntervalForResource = 14400  // 4 hours for large models
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 4  // Allow parallel downloads

        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public API

    /// Download a model from HuggingFace to local cache
    /// Returns the local directory URL where the model was downloaded
    func downloadModel(huggingFaceId: String, modelId: String) async throws -> URL {
        guard !isDownloading else {
            throw DownloadError.downloadInProgress
        }

        isDownloading = true
        currentModelId = modelId
        downloadProgress = 0
        downloadedBytes = 0
        downloadError = nil

        let cacheDir = getModelCacheDirectory(for: huggingFaceId)

        // Create cache directory
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Download each required file
        for fileName in requiredFiles {
            let fileURL = cacheDir.appendingPathComponent(fileName)

            // Skip if file already exists and is complete
            if FileManager.default.fileExists(atPath: fileURL.path) {
                print("[ModelDownload] File already exists: \(fileName)")
                continue
            }

            // Build HuggingFace URL
            let downloadURL = URL(string: "https://huggingface.co/\(huggingFaceId)/resolve/main/\(fileName)")!

            do {
                let localURL = try await downloadFile(from: downloadURL, to: fileURL, fileName: fileName)
                print("[ModelDownload] Downloaded: \(localURL.lastPathComponent)")
            } catch {
                // Some files are optional (like preprocessor_config.json for non-VLM models)
                if fileName == "preprocessor_config.json" {
                    print("[ModelDownload] Optional file not found: \(fileName)")
                    continue
                }
                throw error
            }
        }

        isDownloading = false
        currentModelId = nil
        downloadProgress = 1.0

        return cacheDir
    }

    /// Get the local cache directory for a model
    func getModelCacheDirectory(for huggingFaceId: String) -> URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let sanitizedId = huggingFaceId.replacingOccurrences(of: "/", with: "--")
        return cacheDir.appendingPathComponent("huggingface/hub/models--\(sanitizedId)/snapshots/main")
    }

    /// Check if a model is already downloaded
    func isModelDownloaded(huggingFaceId: String) -> Bool {
        let cacheDir = getModelCacheDirectory(for: huggingFaceId)
        let configFile = cacheDir.appendingPathComponent("config.json")
        let modelFile = cacheDir.appendingPathComponent("model.safetensors")

        return FileManager.default.fileExists(atPath: configFile.path) &&
               FileManager.default.fileExists(atPath: modelFile.path)
    }

    /// Cancel current download
    func cancelDownload() {
        // Capture modelId before closure to avoid actor isolation issues
        let modelIdToSave = currentModelId

        for (_, task) in downloadTasks {
            task.cancel { [weak self] resumeData in
                if let data = resumeData, let modelId = modelIdToSave {
                    Task { @MainActor in
                        self?.saveResumeData(data, for: modelId)
                    }
                }
            }
        }
        downloadTasks.removeAll()
        isDownloading = false
        currentModelId = nil
    }

    /// Delete downloaded model
    func deleteModel(huggingFaceId: String) throws {
        let cacheDir = getModelCacheDirectory(for: huggingFaceId)
        if FileManager.default.fileExists(atPath: cacheDir.path) {
            try FileManager.default.removeItem(at: cacheDir)
        }
    }

    // MARK: - Private Methods

    private func downloadFile(from remoteURL: URL, to localURL: URL, fileName: String) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            var request = URLRequest(url: remoteURL)
            request.httpMethod = "GET"

            let task = backgroundSession.downloadTask(with: request)
            let taskId = "\(currentModelId ?? "unknown")_\(fileName)"
            downloadTasks[taskId] = task
            downloadContinuations[taskId] = continuation

            // Store destination URL for later
            UserDefaults.standard.set(localURL.path, forKey: "download_dest_\(task.taskIdentifier)")

            task.resume()
            print("[ModelDownload] Started downloading: \(fileName) from \(remoteURL)")
        }
    }

    private func saveResumeData(_ data: Data, for modelId: String) {
        resumeData[modelId] = data
        let key = "resume_\(modelId)"
        UserDefaults.standard.set(data, forKey: key)
    }

    private func loadResumeData() {
        // Load any saved resume data
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("resume_") {
            if let data = defaults.data(forKey: key) {
                let modelId = String(key.dropFirst(7))  // Remove "resume_" prefix
                resumeData[modelId] = data
            }
        }
    }

    private func clearResumeData(for modelId: String) {
        resumeData.removeValue(forKey: modelId)
        UserDefaults.standard.removeObject(forKey: "resume_\(modelId)")
    }

    // Format bytes for display
    var formattedDownloadedBytes: String {
        ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    var formattedTotalBytes: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

// MARK: - URLSession Delegate

extension ModelDownloadService: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.downloadedBytes = totalBytesWritten

            if totalBytesExpectedToWrite > 0 {
                self.totalBytes = totalBytesExpectedToWrite
                self.downloadProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }

            // Calculate download speed
            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastProgressUpdate)
            if elapsed >= 1.0 {
                let bytesPerSecond = Double(totalBytesWritten - self.lastBytesWritten) / elapsed
                self.downloadSpeed = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
                self.lastProgressUpdate = now
                self.lastBytesWritten = totalBytesWritten
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Get the destination URL
        let destPath = UserDefaults.standard.string(forKey: "download_dest_\(downloadTask.taskIdentifier)")

        Task { @MainActor in
            guard let destPath = destPath else {
                print("[ModelDownload] No destination path found for task")
                return
            }

            let destURL = URL(fileURLWithPath: destPath)

            do {
                // Create parent directory if it doesn't exist
                let parentDir = destURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                // Remove existing file if any
                try? FileManager.default.removeItem(at: destURL)

                // Move downloaded file to destination
                try FileManager.default.moveItem(at: location, to: destURL)

                // Find and resume continuation
                for (taskId, task) in self.downloadTasks where task.taskIdentifier == downloadTask.taskIdentifier {
                    if let continuation = self.downloadContinuations.removeValue(forKey: taskId) {
                        continuation.resume(returning: destURL)
                    }
                    self.downloadTasks.removeValue(forKey: taskId)
                    break
                }

                // Cleanup
                UserDefaults.standard.removeObject(forKey: "download_dest_\(downloadTask.taskIdentifier)")

            } catch {
                print("[ModelDownload] Error moving file: \(error)")
                for (taskId, task) in self.downloadTasks where task.taskIdentifier == downloadTask.taskIdentifier {
                    if let continuation = self.downloadContinuations.removeValue(forKey: taskId) {
                        continuation.resume(throwing: error)
                    }
                    self.downloadTasks.removeValue(forKey: taskId)
                    break
                }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }

        Task { @MainActor in
            // Check for cancellation with resume data
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                   let modelId = self.currentModelId {
                    self.saveResumeData(resumeData, for: modelId)
                    print("[ModelDownload] Download cancelled, resume data saved")
                }
            } else {
                self.downloadError = error.localizedDescription
                print("[ModelDownload] Download error: \(error.localizedDescription)")
            }

            // Resume any waiting continuations with error
            for (taskId, downloadTask) in self.downloadTasks where downloadTask.taskIdentifier == task.taskIdentifier {
                if let continuation = self.downloadContinuations.removeValue(forKey: taskId) {
                    continuation.resume(throwing: error)
                }
                self.downloadTasks.removeValue(forKey: taskId)
                break
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            print("[ModelDownload] Background session events completed")
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}

// MARK: - Errors

enum DownloadError: LocalizedError {
    case downloadInProgress
    case networkError(String)
    case fileNotFound(String)
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case .downloadInProgress:
            return "A download is already in progress"
        case .networkError(let message):
            return "Network error: \(message)"
        case .fileNotFound(let file):
            return "File not found: \(file)"
        case .insufficientStorage:
            return "Not enough storage space"
        }
    }
}
