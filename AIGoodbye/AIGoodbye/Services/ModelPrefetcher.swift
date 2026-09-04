//
//  ModelPrefetcher.swift
//  AIGoodbye
//
//  Fast, byte-accurate model downloads.
//
//  Downloads a model's files from the Hugging Face CDN using
//  URLSessionDownloadTask (native, line-rate networking with real progress),
//  placing them in the exact layout the MLX/Hub libraries expect - including
//  the per-file metadata sidecars - so the library's loader finds everything
//  already on disk and skips its own (much slower) downloader.
//
//  If anything here fails, MLXService falls back to the library's built-in
//  downloader, so this is a pure fast-path: correctness never depends on it.
//

import Foundation

enum PrefetchError: Error {
    case listingFailed
    case noFiles
    case downloadFailed
}

final class ModelPrefetcher {

    /// Downloads all *.safetensors and *.json files for the repo into `repoDir`.
    /// `progress` is called with (downloadedBytes, totalBytes) from a background
    /// queue; throttle/hop as needed on the receiving side.
    func prefetch(
        hfId: String,
        into repoDir: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        // 1. Repo info: latest commit hash (for metadata sidecars).
        let infoURL = URL(string: "https://huggingface.co/api/models/\(hfId)")!
        let commitHash: String?
        do {
            let (data, response) = try await URLSession.shared.data(from: infoURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw PrefetchError.listingFailed
            }
            let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            commitHash = info?["sha"] as? String
        }

        // 2. File listing with sizes.
        let treeURL = URL(string: "https://huggingface.co/api/models/\(hfId)/tree/main?recursive=true")!
        let (treeData, treeResponse) = try await URLSession.shared.data(from: treeURL)
        guard (treeResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw PrefetchError.listingFailed
        }
        let allEntries = try JSONDecoder().decode([RepoFile].self, from: treeData)
        let files = allEntries.filter { entry in
            entry.type == "file"
                && (entry.path.hasSuffix(".safetensors") || entry.path.hasSuffix(".json"))
        }
        guard !files.isEmpty else { throw PrefetchError.noFiles }

        let totalBytes = files.reduce(Int64(0)) { $0 + $1.actualSize }
        var completedBytes: Int64 = 0
        progress(0, totalBytes)

        let metaDir = repoDir
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("download", isDirectory: true)

        // 3. Download files sequentially (the big weights file dominates anyway).
        for file in files {
            try Task.checkCancellation()

            let destination = repoDir.appendingPathComponent(file.path)
            let metaPath = metaDir.appendingPathComponent(file.path + ".metadata")
            let size = file.actualSize

            // Already fully downloaded with metadata? Count it and move on.
            if let existing = try? FileManager.default.attributesOfItem(atPath: destination.path),
               (existing[.size] as? Int64) == size, size > 0,
               FileManager.default.fileExists(atPath: metaPath.path) {
                completedBytes += size
                progress(completedBytes, totalBytes)
                continue
            }

            let sourceURL = URL(string: "https://huggingface.co/\(hfId)/resolve/main/\(file.path)")!
            let base = completedBytes
            var attempt = 0
            while true {
                do {
                    let download = FileDownload(destination: destination) { bytesSoFar in
                        progress(base + bytesSoFar, totalBytes)
                    }
                    try await download.run(url: sourceURL, timeout: 30)
                    break
                } catch {
                    try Task.checkCancellation()
                    attempt += 1
                    if attempt > 2 { throw error }
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }

            // Metadata sidecar so the library's loader (and its offline mode)
            // recognizes the file as a valid, verified download.
            let etag = file.lfs?.oid ?? file.oid ?? ""
            if let commitHash, !etag.isEmpty {
                try? FileManager.default.createDirectory(
                    at: metaPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let contents = "\(commitHash)\n\(etag)\n\(Date().timeIntervalSince1970)\n"
                try? contents.write(to: metaPath, atomically: true, encoding: .utf8)
            }

            // Clear any stale partial download the library may have left behind.
            let incompleteDir = metaPath.deletingLastPathComponent()
            if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: incompleteDir.path) {
                for name in leftovers where name.hasPrefix(file.path + ".") && name.hasSuffix(".incomplete") {
                    try? FileManager.default.removeItem(at: incompleteDir.appendingPathComponent(name))
                }
            }

            completedBytes += size
            progress(completedBytes, totalBytes)
        }
    }

    // MARK: - Repo listing model

    private struct RepoFile: Decodable {
        let type: String
        let path: String
        let size: Int64?
        let oid: String?
        let lfs: LFSInfo?

        struct LFSInfo: Decodable {
            let oid: String?
            let size: Int64?
        }

        /// Real byte size (LFS entries report the pointer size in `size`).
        var actualSize: Int64 {
            lfs?.size ?? size ?? 0
        }
    }
}

// MARK: - Single-file download with byte progress

/// Downloads one file with URLSessionDownloadTask, reporting byte progress.
/// One instance per file; the session is torn down when the transfer ends.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onBytes: @Sendable (Int64) -> Void

    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var moveError: Error?
    private var lastReport = Date.distantPast

    init(destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.onBytes = onBytes
    }

    func run(url: URL, timeout: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont

                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = timeout

                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1

                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                self.session = session
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session?.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Throttle UI updates to ~4 per second.
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.25 {
            lastReport = now
            onBytes(totalBytesWritten)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode,
               !(200..<300).contains(status) {
                throw PrefetchError.downloadFailed
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let cont = continuation
        continuation = nil
        session.finishTasksAndInvalidate()

        if let error {
            cont?.resume(throwing: error)
        } else if let moveError {
            cont?.resume(throwing: moveError)
        } else {
            cont?.resume(returning: ())
        }
    }
}
