//
//  MLXService.swift
//  AIGoodbye
//
//  On-device inference for downloaded models via Apple MLX.
//
//  v3.0: rebuilt around the library's ChatSession:
//  - real token streaming (text appears as it is generated)
//  - generation cancels when the caller stops listening (Stop button)
//  - the model's own chat template is applied by the library (no manual
//    prompt strings, no template token cleanup)
//  - the key-value cache is reused across turns, so each message no longer
//    re-processes the whole conversation (big win on older devices)
//  - the Context Window setting genuinely limits how much history is loaded
//

import Foundation
import UIKit
import Combine
import Network
import MLX
import MLXLMCommon
import MLXLLM
import MLXVLM

@MainActor
final class MLXService: ObservableObject {

    // MARK: - Published state

    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalDownloadBytes: Int64 = 0
    @Published var isDownloadStalled: Bool = false
    @Published var isPreparingModel: Bool = false
    @Published var loadedModelId: String?
    /// The model a `performLoad` is currently downloading or preparing. Not
    /// necessarily the selected one: an image question on Apple Intelligence
    /// borrows a vision model, and the storage screen must know that model
    /// is busy even though it is not selected.
    @Published private(set) var loadingModelId: String?
    @Published private(set) var loadingModelName: String?
    /// True while a Wi-Fi-only download is parked because the device is on
    /// cellular or another expensive path. The system waits silently (for
    /// hours) in that state, so the chip has to say what is going on.
    @Published private(set) var isWaitingForWiFi: Bool = false
    /// Seconds left in the running download, from the last ten seconds of
    /// throughput. Nil until there is enough data for an honest figure, and
    /// whenever the transfer is parked or stalled - "about 4 min left" on a
    /// frozen bar is worse than no estimate.
    @Published private(set) var estimatedSecondsRemaining: TimeInterval?

    /// Recent (time, bytes) samples for the estimate.
    private var throughputSamples: [(time: Date, bytes: Int64)] = []

    /// Last moment download bytes moved; drives the stall warning.
    private var lastDownloadActivity = Date()
    private var stallMonitor: Task<Void, Never>?
    private var diskPollTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var pathIsExpensive = false
    private var settingsWatch: AnyCancellable?
    /// The transfer currently running inside `performLoad`, so a settings
    /// change can restart it without cancelling the load that owns it.
    private var prefetchJob: Task<Void, Error>?
    private var restartPrefetch = false

    /// Guards against concurrent loads (e.g. the launch warm-up racing a
    /// user-triggered load): the second caller awaits the first instead of
    /// loading the multi-gigabyte model twice.
    private var inFlightLoad: (id: Int, modelId: String, task: Task<Void, Error>)?
    /// How many callers are waiting on `inFlightLoad`, so cancelling one
    /// screen doesn't abort a download another screen still needs.
    private var inFlightJoiners = 0
    private var nextLoadId = 0

    // MARK: - Private state

    private var modelContainer: ModelContainer?
    private var session: ChatSession?
    private var sessionModelId: String?

    private let settings: SettingsManager

    /// Brand and behavior instructions sent to every model.
    nonisolated static let basePrompt = """
    You are AiGoodbye, a helpful AI assistant created by Dmitry Mikhaylov (Dealer Of Happiness). \
    Official website: aigoodbye.ai. Contact: marketing@dealerofhappiness.com. \
    You run completely offline on the user's device; no data ever leaves the phone. \
    Be concise, helpful, and friendly. Use Markdown formatting (bold, lists, code blocks) when it makes answers clearer. \
    When analyzing images, describe what you see clearly and answer questions about the visual content.
    """

    /// Full system prompt: brand and behavior, the response-language rule,
    /// the active persona, and anything the user asked the app to remember.
    ///
    /// - Parameter memoryTokens: how much of the window remembered facts may
    ///   take (the newest that fit go in). Apple Intelligence passes
    ///   `AppleIntelligenceService.memoryBudgetTokens`; downloaded models an
    ///   eighth of the window they actually get.
    @MainActor
    static func systemPrompt(for language: AppLanguage, memoryTokens: Int) -> String {
        var prompt = basePrompt + " " + language.modelInstruction

        let persona = PersonaStore.shared.activeInstructions
        if !persona.isEmpty {
            prompt += "\n\n" + persona
        }

        let memory = MemoryStore.shared.promptBlock(maxTokens: memoryTokens)
        if !memory.isEmpty {
            prompt += "\n\n" + memory
        }
        return prompt
    }

    /// Language-only prompt for contexts without user personalization
    /// (used by tests and one-shot utilities).
    nonisolated static func basePrompt(for language: AppLanguage) -> String {
        basePrompt + " " + language.modelInstruction
    }

