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
//  Interrupted transfers continue instead of starting over: resume data from
//  a failure *or* a user cancel is parked next to the destination file
//  (`<file>.resume`), so a network blip or a Stop at 90% of a 5.8 GB file
//  costs nothing - across retries and across app launches.
//
//  If anything here fails, MLXService falls back to the library's built-in
//  downloader, so this is a pure fast-path: correctness never depends on it.
//

import CryptoKit
import Foundation

/// Thrown from the download delegate's queue as well as from the main actor,
/// so it must not pick up the module's main-actor default.
nonisolated enum PrefetchError: Error {
    /// The repository listing failed. `status` is the HTTP status, or 0 when
    /// no request could be built at all.
    case listingFailed(status: Int)
    case noFiles
    /// A file transfer ended with a non-2xx response (0: no request built).
    case downloadFailed(status: Int)
    case sizeMismatch
}

final class ModelPrefetcher {

    /// Downloads all *.safetensors and *.json files for the repo into `repoDir`.
    /// `progress` is called with (downloadedBytes, totalBytes) from a background
    /// queue; throttle/hop as needed on the receiving side.
    /// When true, downloads are refused on cellular (models are 1-6 GB).
    var wifiOnly: Bool = true

    /// Per-model manifest of the URLs this prefetcher transfers, kept beside
    /// the files. A delete needs it to reach the background sessions by
    /// identifier - offline, and without the model's directory listing.
    private static let transferManifestName = ".aig_transfers"

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

