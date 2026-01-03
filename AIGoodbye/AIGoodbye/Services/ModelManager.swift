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
    @Published var currentModelId: String = "llama-3.2-1b"
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

        do {
            let destinationURL = modelPath(for: model)

            // Use URLSession for download with progress
            let (asyncBytes, response) = try await URLSession.shared.bytes(from: model.downloadURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw ModelManagerError.downloadFailed("Server returned error")
            }

            let totalBytes = response.expectedContentLength

            // Create file and write
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destinationURL)

            var downloadedBytes: Int64 = 0
            var buffer = Data()
            let bufferSize = 1024 * 1024 // 1MB buffer

            for try await byte in asyncBytes {
                buffer.append(byte)
                downloadedBytes += 1

                if buffer.count >= bufferSize {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)

                    // Update progress
                    let progress = totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0
                    await MainActor.run {
                        self.downloadProgress = progress
                        self.downloadStates[model.id] = .downloading(progress: progress)
                    }
                }
            }

            // Write remaining buffer
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }

            try handle.close()

            await MainActor.run {
                self.downloadStates[model.id] = .downloaded
                self.isDownloading = false
                self.downloadingModelId = nil
                self.downloadProgress = 1.0
            }

        } catch {
            await MainActor.run {
                self.downloadStates[model.id] = .failed(error.localizedDescription)
                self.isDownloading = false
                self.downloadingModelId = nil
            }
            throw error
        }
    }

    // MARK: - Cancel Download

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
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