    init(settings: SettingsManager) {
        self.settings = settings

        // Keep the network path's cost current so a Wi-Fi-only download
        // parked on cellular can be reported instead of looking stalled.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.usesInterfaceType(.cellular)
            let service = self
            Task { @MainActor in
                guard let service else { return }
                service.pathIsExpensive = expensive
                service.refreshWiFiWait()
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    /// Whether MLX's Metal allocator has been configured in this process.
    private static var metalConfigured = false

    /// Cap the MLX GPU cache to prevent memory accumulation during inference
    /// (20 MB follows the official mlx-swift-examples guidance for iOS).
    ///
    /// Done on the first load, not at launch: setting the limit creates
    /// MLX's Metal device and allocator, which cost launch time and a few MB
    /// for every user - most of whom, on Apple Intelligence, never load a
    /// downloaded model in a given session. (Never touch MLX's Metal device
    /// in the simulator; it aborts.)
    private static func configureMetalIfNeeded() {
        guard !metalConfigured else { return }
        metalConfigured = true
        #if !targetEnvironment(simulator)
        Memory.cacheLimit = 20 * 1024 * 1024
        #endif
    }

    // MARK: - Model loading

    /// Load (and download if needed) the given model. Safe to call repeatedly
    /// and concurrently: overlapping calls for the same model share one load.
    func loadModel(_ model: AIModel) async throws {
        guard model.backend == .mlx, model.huggingFaceId != nil else {
            throw MLXError.unsupportedBackend(model.name)
        }

        if modelContainer != nil && loadedModelId == model.id { return }

        // Join an in-flight load for the same model, or supersede one for a
        // different model. Looped, because a join can legitimately finish
        // with nothing loaded - `unload()` may have run in between - and
        // returning "success" then leaves every later message failing
        // against a model that isn't there.
        while true {
            if modelContainer != nil && loadedModelId == model.id { return }

            guard let inflight = inFlightLoad else { break }
            guard inflight.modelId == model.id else {
                inflight.task.cancel()
                _ = try? await inflight.task.value
                break
            }
            try await join(inflight)
            // Loaded: done, whether or not the original's `defer` has run
            // yet. (Testing the registry instead of the weights, as this
            // once did, made a joiner that resumed first unload the model
            // that had just finished loading and load it a second time.)
            if modelContainer != nil && loadedModelId == model.id { return }
            // The join succeeded but left nothing loaded (`unload()` ran in
            // between): drop the stale entry and start a fresh load rather
            // than reporting a model that isn't there.
            if inFlightLoad?.id == inflight.id { inFlightLoad = nil; break }
        }

        nextLoadId += 1
        let loadId = nextLoadId
        let task = Task { try await self.performLoad(model) }
        let entry = (id: loadId, modelId: model.id, task: task)
        inFlightLoad = entry
        // Always clears its own entry, joiners or not: they hold the task
        // directly, and leaving a finished task parked here meant a failed
        // load replayed the same error forever and a successful one could
        // report success with nothing loaded.
        defer { if inFlightLoad?.id == loadId { inFlightLoad = nil } }

        try await join(entry)
    }

    /// Cancel the in-flight load or download of `modelId`, if any. Used
    /// when the user removes a model that is still downloading, so the
    /// transfer does not quietly recreate the folder it just deleted.
    func cancelLoad(of modelId: String) {
        guard let inflight = inFlightLoad, inflight.modelId == modelId else { return }
        inflight.task.cancel()
    }

    /// Wait for a load, letting cancellation through.
    ///
    /// `await task.value` is not itself a cancellation point, and the task is
    /// unstructured so it is not a child either. Without the handler, Stop
    /// did nothing during a multi-gigabyte download, Describe Surroundings
    /// sat silent for minutes holding the engine claim, and every other
    /// feature reported "the AI is busy" until it finished.
    private func join(_ entry: (id: Int, modelId: String, task: Task<Void, Error>)) async throws {
        inFlightJoiners += 1
        defer { inFlightJoiners -= 1 }
        try await withTaskCancellationHandler {
            // A cancellable wait, not `entry.task.value`: with two waiters
            // (the setup screen's download and the first message), the one
            // that was cancelled used to keep waiting until the whole load
            // finished, so Stop did nothing and the composer stayed locked.
            try await Timeout.awaitCancellable(entry.task)
        } onCancel: {
            Task { @MainActor [weak self] in
                // Only the last waiter cancels: another screen may still be
                // waiting for the same model.
                guard let self, self.inFlightJoiners <= 1 else { return }
                entry.task.cancel()
            }
        }
        try Task.checkCancellation()
    }

    private func performLoad(_ model: AIModel) async throws {
        guard let hfId = model.huggingFaceId else {
            throw MLXError.unsupportedBackend(model.name)
        }

        // Before any weights exist, so the cache limit is in place for them.
        Self.configureMetalIfNeeded()

        // Memory preflight, before spending minutes downloading something
        // that would be killed the moment it loads. Two different answers:
        // a model that can never fit this device says so (closing apps
        // cannot help) - checked before unloading, so refusing it costs the
        // working model nothing - and one that fits but finds too little
        // free right now says what would help.
        if !model.fitsThisDevice() {
            throw MLXError.modelLoadFailed(
                L10n.text("\(model.name) needs more memory than iOS lets an app use on this device. Choose a smaller model.")
            )
        }

        // Switching models: free the previous one first, and give the
        // allocator its cached buffers back before measuring.
        unload()
        #if !targetEnvironment(simulator)
        Memory.clearCache()
        #endif

        // Other apps don't count here: iOS gives each app its own limit. A
        // shortfall now means this app is holding memory it shouldn't, which
        // a restart clears - "close other apps" was advice that couldn't help.
        // A model that has loaded here before is tried anyway: it fit then.
        let neededGB = model.memoryNeededGB
        if !DeviceCapability.canLoad(neededGB: neededGB),
           !ModelManager.shared.hasLoadedBefore(model) {
            // In the app language's number style ("3,5" in German), not
            // printf's fixed "3.5".
            let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1)).locale(L10n.locale)
            let needText = neededGB.formatted(style)
            let hasText = DeviceCapability.usableMemoryGBExactDecimal.formatted(style)
            throw MLXError.modelLoadFailed(
                L10n.text("\(model.name) needs about \(needText) GB of memory, but AiGoodbye has only about \(hasText) GB free right now. Quit and reopen AiGoodbye, then try again.")
            )
        }

        let wasDownloaded = ModelManager.shared.isModelDownloaded(model)

        // Preflight: a 1.8-5.8 GB download onto a nearly full disk fails late
        // and confusingly. Check up front and say so clearly.
        if !wasDownloaded {
            let alreadyHave = ModelManager.shared.downloadedSizeBytes(for: model)
            let needed = max(model.sizeBytes - alreadyHave, 0) + 300_000_000 // headroom
            if let free = try? URL.documentsDirectory
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage,
               free < needed {
                let neededText = AIModel.formattedBytes(needed)
                throw MLXError.modelLoadFailed(
                    L10n.text("Not enough free space. \(model.name) needs about \(neededText) free. Free up space and try again.")
                )
            }
        }
        loadingModelId = model.id
        loadingModelName = model.name
        // So the Privacy Center labels this load's listing and file requests
        // as the download they are.
        NetworkAudit.shared.downloadingRepo = hfId
        if !wasDownloaded {
            beginDownloadState(expectedBytes: model.sizeBytes)
            if settings.wifiOnlyDownloads { startWiFiWatch() }
        } else {
            isPreparingModel = true
        }
        defer {
            endDownloadState()
            isPreparingModel = false
            loadingModelId = nil
            loadingModelName = nil
            NetworkAudit.shared.downloadingRepo = nil
        }

        // Fast path: download the files ourselves at full network speed with
        // real byte progress. On any failure fall back to the library's own
        // downloader below (which then finds whatever we already fetched).
        var filesOnDisk = wasDownloaded
        if !wasDownloaded, let repoDir = ModelManager.shared.modelDirectory(for: model) {
            do {
                // The transfer runs in a child task of its own so that a
                // change to the Wi-Fi-only setting mid-download can restart
                // just the transfer (with resume data) without cancelling
                // this load. A session's configuration is immutable once
                // created, so a user who turns the setting off to unblock a
                // download parked on cellular used to see nothing happen.
                while true {
                    let prefetcher = ModelPrefetcher()
                    prefetcher.wifiOnly = settings.wifiOnlyDownloads
                    let job = Task { [weak self] in
                        try await prefetcher.prefetch(hfId: hfId, into: repoDir) { done, total in
                            // Bound to a local constant first: reaching for
                            // the capture-list `self` from inside the nested
                            // Task is a reference to a captured var from
                            // concurrent code.
                            let service = self
                            Task { @MainActor in
                                service?.noteDownloadProgress(done: done, total: total)
                            }
                        }
                    }
                    prefetchJob = job
                    do {
                        try await withTaskCancellationHandler {
                            try await Timeout.awaitCancellable(job)
                        } onCancel: {
                            job.cancel()
                        }
                        prefetchJob = nil
                        break
                    } catch {
                        prefetchJob = nil
                        if restartPrefetch, !Task.isCancelled {
                            restartPrefetch = false
                            continue
                        }
                        throw error
                    }
                }
                isDownloading = false
                isDownloadStalled = false
                isPreparingModel = true
                filesOnDisk = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A full disk won't be fixed by trying a second downloader.
                if Self.isOutOfSpace(error) {
                    throw MLXError.modelLoadFailed(
                        L10n.text("Not enough free space. \(model.name) needs about \(model.size) free. Free up space and try again.")
                    )
                }
                // Say what actually went wrong (Hugging Face error, gated
                // repository, no connection) before falling back to the
                // generic Wi-Fi text, which used to be the answer for every
                // failure and told people on Wi-Fi to check their Wi-Fi.
                if let specific = ModelPrefetcher.friendlyMessage(for: error) {
                    throw MLXError.modelLoadFailed(specific)
                }
                if (error as NSError).domain == NSURLErrorDomain {
                    throw MLXError.modelLoadFailed(friendlyMessage(for: error))
                }
                // The library's downloader knows nothing of the Wi-Fi-only
                // setting: falling through to it here would put gigabytes
                // on a cellular plan the user explicitly protected. Stop
                // instead and say so.
                if settings.wifiOnlyDownloads {
                    throw MLXError.modelLoadFailed(
                        isWaitingForWiFi
                            ? L10n.text("Waiting for Wi-Fi. Connect to Wi-Fi, or turn off \"Download over Wi-Fi only\" in Settings.")
                            : L10n.text("The download couldn't be completed. Check that Wi-Fi is connected and try again.")
                    )
                }
                // Library fallback still runs; show byte progress from disk,
                // and record the transfers it is about to make so the
                // Privacy Center's log stays honest.
                NetworkAudit.noteLibraryDownload(files: ModelPrefetcher.plannedTransferURLs(for: model))
                startDiskPollProgress(for: model)
            }
        }

        // Text-only models (which a user can add themselves) are not VLMs and
        // the vision factory doesn't know how to build them.
        let factory: any ModelFactory = model.supportsVision
            ? VLMModelFactory.shared
            : LLMModelFactory.shared

        // Two ways to describe the model to the library:
        //
        // By directory, when the files are on disk. This reads only disk.
        // Identified by Hub id, the library first re-lists the repository
        // and checks every file against huggingface.co, and consults the
        // local copy only when the network is entirely absent - so on a
        // captive portal, a filtered network, or an outage, a fully
        // installed model failed with "Download failed" and the app then
        // offered to download it again. It could also quietly re-download
        // 1.8 GB behind "Preparing" if the repository had been re-pushed.
        //
        // By Hub id, for the download itself, and as the one retry if a
        // local load fails on a file an older download never fetched: that
        // path fetches only what is missing, into the same folder.
        //
        // `hub:` is not optional in either case. The library's own default
        // points at Library/Caches, a different folder from the one the
        // prefetcher fills, so leaving it out made the loader download the
        // whole model a second time after the app had already said the
        // model was installed.
        let tokenizerLoader = TransformersTokenizerLoader()
        func load(_ configuration: ModelConfiguration) async throws -> ModelContainer {
            try await factory.loadContainer(
                from: AppHubDownloader(hub: ModelManager.shared.hub),
                using: tokenizerLoader,
                configuration: configuration
            ) { [weak self] progress in
                let service = self
                Task { @MainActor in
                    guard let service, progress.isFinished, service.isDownloading else { return }
                    service.isDownloading = false
                    service.isPreparingModel = true
                }
            }
        }
        // Installed models load straight from their folder: no downloader is
        // involved, so nothing can reach the network on this path.
        func load(directory: URL) async throws -> ModelContainer {
            try await factory.loadContainer(from: directory, using: tokenizerLoader)
        }

        // A download that finishes while the phone is locked or another app
        // is in front lands here in the background. iOS does not allow GPU
        // work from the background and aborts the process when it is tried,
        // so the weights wait until the user is back. (The library fallback
        // below downloads and loads in one call and cannot be split; this
        // only covers its start. It is reached only when the fast path
        // failed.)
        try await waitUntilActive()

        let hubConfiguration = ModelConfiguration(id: hfId)
        do {
            if filesOnDisk, let repoDir = ModelManager.shared.modelDirectory(for: model) {
                do {
                    modelContainer = try await load(directory: repoDir)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Retry through the Hub only for a file an older download
                    // never fetched. Any other failure (unsupported
                    // architecture, corrupt shard, out of memory) used to go
                    // the same way, which contacted huggingface.co for an
                    // installed model and, offline, replaced the real error
                    // with "No internet connection".
                    guard ModelPrefetcher.isMissingFileError(error) else { throw error }
                    if settings.wifiOnlyDownloads, isOnExpensivePath() {
                        throw MLXError.modelLoadFailed(
                            L10n.text("Waiting for Wi-Fi. Connect to Wi-Fi, or turn off \"Download over Wi-Fi only\" in Settings.")
                        )
                    }
                    beginDownloadState(expectedBytes: model.sizeBytes)
                    NetworkAudit.noteLibraryDownload(files: ModelPrefetcher.plannedTransferURLs(for: model))
                    startDiskPollProgress(for: model)
                    modelContainer = try await load(hubConfiguration)
                }
            } else {
                modelContainer = try await load(hubConfiguration)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MLXError.modelLoadFailed(friendlyMessage(for: error))
        }

        loadedModelId = model.id
        // The container loaded successfully, so the files on disk are known
        // good: record completeness so a future partial state is detectable.
        ModelManager.shared.markDownloadComplete(model)
        ModelManager.shared.noteModelInstalled(model)
    }

    /// Suspends until the app is active. Returns at once when it already is;
    /// throws `CancellationError` if the load is cancelled while waiting.
    private func waitUntilActive() async throws {
        guard UIApplication.shared.applicationState != .active else { return }
        isAwaitingForeground = true
        defer { isAwaitingForeground = false }

        let (activations, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            continuation.yield()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Checked again now that the observer is in place, so an activation
        // between the first check and the subscription is not missed.
        if UIApplication.shared.applicationState == .active { return }

        await withTaskCancellationHandler {
            for await _ in activations { break }
        } onCancel: {
            continuation.finish()
        }
        try Task.checkCancellation()
    }

    // MARK: - Download progress bookkeeping

    private func beginDownloadState(expectedBytes: Int64) {
        isDownloading = true
        downloadProgress = 0
        downloadedBytes = 0
        totalDownloadBytes = expectedBytes
        isDownloadStalled = false
        lastDownloadActivity = Date()
        throughputSamples = []
        estimatedSecondsRemaining = nil

        // Warn when no bytes have moved for a while (bad Wi-Fi, captive
        // portal, etc.) so the user is never stuck staring at a frozen bar.
        stallMonitor?.cancel()
        stallMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.isDownloading else { break }
                // Parked for Wi-Fi is not a stall; the chip says so instead.
                if !self.isWaitingForWiFi,
                   Date().timeIntervalSince(self.lastDownloadActivity) > 45 {
                    self.isDownloadStalled = true
                }
                // No progress callbacks arrive while nothing moves, so the
                // estimate is refreshed here too: it must not keep promising
                // "2 min left" through a stall.
                self.updateEstimate(now: Date())
            }
        }
    }