        // 2. File listing with sizes. The HTTP status travels with the error:
        // a 503 from Hugging Face, a 429, and a gated repository each need a
        // different sentence, and a blanket "check Wi-Fi" was wrong for all.
        guard let treeURL = URL(string: "https://huggingface.co/api/models/\(hfId)/tree/main?recursive=true") else {
            throw PrefetchError.listingFailed(status: 0)
        }
        let (treeData, treeResponse) = try await URLSession.shared.data(from: treeURL)
        let listingStatus = (treeResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard listingStatus == 200 else {
            throw PrefetchError.listingFailed(status: listingStatus)
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

        // Resolve every source URL before the first byte moves. Paths are
        // percent-encoded: a repository file name with a space or a
        // non-ASCII character used to make `URL(string:)` fail halfway
        // through the download, reported as a Wi-Fi problem.
        var sources: [(file: RepoFile, url: URL)] = []
        for file in files {
            guard let encodedPath = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "https://huggingface.co/\(hfId)/resolve/main/\(encodedPath)") else {
                throw PrefetchError.downloadFailed(status: 0)
            }
            sources.append((file: file, url: url))
        }
        Self.writeTransferManifest(urls: sources.map { $0.url }, in: repoDir)

        let totalBytes = files.reduce(Int64(0)) { $0 + $1.actualSize }
        var completedBytes: Int64 = 0
        progress(0, totalBytes)

        let metaDir = repoDir
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("download", isDirectory: true)

        // 3. Download files sequentially (the big weights file dominates anyway).
        for (file, sourceURL) in sources {
            try Task.checkCancellation()

            let destination = repoDir.appendingPathComponent(file.path)
            let resumeFile = FileDownload.resumeDataFile(for: destination)
            let expectedSize = file.actualSize

            // Already fully downloaded (size matches)? Count it and move on.
            if expectedSize > 0,
               let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
               (attrs[.size] as? Int64) == expectedSize {
                try? FileManager.default.removeItem(at: resumeFile)
                writeSidecarIfNeeded(for: file, commitHash: commitHash, metaDir: metaDir)
                completedBytes += expectedSize
                progress(completedBytes, totalBytes)
                continue
            }

            // The parent must exist now, not only when the file lands: resume
            // data for a file in a subfolder is parked next to it, and the
            // cancel path must never create directories itself (it can run
            // moments after the user deleted the model).
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let base = completedBytes
            var attempt = 0
            // Resume data left by an earlier cancel or failure - in this life
            // of the app or a previous one - continues the transfer instead
            // of restarting a multi-gigabyte file from byte zero.
            var resumeData: Data? = FileManager.default.contents(atPath: resumeFile.path)
            if resumeData?.isEmpty == true { resumeData = nil }
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
                            try? FileManager.default.removeItem(at: resumeFile)
                            throw PrefetchError.sizeMismatch
                        }
                    }
                    // The file is complete; its resume data is stale now.
                    try? FileManager.default.removeItem(at: resumeFile)
                    break
                } catch {
                    // Park partial progress on disk before anything else, so
                    // a kill between retries (or the cancel below) does not
                    // lose it. Without new resume data the old blob is stale.
                    let harvested = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                    if let harvested {
                        resumeData = harvested
                        try? harvested.write(to: resumeFile, options: .atomic)
                    }
                    try Task.checkCancellation()
                    if harvested == nil {
                        resumeData = nil
                        try? FileManager.default.removeItem(at: resumeFile)
                    }
                    // A full disk won't heal with retries, and neither will a
                    // gated repository or a missing file (4xx).
                    if MLXService.isOutOfSpace(error) { throw error }
                    if let prefetchError = error as? PrefetchError,
                       case .downloadFailed(let status) = prefetchError,
                       (400..<500).contains(status) {
                        throw error
                    }
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
    ///
    /// Written even without a commit hash: the library compares the hash
    /// first and, when it is empty, falls through to the etag, which is
    /// enough to accept the file. Skipping the sidecar when the repo-info
    /// call failed left installed models looking unverified, so every load
    /// re-listed the repository and failed outright offline.
    private func writeSidecarIfNeeded(for file: RepoFile, commitHash: String?, metaDir: URL) {
        let etag = file.lfs?.oid ?? file.oid ?? ""
        guard !etag.isEmpty else { return }
        let metaPath = metaDir.appendingPathComponent(file.path + ".metadata")
        guard !FileManager.default.fileExists(atPath: metaPath.path) else { return }
        try? FileManager.default.createDirectory(
            at: metaPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = "\(commitHash ?? "")\n\(etag)\n\(Date().timeIntervalSince1970)\n"
        try? contents.write(to: metaPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Transfer manifest and background-session teardown

    private static func writeTransferManifest(urls: [URL], in repoDir: URL) {
        try? FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(urls.map(\.absoluteString)) else { return }
        try? data.write(to: repoDir.appendingPathComponent(transferManifestName), options: .atomic)
    }

    /// The file URLs the prefetcher planned for this model, from the manifest
    /// written at listing time. Empty when nothing was ever started.
    static func plannedTransferURLs(for model: AIModel) -> [URL] {
        guard let repoDir = ModelManager.shared.modelDirectory(for: model) else { return [] }
        let manifest = repoDir.appendingPathComponent(transferManifestName)
        guard let data = FileManager.default.contents(atPath: manifest.path),
              let strings = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return strings.compactMap { URL(string: $0) }
    }

    /// Stop any transfer the system is still running for this model.
    ///
    /// A background session outlives the app: after a kill mid-download the
    /// daemon keeps going, and nothing in the process holds a handle to it.
    /// "Remove" on the storage screen used to delete the folder while the
    /// daemon carried on for hours and then parked the finished file. Each
    /// per-file session is reachable by its stable identifier, so recreate it
    /// and tear it down. Must run before the model directory is deleted: the
    /// manifest lives inside it.
    static func cancelBackgroundTransfers(for model: AIModel) {
        for url in plannedTransferURLs(for: model) {
            let identifier = FileDownload.sessionIdentifier(for: url)
            // A FileDownload in this process owns that identifier and its own
            // cancel path tears it down. Two live sessions with one identifier
            // is undefined behavior, and its continuation could hang forever.
            if FileDownload.isLive(identifier) { continue }
            let config = URLSessionConfiguration.background(withIdentifier: identifier)
            config.sessionSendsLaunchEvents = false
            URLSession(configuration: config).invalidateAndCancel()
        }
    }

    // MARK: - Error helpers shared with MLXService

    /// A user-facing sentence for errors this prefetcher knows more about than
    /// `localizedDescription` says; nil when it has nothing specific to add.
    nonisolated static func friendlyMessage(for error: Error) -> String? {
        guard let prefetchError = error as? PrefetchError else { return nil }
        switch prefetchError {
        case .listingFailed(let status), .downloadFailed(let status):
            switch status {
            case 401, 403:
                return L10n.text("This model is gated or private and can't be downloaded.")
            case 429, 500...:
                return L10n.text("Hugging Face returned an error (\(status)). Try again later.")
            default:
                return nil
            }
        case .noFiles, .sizeMismatch:
            return nil
        }
    }

    /// Whether an error means a file that should be on disk is not (Cocoa or
    /// POSIX flavor, including as an underlying error).
    nonisolated static func isMissingFileError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain
            && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError) {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isMissingFileError(underlying)
        }
        return false
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
///
/// `nonisolated`: URLSession calls the delegate on its own queue, so nothing
/// here may assume the main actor.
nonisolated final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let wifiOnly: Bool
    private let onBytes: @Sendable (Int64) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    /// The transfer, kept so a cancel can ask it for resume data. Nil until
    /// `getAllTasks` has created or adopted it.
    private var task: URLSessionDownloadTask?
    private var ownedIdentifier: String?
    private var cancelled = false
    /// Set once the transfer completed or the session was invalidated. The
    /// `getAllTasks` reply can arrive after both - a transfer the system
    /// finished while the app was dead is delivered the instant the session
    /// exists - and creating a task on an invalidated session is an
    /// uncatchable NSException.
    private var finished = false
    private var moveError: Error?
    // Touched only on the serial delegate queue.
    private var lastReport = Date.distantPast
    private var notedRedirect: URL?

    /// Identifiers of background sessions a `FileDownload` in this process
    /// currently owns, so a delete never opens a second session on one of
    /// them (see `ModelPrefetcher.cancelBackgroundTransfers`).
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var liveIdentifiers = Set<String>()

    static func isLive(_ identifier: String) -> Bool {
        liveLock.lock()
        defer { liveLock.unlock() }
        return liveIdentifiers.contains(identifier)
    }

    private static func setLive(_ identifier: String, _ live: Bool) {
        liveLock.lock()
        if live { liveIdentifiers.insert(identifier) } else { liveIdentifiers.remove(identifier) }
        liveLock.unlock()
    }

    /// Where resume data for `destination` waits between attempts and
    /// between app launches.
    static func resumeDataFile(for destination: URL) -> URL {
        destination.appendingPathExtension("resume")
    }

    private var resumeFile: URL { Self.resumeDataFile(for: destination) }

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
                let identifier = Self.sessionIdentifier(for: url)
                let config = URLSessionConfiguration.background(withIdentifier: identifier)
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
                Self.setLive(identifier, true)

                lock.lock()
                self.ownedIdentifier = identifier
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
                    // Held to the end: a cancel that lands in between must
                    // either see the task (and cancel it) or be seen here
                    // (and create none). Nothing below calls back into the
                    // delegate synchronously, so holding it is safe.
                    lock.lock()
                    defer { lock.unlock() }
                    guard !cancelled, !finished, let session = self.session else { return }

                    let task: URLSessionDownloadTask
                    if let existing = tasks.compactMap({ $0 as? URLSessionDownloadTask }).first(where: {
                        $0.originalRequest?.url == url || $0.currentRequest?.url == url
                    }) {
                        task = existing
                    } else if let resumeData {
                        task = session.downloadTask(withResumeData: resumeData)
                    } else {
                        task = session.downloadTask(with: url)
                    }
                    self.task = task
                    task.resume()
                }
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let task = self.task
            let session = self.session
            lock.unlock()
            if let task {
                // Keep the bytes. `invalidateAndCancel()` here threw away the
                // system's temp file, so a Stop, a model switch or opening
                // another chat at 1.7 GB of 1.8 restarted from zero while
                // the banner promised the opposite. The task completes with
                // NSURLErrorCancelled and `didCompleteWithError` tears the
                // session down.
                let resumeFile = self.resumeFile
                task.cancel(byProducingResumeData: { data in
                    guard let data else { return }
                    try? data.write(to: resumeFile, options: .atomic)
                })
            } else {
                // No task yet: `getAllTasks` sees `cancelled` and creates
                // none; `didBecomeInvalidWithError` settles the wait.
                session?.invalidateAndCancel()
            }
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

    /// The bytes come from the CDN host the redirect names (`cdn-lfs*.hf.co`,
    /// `cas-bridge.xethub.hf.co`), not from huggingface.co, and the Privacy
    /// Center should list the host that actually served them. Background
    /// sessions follow redirects on their own and do not deliver this call;
    /// for them `didCompleteWithError` notes the final URL instead.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url, url != notedRedirect {
            notedRedirect = url
            NetworkAudit.note(url, method: request.httpMethod ?? "GET")
        }
        completionHandler(request)
    }

    private func noteRedirectTarget(of task: URLSessionTask) {
        guard let final = task.currentRequest?.url ?? task.response?.url,
              let original = task.originalRequest?.url,
              final != original, final != notedRedirect else { return }
        notedRedirect = final
        NetworkAudit.note(final)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode,
               !(200..<300).contains(status) {
                throw PrefetchError.downloadFailed(status: status)
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
        finished = true
        self.session = nil
        self.task = nil
        let identifier = ownedIdentifier
        lock.unlock()
        if let identifier { Self.setLive(identifier, false) }
        cont?.resume(throwing: error ?? CancellationError())
    }

    /// Stable per-URL identifier of the background session that transfers
    /// it. Internal so `ModelPrefetcher.cancelBackgroundTransfers` can
    /// reach a session no `FileDownload` holds any more.
    static func sessionIdentifier(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "com.aigoodbye.modeldownload." + hex
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        noteRedirectTarget(of: task)
        // Park resume data before anyone observes completion, so it is on
        // disk by the time the caller decides what to do next.
        if let error,
           let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeFile, options: .atomic)
        }

        lock.lock()
        let cont = continuation
        continuation = nil
        finished = true
        self.session = nil
        self.task = nil
        let moveError = self.moveError
        lock.unlock()

        // Cancel, not finish: this session exists for one file. If a
        // transfer completed by the system while the app was away was
        // delivered here alongside a fresh task for the same URL, the fresh
        // one must not go on downloading a second copy in the background.
        session.invalidateAndCancel()

        if let error {
            cont?.resume(throwing: error)
        } else if let moveError {
            cont?.resume(throwing: moveError)
        } else {
            cont?.resume(returning: ())
        }
    }
}
