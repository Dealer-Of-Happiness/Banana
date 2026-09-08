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
//  Failed transfers retry with URLSession resume data, so a network blip at
//  90% of a 5.8 GB file continues instead of starting over.
//
//  If anything here fails, MLXService falls back to the library's built-in
//  downloader, so this is a pure fast-path: correctness never depends on it.
//

import CryptoKit
import Foundation

enum PrefetchError: Error {
    case listingFailed
    case noFiles
    case downloadFailed
    case sizeMismatch
}

final class ModelPrefetcher {

    /// Downloads all *.safetensors and *.json files for the repo into `repoDir`.
    /// `progress` is called with (downloadedBytes, totalBytes) from a background
    /// queue; throttle/hop as needed on the receiving side.
    /// When true, downloads are refused on cellular (models are 1-6 GB).
    var wifiOnly: Bool = true

    func prefetch(
        hfId: String,
        into repoDir: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        // 1. Repo info: latest commit hash (nicety for metadata sidecars —
        // a failure here must not forfeit the fast path).
        var commitHash: String?
        if let infoURL = URL(string: "https://huggingface.co/api/models/\(hfId)"),
           let (data, response) = try? await URLSession.shared.data(from: infoURL),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            commitHash = info["sha"] as? String
        }

        // 2. File listing with sizes.
        guard let treeURL = URL(string: "https://huggingface.co/api/models/\(hfId)/tree/main?recursive=true") else {
            throw PrefetchError.listingFailed
        }
        let (treeData, treeResponse) = try await URLSession.shared.data(from: treeURL)
        guard (treeResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw PrefetchError.listingFailed
        }
        let allEntries = try JSONDecoder().decode([RepoFile].self, from: treeData)
        // `.jinja` too: newer repositories ship the chat template as a
        // standalone file that the library prefers over the JSON copy, and
        // a purely local load can only use what is on disk.
        let files = allEntries.filter { entry in
            entry.type == "file"
                && (entry.path.hasSuffix(".safetensors")
                    || entry.path.hasSuffix(".json")
                    || entry.path.hasSuffix(".jinja"))
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
            let expectedSize = file.actualSize

            // Already fully downloaded (size matches)? Count it and move on.
            if expectedSize > 0,
               let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
               (attrs[.size] as? Int64) == expectedSize {
                writeSidecarIfNeeded(for: file, commitHash: commitHash, metaDir: metaDir)
                completedBytes += expectedSize
                progress(completedBytes, totalBytes)
                continue
            }

            guard let sourceURL = URL(string: "https://huggingface.co/\(hfId)/resolve/main/\(file.path)") else {
                throw PrefetchError.downloadFailed
            }
            let base = completedBytes
            var attempt = 0
            var resumeData: Data?
            while true {
                do {
                    let download = FileDownload(destination: destination, wifiOnly: wifiOnly) { bytesSoFar in
                        progress(base + bytesSoFar, totalBytes)
                    }
                    try await download.run(url: sourceURL, resumeData: resumeData, timeout: 30)

                    // Verify size when known: a truncated weights file would
                    // otherwise surface later as a cryptic load failure.
                    if expectedSize > 0 {
                        let written = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64
                        if written != expectedSize {
                            try? FileManager.default.removeItem(at: destination)
                            throw PrefetchError.sizeMismatch
                        }
                    }
                    break
                } catch {
                    try Task.checkCancellation()
                    // A full disk won't heal with retries.
                    if MLXService.isOutOfSpace(error) { throw error }
                    // Keep partial progress for the next attempt when available.
                    resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                    attempt += 1
                    if attempt > 3 { throw error }
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }

            writeSidecarIfNeeded(for: file, commitHash: commitHash, metaDir: metaDir)

            // Clear any stale partial download the library may have left behind.
            let parent = metaDir.appendingPathComponent(file.path).deletingLastPathComponent()
            if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: parent.path) {
                let fileName = (file.path as NSString).lastPathComponent
                for name in leftovers where name.hasPrefix(fileName + ".") && name.hasSuffix(".incomplete") {
                    try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
                }
            }

            completedBytes += expectedSize
            progress(completedBytes, totalBytes)
        }
    }

    /// Metadata sidecar (commitHash\netag\ntimestamp) so the library's loader
    /// - including its offline mode - recognizes the file as a verified
    /// download. Best-effort: absence only costs a quick re-check online.
    private func writeSidecarIfNeeded(for file: RepoFile, commitHash: String?, metaDir: URL) {
        guard let commitHash else { return }
        let etag = file.lfs?.oid ?? file.oid ?? ""
        guard !etag.isEmpty else { return }
        let metaPath = metaDir.appendingPathComponent(file.path + ".metadata")
        guard !FileManager.default.fileExists(atPath: metaPath.path) else { return }
        try? FileManager.default.createDirectory(
            at: metaPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = "\(commitHash)\n\(etag)\n\(Date().timeIntervalSince1970)\n"
        try? contents.write(to: metaPath, atomically: true, encoding: .utf8)
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
/// All mutable state is lock-protected: the caller's task, the delegate
/// queue, and the cancellation handler all touch it.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let wifiOnly: Bool
    private let onBytes: @Sendable (Int64) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var cancelled = false
    private var moveError: Error?
    private var lastReport = Date.distantPast

    init(destination: URL, wifiOnly: Bool, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.wifiOnly = wifiOnly
        self.onBytes = onBytes
    }

    func run(url: URL, resumeData: Data?, timeout: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // A background session, so a multi-gigabyte model keeps
                // downloading when the user locks the phone or switches apps.
                // With a default session the download simply stops, which is
                // the app's very first experience for most new users.
                // One stable identifier per URL, rather than a fresh UUID
                // per attempt. A background session outlives the app: if
                // the app is killed mid-transfer (memory pressure while it
                // sits suspended behind another app, say), the system keeps
                // downloading. With a random identifier nothing ever
                // reconnected to that transfer, and the next launch started
                // the 1.8 GB weights file again from zero.
                let config = URLSessionConfiguration.background(
                    withIdentifier: Self.sessionIdentifier(for: url)
                )
                config.sessionSendsLaunchEvents = false
                config.isDiscretionary = false
                config.timeoutIntervalForRequest = timeout
                // Multi-gigabyte downloads shouldn't eat a cellular plan.
                config.allowsCellularAccess = !wifiOnly
                config.allowsExpensiveNetworkAccess = !wifiOnly
                config.allowsConstrainedNetworkAccess = false
                config.waitsForConnectivity = true
                config.timeoutIntervalForResource = 60 * 60 * 6
                // Background sessions ignore protocolClasses, so the audit
                // log has to be told about this request explicitly.
                NetworkAudit.note(url)

                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1

                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)

                lock.lock()
                if cancelled {
                    lock.unlock()
                    session.invalidateAndCancel()
                    cont.resume(throwing: CancellationError())
                    return
                }
                self.continuation = cont
                self.session = session
                lock.unlock()

                // Adopt a transfer the system is still running for this
                // URL from a previous life of the app; otherwise start one.
                // A transfer that finished while the app was gone delivers
                // its `didFinishDownloadingTo` on this session by itself.
                session.getAllTasks { [self] tasks in
                    lock.lock()
                    let cancelled = self.cancelled
                    lock.unlock()
                    if cancelled { return }   // `didBecomeInvalidWithError` settles the wait

                    if let existing = tasks.first(where: {
                        $0.originalRequest?.url == url || $0.currentRequest?.url == url
                    }) {
                        existing.resume()
                        return
                    }
                    let task: URLSessionDownloadTask
                    if let resumeData {
                        task = session.downloadTask(withResumeData: resumeData)
                    } else {
                        task = session.downloadTask(with: url)
                    }
                    task.resume()
                }
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let session = self.session
            lock.unlock()
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
            lock.lock()
            moveError = error
            lock.unlock()
        }
    }

    /// The session was torn down with the wait still pending - which can
    /// happen if cancellation lands before a task exists. Nothing else
    /// would ever resume the continuation.
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error ?? CancellationError())
    }

    private static func sessionIdentifier(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "com.aigoodbye.modeldownload." + hex
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let moveError = self.moveError
        lock.unlock()

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