    private func endDownloadState() {
        isDownloading = false
        isDownloadStalled = false
        isWaitingForWiFi = false
        throughputSamples = []
        estimatedSecondsRemaining = nil
        stallMonitor?.cancel()
        stallMonitor = nil
        diskPollTask?.cancel()
        diskPollTask = nil
        settingsWatch = nil
        prefetchJob = nil
        restartPrefetch = false
    }

    /// While a Wi-Fi-only download runs: say when it is parked because the
    /// device is on cellular (the system otherwise waits for hours behind a
    /// frozen bar), and restart the transfer if the user turns the setting
    /// off meanwhile (a session's configuration cannot change after the
    /// fact; resume data makes the restart cheap).
    private func startWiFiWatch() {
        refreshWiFiWait()
        settingsWatch = settings.$wifiOnlyDownloads
            .dropFirst()
            .sink { [weak self] wifiOnly in
                let service = self
                Task { @MainActor in
                    guard let service, service.isDownloading, !wifiOnly, let job = service.prefetchJob else { return }
                    service.isWaitingForWiFi = false
                    service.restartPrefetch = true
                    job.cancel()
                }
            }
    }

    /// Whether the current network path is cellular or otherwise expensive
    /// (kept current by the path monitor started in `init`).
    private func isOnExpensivePath() -> Bool { pathIsExpensive }

