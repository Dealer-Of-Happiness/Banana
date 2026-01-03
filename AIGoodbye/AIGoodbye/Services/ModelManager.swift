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
    @Published var currentModelId: String = "tinyllama"
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var downloadingModelId: String?

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

        let destinationURL = modelPath(for: model)

        // Delete any existing partial file
        try? FileManager.default.removeItem(at: destinationURL)

        do {
            // Use simple async download - reliable and fast
            let (tempURL, response) = try await URLSession.shared.download(from: model.downloadURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw ModelManagerError.downloadFailed("Server error: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }

            // Move to destination
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)

            // Verify file size
            if let attributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
               let fileSize = attributes[.size] as? Int64,
               fileSize < model.sizeBytes / 2 {
                try? FileManager.default.removeItem(at: destinationURL)
                throw ModelManagerError.downloadFailed("Download incomplete - file too small")
            }

            downloadStates[model.id] = .downloaded
            isDownloading = false
            downloadingModelId = nil
            downloadProgress = 1.0

        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            downloadStates[model.id] = .failed(error.localizedDescription)
            isDownloading = false
            downloadingModelId = nil
            throw error
        }
    }

    // MARK: - Cancel Download

    func cancelDownload() {
        // Note: Can't cancel URLSession.shared.download() easily
        // Just reset state
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