    private func refreshWiFiWait() {
        let waiting = isDownloading && settings.wifiOnlyDownloads && pathIsExpensive
        if waiting != isWaitingForWiFi { isWaitingForWiFi = waiting }
        if waiting {
            lastDownloadActivity = Date()
            isDownloadStalled = false
            // Parked: the old throughput says nothing about when it resumes.
            throughputSamples = []
            if estimatedSecondsRemaining != nil { estimatedSecondsRemaining = nil }
        }
    }

    private func noteDownloadProgress(done: Int64, total: Int64) {
        if done > downloadedBytes {
            lastDownloadActivity = Date()
            isDownloadStalled = false
        }
        downloadedBytes = done
        totalDownloadBytes = max(total, 1)
        downloadProgress = min(Double(done) / Double(max(total, 1)), 0.999)

        let now = Date()
        // A restart (Wi-Fi toggle, fallback downloader) can report fewer
        // bytes than before; the old samples would then describe a
        // different transfer.
        if let last = throughputSamples.last, done < last.bytes { throughputSamples = [] }
        // Callbacks can arrive hundreds of times a second; two samples a
        // second are plenty for a ten-second window.
        if let last = throughputSamples.last, now.timeIntervalSince(last.time) < 0.5 { return }
        throughputSamples.append((time: now, bytes: done))
        updateEstimate(now: now)
    }

    /// Recompute `estimatedSecondsRemaining` from the last ten seconds.
    private func updateEstimate(now: Date) {
        let window: TimeInterval = 10
        throughputSamples.removeAll { now.timeIntervalSince($0.time) > window }

        var estimate: TimeInterval?
        if isDownloading, !isWaitingForWiFi, !isDownloadStalled,
           let first = throughputSamples.first, let last = throughputSamples.last {
            let span = last.time.timeIntervalSince(first.time)
            let moved = Double(last.bytes - first.bytes)
            // Three seconds of data at least: the first callbacks after a
            // resume arrive in a burst and would promise seconds for gigabytes.
            if span >= 3, moved > 0 {
                let remainingBytes = Double(max(totalDownloadBytes - last.bytes, 0))
                estimate = (remainingBytes / (moved / span)).rounded()
            }
        }
        // Whole seconds only, so a progress callback that changes nothing
        // visible does not republish.
        if estimate != estimatedSecondsRemaining { estimatedSecondsRemaining = estimate }
    }

    /// Fallback progress source: watch bytes appear on disk while the
    /// library's own downloader runs.
    private func startDiskPollProgress(for model: AIModel) {
        diskPollTask?.cancel()
        diskPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isDownloading else { break }
                // Uncached: the cached value was taken before the download
                // started and would never move.
                let bytes = ModelManager.shared.currentSizeOnDisk(for: model)
                self.noteDownloadProgress(done: bytes, total: max(model.sizeBytes, bytes))
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    #if DEBUG
    /// Test hook: run only the download phase (no Metal weight loading), so
    /// the full download UX can be exercised in the iOS Simulator.
    /// Launch with AIG_SIM_TEST_DOWNLOAD=1 to activate.
    func debugDownloadOnly(_ model: AIModel) async throws {
        // Joined like the real load is: the setup screen and the first
        // message both arrive here, and two prefetches of one file would
        // open two background sessions under the same identifier.
        if let inflight = debugDownloadTask {
            try await Timeout.awaitCancellable(inflight)
            return
        }
        let task = Task { [self] in
            guard let hfId = model.huggingFaceId,
                  let repoDir = ModelManager.shared.modelDirectory(for: model) else { return }
            beginDownloadState(expectedBytes: model.sizeBytes)
            defer { endDownloadState() }
            try await ModelPrefetcher().prefetch(hfId: hfId, into: repoDir) { [weak self] done, total in
                let service = self
                Task { @MainActor in
                    service?.noteDownloadProgress(done: done, total: total)
                }
            }
            ModelManager.shared.noteModelInstalled(model)
        }
        debugDownloadTask = task
        defer { debugDownloadTask = nil }
        // Cancellable, like the real load: `task.value` on an unstructured
        // task is not a cancellation point, so Stop would otherwise wait
        // for the whole download.
        try await withTaskCancellationHandler {
            try await Timeout.awaitCancellable(task)
        } onCancel: {
            task.cancel()
        }
    }

    private var debugDownloadTask: Task<Void, Error>?
    #endif

    func unload() {
        session = nil
        sessionModelId = nil
        modelContainer = nil
        loadedModelId = nil
    }

    /// Drop only the chat session; the loaded model stays in memory.
    func dropSession() {
        session = nil
        sessionModelId = nil
    }

    var isModelLoaded: Bool { modelContainer != nil }

    /// Generations currently streaming. Memory-warning handling must not
    /// touch the model while this is non-zero.
    private var activeGenerations = 0

    /// True while weights are loading or an answer is being produced.
    var isBusy: Bool {
        inFlightLoad != nil || isDownloading || isPreparingModel || activeGenerations > 0
    }

    /// True only while Metal is in use: weights going onto the GPU, or a
    /// generation running. A pure transfer is not - it runs on a background
    /// URLSession that is built to survive the app leaving the foreground,
    /// so going to the background must not cancel it. A load parked in
    /// `waitUntilActive` is not using the GPU either.
    var isUsingGPU: Bool {
        (isPreparingModel && !isAwaitingForeground) || activeGenerations > 0
    }

    /// Set while `performLoad` waits for the app to come back to the
    /// foreground before touching Metal.
    private var isAwaitingForeground = false

    // MARK: - Conversation session

    /// Start (or restart) the chat session for a conversation.
    ///
    /// Call when: a conversation is opened or switched, history is edited
    /// (regenerate, clear), or the model / context setting changes.
    /// Do NOT call between normal turns; keeping the session alive is what
    /// enables cache reuse.
    func startSession(
        model: AIModel,
        history: [(role: String, content: String)],
        instructions overrideInstructions: String? = nil
    ) {
        guard let container = modelContainer, loadedModelId == model.id else {
            session = nil
            sessionModelId = nil
            return
        }

        // repetitionPenalty is essential for small quantized models: without
        // it, 2B-class models can loop the same phrases endlessly.
        // maxTokens scales with the user's context setting so long answers
        // aren't needlessly cut off when there's room for them.
        //
        // Deliberately NO `maxKVSize`. It makes MLX use a rotating KV cache,
        // and Qwen3-VL's attention builds its mask without consulting the
        // cache's rotation (unlike the text-only models). Once a session
        // passed the cap, the mask and the keys disagreed in shape and MLX's
        // C++ core threw - which the Swift wrapper turns into `fatalError`.
        // A process crash roughly ten image turns into a conversation, and
        // silent loss of the system prompt before that.
        //
        // Memory is bounded another way: `sessionTokenEstimate` tracks what
        // the session has accumulated, and once it crosses `budget` the
        // session is dropped after the turn so the next one is rebuilt from
        // trimmed history with a fresh cache.
        let budget = Self.effectiveContextWindow(for: model, requested: settings.contextWindow)
        sessionTokenBudget = budget
        let parameters = GenerateParameters(
            maxTokens: budget >= 16384 ? 2048 : 1200,
            // The smallest models get a fraction of the Creativity setting:
            // see `AIModel.temperatureScale`.
            temperature: Float(settings.temperature * model.temperatureScale),
            topP: 0.9,
            repetitionPenalty: model.repetitionPenalty,
            repetitionContextSize: 64
        )

        let edge = model.imageProcessingEdge
        let processing = UserInput.Processing(
            resize: CGSize(width: edge, height: edge)
        )

        // Trimmed against the window we will honour, not the one the user
        // asked for: on a 6 GB phone those differ, and history sized to the
        // larger number arrived in a cache budgeted for the smaller one.
        // Half of it, so that several turns fit before the session is
        // retired and rebuilt (a full prefill, tens of seconds on a 2B VLM).
        let trimmed = Self.trimHistory(history, tokenBudget: budget / 2)
        let chatHistory: [Chat.Message] = trimmed.compactMap { entry in
            switch entry.role.lowercased() {
            case "user": return .user(entry.content)
            case "assistant": return .assistant(entry.content)
            default: return nil
            }
        }

        let instructions = overrideInstructions
            ?? Self.systemPrompt(for: settings.appLanguage, memoryTokens: budget / 8)

        // What the cache starts out holding. Seeding this with the history
        // matters: a reopened conversation used to start its count at zero
        // with thousands of tokens already in the cache, and the retirement
        // below then fired far too late. The instructions are counted here
        // and again on every turn, because the session re-sends them with
        // each prompt and the model attends to every copy.
        sessionInstructionTokens = Self.weightedLength(of: instructions) / 3
        sessionTokenEstimate = sessionInstructionTokens
            + trimmed.reduce(0) { $0 + Self.weightedLength(of: $1.content) / 3 }
        if chatHistory.isEmpty {
            session = ChatSession(
                container,
                instructions: instructions,
                generateParameters: parameters,
                processing: processing,
                additionalContext: Self.chatTemplateContext
            )
        } else {
            session = ChatSession(
                container,
                instructions: instructions,
                history: chatHistory,
                generateParameters: parameters,
                processing: processing,
                additionalContext: Self.chatTemplateContext
            )
        }
        sessionModelId = model.id
    }

    /// See `ChatTemplateOptions.context` (MLXIntegration.swift).
    nonisolated static var chatTemplateContext: [String: any Sendable] { ChatTemplateOptions.context }

    /// Whether a live session exists for the given model.
    func hasSession(for model: AIModel) -> Bool {
        session != nil && sessionModelId == model.id
    }

    /// Roughly how many tokens the live session's cache holds, and the cap.
    ///
    /// The cache is what makes a long conversation eat memory: about 112 KB
    /// per token for the 2B model, so 8K tokens is close to a gigabyte on top
    /// of the weights. Rather than a rotating cache (which crashes Qwen3-VL,
    /// see `startSession`), the session is simply retired once it has
    /// accumulated more than it should hold; the next turn rebuilds it from
    /// trimmed history, which is a few seconds of prefill.
    private var sessionTokenEstimate = 0
    private var sessionTokenBudget = 8192
    private var sessionInstructionTokens = 0

    private func noteTurnCompleted(tokens: Int) {
        sessionTokenEstimate += max(0, tokens) + sessionInstructionTokens
        guard sessionTokenEstimate > sessionTokenBudget else { return }
        dropSession()
    }

    /// The context window we will actually honour for a model, which is the
    /// user's setting capped by what its key-value cache can cost in memory.
    ///
    /// The cache grows with the model's depth, so a 32K window that is fine
    /// on the 500 MB model is several gigabytes on the 8B one. Silently
    /// choosing a smaller number is much better than being killed mid-answer.
    /// Sized against the device's stable budget, not against whatever memory
    /// happens to be free at this instant - which is measured immediately
    /// after the weights load, and so gave the same setting a different
    /// meaning in every session.
    nonisolated static func effectiveContextWindow(
        for model: AIModel,
        requested: Int,
        usableMemoryGB: Int = DeviceCapability.memoryBudgetGB
    ) -> Int {
        // Per-token key-value cost, from the models' actual configs:
        // Qwen3-VL-2B is 28 layers x 8 KV heads x 128 dims x 2 (K and V)
        // x 2 bytes = 112 KiB; the 8B is 36 layers = 144 KiB. The earlier
        // estimate of 25 KB per GB of weights was 2.5x too low, which let an
        // "8K" window cost nearly a gigabyte on a 6 GB phone.
        let gigabytes = Double(model.sizeBytes) / 1_000_000_000
        let kilobytesPerToken: Double = gigabytes < 3 ? 112 : 144

        // Never let the cache exceed a quarter of what the app can have.
        let budgetKB = Double(usableMemoryGB) * 1_048_576 * 0.25
        let affordable = Int(budgetKB / kilobytesPerToken)

        return max(2048, min(requested, affordable))
    }

    // MARK: - Generation

    /// Stream a response. Yields the FULL response text so far with each event
    /// (snapshot semantics). Ending iteration early cancels generation.
    /// Only the newest snapshot is buffered; older ones are superseded anyway.
    func respondStream(prompt: String, image: UIImage?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            guard let session = self.session else {
                continuation.finish(throwing: MLXError.modelNotLoaded)
                return
            }

            // Orientation must be applied here: `cgImage` alone is the raw
            // sensor bitmap, so a portrait photo would reach the model
            // rotated 90 degrees while looking upright on screen.
            let userImage: UserInput.Image?
            if let image, let oriented = ImageNormalizer.orientedCIImage(from: image) {
                userImage = .ciImage(oriented)
            } else {
                userImage = nil
            }

            // Estimated cost of this turn: the prompt, plus a picture, which
            // Qwen3-VL turns into roughly 430-580 tokens at this edge size.
            let promptTokens = Self.weightedLength(of: prompt) / 3 + (userImage == nil ? 0 : 600)
            self.activeGenerations += 1

            let task = Task {
                defer { Task { @MainActor in self.activeGenerations = max(0, self.activeGenerations - 1) } }
                var accumulated = ""
                do {
                    let stream = session.streamResponse(to: prompt, image: userImage)
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        accumulated += chunk
                        continuation.yield(ChatTemplateOptions.visibleAnswer(accumulated))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: MLXError.generationFailed(self.friendlyMessage(for: error)))
                }
                await MainActor.run {
                    self.noteTurnCompleted(tokens: promptTokens + Self.weightedLength(of: accumulated) / 3)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - History trimming

    /// Keep the most recent messages that fit within the token budget.
    ///
    /// Cost is script-aware: Latin-like text averages ~3.5 characters per
    /// token, but CJK (Chinese/Japanese/Korean) averages ~1.5 — so each CJK
    /// character is charged at 2.3x. Without this, Chinese conversations
    /// would overrun the real context window 2-3x.
    nonisolated static func trimHistory(
        _ history: [(role: String, content: String)],
        tokenBudget: Int
    ) -> [(role: String, content: String)] {
        // Reserve room (in tokens) for the system prompt, the next question
        // and the answer, then convert at the same 3 characters per token
        // the session estimate uses. The old mix of a character reserve and
        // a 3.5 ratio made a full conversation count as over budget the
        // moment its session was built, so it was rebuilt on every turn.
        let reserveTokens = 600
        let charBudget = max(2000, (tokenBudget - reserveTokens) * 3)

        var result: [(role: String, content: String)] = []
        var used = 0
        for entry in history.reversed() {
            // Individual messages are capped so one huge document cannot
            // consume the entire window.
            let content = entry.content.count > 4000
                ? String(entry.content.prefix(4000)) + "\n[Truncated]"
                : entry.content
            let cost = weightedLength(of: content)
            if used + cost > charBudget { break }
            result.append((entry.role, content))
            used += cost
        }
        return result.reversed()
    }

    /// Character count with CJK characters weighted at 2.3x (they carry far
    /// more tokens per character than Latin text).
    nonisolated static func weightedLength(of text: String) -> Int {
        var latin = 0
        var cjk = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2E80...0x9FFF,     // CJK radicals, ideographs, kana
                 0xAC00...0xD7AF,     // Hangul syllables
                 0xF900...0xFAFF,     // CJK compatibility ideographs
                 0x20000...0x2FA1F:   // CJK extensions
                cjk += 1
            default:
                latin += 1
            }
        }
        return latin + Int(Double(cjk) * 2.3)
    }

    // MARK: - Errors

    private func friendlyMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return L10n.text("No internet connection. The model download needs internet once; chatting works fully offline afterward.")
            case NSURLErrorTimedOut:
                return L10n.text("The connection timed out. Please try again.")
            default: break
            }
        }
        // Missing files after a failed download attempt (the library falls
        // back to an empty local folder when it can't reach the internet).
        if ns.domain == NSCocoaErrorDomain
            && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError) {
            return L10n.text("The download couldn't start. Check your internet connection and try again.")
        }
        if Self.isOutOfSpace(error) {
            return L10n.text("Your device is out of free space. Free up storage and try again.")
        }
        return error.localizedDescription
    }

    /// Whether an error means the disk is full (Cocoa or POSIX flavor).
    nonisolated static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isOutOfSpace(underlying)
        }
        return false
    }
}

// MARK: - Errors

enum MLXError: LocalizedError {
    case modelNotLoaded
    case modelLoadFailed(String)
    case generationFailed(String)
    case unsupportedBackend(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return L10n.text("The AI model isn't ready yet. Download or select a model in Settings.")
        case .modelLoadFailed(let reason):
            return L10n.text("Couldn't load the model: \(reason)")
        case .generationFailed(let reason):
            return L10n.text("Couldn't generate a response: \(reason)")
        case .unsupportedBackend(let name):
            return L10n.text("\(name) can't run on this engine.")
        }
    }
}
