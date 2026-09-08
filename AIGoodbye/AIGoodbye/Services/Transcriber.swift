//
//  Transcriber.swift
//  AIGoodbye
//
//  On-device speech to text for long recordings.
//
//  Prefers `SpeechTranscriber` (iOS 26), which is built for long-form audio:
//  no per-request length limit, far better accuracy than the older
//  `SFSpeechRecognizer` (roughly a quarter of the errors on an hour-long
//  meeting in published benchmarks), automatic punctuation, and word-level
//  timestamps. Its model is managed by the system and shared between apps,
//  so it costs the app nothing to ship.
//
//  It supports around ten languages. For everything else this falls back to
//  `SFSpeechRecognizer` with `requiresOnDeviceRecognition`, rotating requests
//  underneath a continuous tap to work around that API's ~1 minute limit.
//
//  Either way, nothing is sent to a server.
//

import Foundation
// `@preconcurrency`: AVAudioConverter's input block is declared `@Sendable`,
// but it is invoked synchronously inside `convert(to:error:)` on the calling
// thread, so handing it the tap's buffer is safe and the warning is noise.
@preconcurrency import AVFoundation
import Speech

@MainActor
final class Transcriber {

    enum Engine: Equatable {
        /// iOS 26 SpeechAnalyzer: accurate, long-form, punctuated.
        case analyzer
        /// SFSpeechRecognizer with rotating requests.
        case legacy
        /// No offline recognizer for this language.
        case none
    }

    private(set) var engine: Engine = .none

    /// Called with the full transcript so far, whenever it changes.
    var onText: ((String) -> Void)?

    /// Called if recognition dies mid-recording. Audio capture is unaffected,
    /// so the recorder keeps recording and tells the user that the words
    /// stopped - which is far better than a transcript that silently freezes
    /// and is only discovered two hours later.
    var onRecognitionFailed: (() -> Void)?

    /// 0...1 while a speech model is downloading during `prepare`.
    var onInstallProgress: ((Double) -> Void)?

    // Modern path
    private var analyzer: SpeechAnalyzer?
    private var speechTranscriber: SpeechTranscriber?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    /// The locale the assets were actually installed for.
    ///
    /// Never the caller's locale. The app asks in terms of bare language codes
    /// ("en", "ru", "zh-Hans"), and `SpeechTranscriber`'s supported locales are
    /// region-qualified ("en_US", "ru_RU"). Installing assets for one and then
    /// building the module with the other is how you get a session that starts
    /// cleanly and then transcribes nothing.
    private var resolvedLocale: Locale?
    /// Identifies the current session, so results from a cancelled one are
    /// ignored rather than written into a discarded transcript.
    private var currentGeneration = UUID()
    /// Text of results marked final, plus the volatile tail.
    private var finalizedText = ""
    private var volatileText = ""
    /// Last time a partial (volatile) result was published.
    private var lastVolatilePublish = Date.distantPast
    /// Partial results arrive several times a second and each publication
    /// re-renders the whole transcript; at hour three that is the difference
    /// between a smooth screen and a hot, stuttering one.
    private let volatilePublishInterval: TimeInterval = 0.25

    // Legacy path
    private let legacy = LegacyTranscriber()

    /// Words worth recognizing that the model wouldn't know: names of people
    /// in the user's meetings, product names, jargon. This is the single
    /// biggest accuracy lever a recorder has.
    var customVocabulary: [String] = []

    // MARK: - Setup

    /// Pick an engine for this language and make sure its model is installed.
    /// Returns the engine that will actually be used.
    func prepare(locale: Locale) async -> Engine {
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            do {
                try await installAssetsIfNeeded(for: supported)
                resolvedLocale = supported
                engine = .analyzer
                return engine
            } catch {
                // Fall through: an asset that won't install shouldn't stop
                // the user recording.
                resolvedLocale = nil
            }
        }
        engine = await prepareLegacy(locale: locale)
        return engine
    }

    /// The legacy recognizer, if it exists for this language and the user
    /// allows it. Its authorization is asked for here, lazily, and never on
    /// the SpeechAnalyzer path: Apple's dialog for it says speech data will
    /// be sent to Apple, which is untrue of either engine as this app uses
    /// them, and flatly contradicts the promise on the screen behind it.
    /// The modern engine needs only the microphone.
    private func prepareLegacy(locale: Locale) async -> Engine {
        guard legacy.isAvailable(for: locale) else { return .none }
        guard await Self.legacyRecognitionAuthorized() else { return .none }
        return .legacy
    }

    /// Whether `SFSpeechRecognizer` may be used, asking once if undecided.
    static func legacyRecognitionAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    /// True when the only reason there is no engine is that the user said no
    /// to the legacy recognizer, so a screen can point at Settings instead of
    /// claiming the language is unsupported.
    static var legacyRecognitionDenied: Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted: return true
        default: return false
        }
    }

    private func installAssetsIfNeeded(for locale: Locale) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        // Reserved, so the system doesn't reclaim the asset between
        // recordings and hand us a module that quietly produces nothing.
        // Best effort: the reservation limit is small and shared.
        _ = try? await AssetInventory.reserve(locale: locale)

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let progress = request.progress
            let reporter = Task { [weak self] in
                while !Task.isCancelled {
                    let fraction = progress.fractionCompleted
                    await MainActor.run { self?.onInstallProgress?(fraction) }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            defer { reporter.cancel() }
            try await request.downloadAndInstall()
        }
        speechTranscriber = transcriber
    }

    // MARK: - Running

    func start(locale: Locale) async throws {
        finalizedText = ""
        volatileText = ""
        lastVolatilePublish = .distantPast

        switch engine {
        case .analyzer:
            do {
                try await startAnalyzer()
            } catch {
                // The modern engine reported its assets installed and then
                // refused to start. Rather than record with no transcript
                // at all, drop to the older recognizer if this language has
                // one; only if that is missing too does the failure surface.
                discardAnalyzer()
                guard await prepareLegacy(locale: locale) == .legacy else { throw error }
                engine = .legacy
                try startLegacy(locale: locale)
            }
        case .legacy:
            try startLegacy(locale: locale)
        case .none:
            break
        }
    }

    private func startLegacy(locale: Locale) throws {
        legacy.onText = { [weak self] text in
            Task { @MainActor in self?.onText?(text) }
        }
        legacy.onFailure = { [weak self] _ in
            Task { @MainActor in self?.onRecognitionFailed?() }
        }
        try legacy.start(locale: locale)
    }

    private func startAnalyzer() async throws {
        // Any previous session must be torn down before a new one starts.
        // Two live sessions overwrite each other's continuation and results
        // task, leaving an orphaned analyzer holding the speech model.
        resultsTask?.cancel()
        resultsTask = nil
        feed.close()

        // Bumped before the first `await`, not after. A previous session's
        // results task can throw while this one is starting, and its catch
        // block checks the generation - if this is still the old value when
        // that lands, the old session closes the feed we have just opened and
        // the new one transcribes nothing, silently.
        let generation = UUID()
        currentGeneration = generation

        let locale = resolvedLocale ?? Locale.current

        // Always a fresh module: a `SpeechTranscriber` whose results sequence
        // has already terminated will attach happily to a new analyzer and
        // then produce nothing, with no error to explain it.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        speechTranscriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Names and jargon the model has never seen. Cheap, and it is what
        // people notice when it goes wrong.
        if !customVocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: customVocabulary]
            // Best effort: a rejected vocabulary must not stop the recording.
            try? await analyzer.setContext(context)
        }

        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        // Bounded on purpose. If the results sequence ever throws, its
        // consumer exits while the render thread keeps producing; an
        // unbounded buffer would then grow by roughly 230 MB an hour next to
        // a multi-gigabyte model, and the app would be killed. Dropping the
        // oldest audio instead costs nothing, because by then nothing is
        // reading it.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(96)
        )
        let epoch = feed.open(continuation: continuation, format: analyzerFormat)
        try await analyzer.start(inputSequence: stream)
        // A `cancel()` or a newer `start()` during that await wins. Only
        // this session's own stream is closed - a newer session may already
        // have reopened the feed for itself, and closing that would silence
        // the session that replaced us.
        guard currentGeneration == generation else {
            feed.close(epoch: epoch)
            Task { await analyzer.cancelAndFinishNow() }
            return
        }

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run {
                        self.apply(text: text, isFinal: isFinal, generation: generation)
                    }
                }
            } catch {
                // The session is dead. Close the feed so the render thread
                // stops producing into a buffer nobody drains, and tell the
                // recorder so it can say so out loud.
                await MainActor.run {
                    guard self.currentGeneration == generation else { return }
                    self.feed.close()
                    self.onRecognitionFailed?()
                }
            }
        }
    }

    /// Fold one recognition result into the transcript.
    private func apply(text: String, isFinal: Bool, generation: UUID) {
        // A result that arrives after cancel() must not resurrect a
        // transcript the caller discarded.
        guard currentGeneration == generation else { return }
        if isFinal {
            // Committed: append and clear the live tail.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                finalizedText += finalizedText.isEmpty ? trimmed : " " + trimmed
            }
            volatileText = ""
            lastVolatilePublish = .distantPast
            onText?(currentText)
            return
        }

        volatileText = text
        let now = Date()
        guard now.timeIntervalSince(lastVolatilePublish) >= volatilePublishInterval else { return }
        lastVolatilePublish = now
        onText?(currentText)
    }

    var currentText: String {
        switch engine {
        case .analyzer:
            let tail = volatileText.trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.isEmpty { return finalizedText }
            return finalizedText.isEmpty ? tail : finalizedText + " " + tail
        case .legacy:
            return legacy.currentText
        case .none:
            return ""
        }
    }

    /// Feed audio.
    ///
    /// Called on the audio render thread, and the tap's buffer is only valid
    /// for the duration of that callback - so the conversion and the yield
    /// both happen here, synchronously. Hopping to the main actor and using
    /// the buffer later would read freed memory, and would also drop the
    /// final buffers when `finish()` closes the stream first.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        legacy.append(buffer)
        feed.append(buffer)
    }

    /// Owns the analyzer's input stream and format converter so the render
    /// thread can use them without touching main-actor state.
    private let feed = AnalyzerFeed()

    /// Stop and return the complete transcript.
    func finish() async -> String {
        switch engine {
        case .analyzer:
            feed.close()

            // Detach the results task and the analyzer *first*. Whatever the
            // framework calls below do, teardown has already happened, so no
            // later result can write into a finished transcript.
            let analyzer = self.analyzer
            let resultsTask = self.resultsTask
            self.analyzer = nil
            self.resultsTask = nil
            self.speechTranscriber = nil

            // Terminating the input stream is NOT enough: the session has to
            // be finalized explicitly or the tail is never committed.
            //
            // Every wait here is bounded. An unbounded await would wedge the
            // recorder screen with the microphone still live and no way out
            // but killing the app, which for a meeting recording is worse
            // than losing the last sentence.
            await Timeout.run(seconds: 5) {
                try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            }
            await Timeout.join(resultsTask, seconds: 3)
            resultsTask?.cancel()
            return currentText
        case .legacy:
            return await legacy.finish()
        case .none:
            return ""
        }
    }

    func cancel() {
        // Invalidate first: late results must not write into the transcript
        // we are about to discard.
        currentGeneration = UUID()
        onText = nil
        onRecognitionFailed = nil
        discardAnalyzer()
        legacy.cancel()
        finalizedText = ""
        volatileText = ""
    }

    /// Tear the modern session down without waiting for it. Whatever it was
    /// holding - the input stream, the results task, the speech model - is
    /// released; nothing it says afterwards is heard.
    private func discardAnalyzer() {
        currentGeneration = UUID()
        feed.close()
        resultsTask?.cancel()
        resultsTask = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        speechTranscriber = nil
        Task { await analyzer?.cancelAndFinishNow() }
    }
}

// MARK: - Analyzer feed

/// The bridge from the audio render thread to the analyzer.
///
/// Holds the input continuation and the format converter behind one lock, so
/// a tap callback can convert and yield without ever leaving the callback -
/// which is required, because the tap's buffer is deallocated the moment it
/// returns.
private nonisolated final class AnalyzerFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    /// Counts `open` calls, so a session can close its own stream without
    /// risk of closing a newer one that has taken its place.
    private var epoch = 0

    @discardableResult
    func open(continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat?) -> Int {
        lock.lock()
        // Finish any previous stream rather than dropping its continuation on
        // the floor, which would leave a consumer waiting forever.
        let previous = self.continuation
        self.continuation = continuation
        self.target = format
        self.converter = nil
        epoch += 1
        let opened = epoch
        lock.unlock()
        previous?.finish()
        return opened
    }

    func close() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.converter = nil
        lock.unlock()
        continuation?.finish()
    }

    /// Close only if the stream opened as `epoch` is still the live one.
    func close(epoch: Int) {
        lock.lock()
        guard self.epoch == epoch else { lock.unlock(); return }
        let continuation = self.continuation
        self.continuation = nil
        self.converter = nil
        lock.unlock()
        continuation?.finish()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard continuation != nil else { return }
        guard let converted = convertLocked(buffer) else { return }
        continuation?.yield(AnalyzerInput(buffer: converted))
    }

    /// The analyzer wants its own format; the tap gives us the hardware's.
    /// Caller holds the lock.
    private func convertLocked(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // Without a known target format we cannot safely hand anything over:
        // feeding raw hardware buffers to a module expecting another rate
        // produces silence or noise, not a transcript.
        guard let target else { return nil }
        if buffer.format.isEqual(target) { return buffer }

        // The converter is cached - building one per callback is the
        // expensive part. The output buffer cannot be: the analyzer keeps
        // what it is handed until it has processed it, so a reused buffer
        // would be overwritten underneath it.
        if converter == nil || converter?.inputFormat.isEqual(buffer.format) == false {
            converter = AVAudioConverter(from: buffer.format, to: target)
            // Priming would drift the timestamps of a long recording.
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

// MARK: - Legacy engine

/// `SFSpeechRecognizer` with requests rotated underneath a continuous tap,
/// because a single request gives up after about a minute. Only used for
/// languages `SpeechTranscriber` doesn't cover.
nonisolated final class LegacyTranscriber: @unchecked Sendable {

    enum StartError: Error {
        /// No on-device recognizer for this language, right now.
        case unavailable
    }

    var onText: ((String) -> Void)?
    /// The recognizer has given up. Called at most once per `start`.
    var onFailure: ((String) -> Void)?

    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tasks: [Int: SFSpeechRecognitionTask] = [:]
    private var requests: [Int: SFSpeechAudioBufferRecognitionRequest] = [:]
    private var segments: [Int: String] = [:]
    private var segmentIndex = 0
    /// Cached join of `segments`, rebuilt only when a segment changes.
    /// Recomputing it per callback meant sorting and joining ~320 segments
    /// several times a second by the end of a four-hour recording.
    private var cachedText = ""
    private var rotationTimer: Timer?
    private var isRunning = false

    /// Segments that ended in an error without ever producing a word, in a
    /// row. This is the guard against the failure that was measured live: a
    /// recognizer that errors the instant a task starts was being restarted
    /// with no delay, about a thousand times a second, for as long as the
    /// recording ran - the CPU pegged, the battery draining, the screen
    /// saying "Transcribing on this device", and not one word appearing.
    private var consecutiveFailures = 0
    private var hasReportedFailure = false
    private let maximumConsecutiveFailures = 5

    private let segmentSeconds: TimeInterval = 45

    func isAvailable(for locale: Locale) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    var currentText: String {
        lock.lock(); defer { lock.unlock() }
        return cachedText
    }

    func start(locale: Locale) throws {
        // Checked here rather than silently inside `beginSegment`, which used
        // to leave the screen claiming it was transcribing over a transcript
        // that would never appear.
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw StartError.unavailable
        }
        self.recognizer = recognizer
        lock.lock()
        segments = [:]
        cachedText = ""
        segmentIndex = 0
        isRunning = true
        consecutiveFailures = 0
        hasReportedFailure = false
        lock.unlock()
        beginSegment()

        let timer = Timer(timeInterval: segmentSeconds, repeats: true) { [weak self] _ in
            self?.rotate()
        }
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    /// Caller holds the lock.
    private func rebuildCachedTextLocked() {
        cachedText = segments.keys.sorted()
            .compactMap { segments[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func beginSegment() {
        guard let recognizer, recognizer.isAvailable else { return }
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        let index = segmentIndex
        segmentIndex += 1
        lock.unlock()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true

        lock.lock()
        requests[index] = request
        self.request = request
        lock.unlock()

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            var producedWords = false
            if let result {
                self.lock.lock()
                self.segments[index] = result.bestTranscription.formattedString
                producedWords = !(self.segments[index] ?? "").isEmpty
                self.rebuildCachedTextLocked()
                let text = self.cachedText
                self.lock.unlock()
                self.onText?(text)
            }
            guard error != nil || result?.isFinal == true else { return }

            self.lock.lock()
            self.requests[index] = nil
            self.tasks[index] = nil
            let shouldRestart = self.isRunning && index == self.segmentIndex - 1
            // A segment that produced words and then ended is normal; one
            // that ended in an error having produced nothing is a strike.
            if error != nil && !producedWords {
                self.consecutiveFailures += 1
            } else if producedWords {
                self.consecutiveFailures = 0
            }
            let strikes = self.consecutiveFailures
            let giveUp = strikes >= self.maximumConsecutiveFailures && !self.hasReportedFailure
            if giveUp { self.hasReportedFailure = true; self.isRunning = false }
            self.lock.unlock()

            if giveUp {
                self.onFailure?(error?.localizedDescription ?? "")
                return
            }
            guard shouldRestart else { return }

            // Back off after a failure. An immediate restart of a recognizer
            // that fails instantly is a hot loop; a short, growing pause is
            // what turns "retry" into something a phone can survive.
            if strikes > 0 {
                let delay = min(0.5 * pow(2.0, Double(strikes - 1)), 4.0)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.beginSegment()
                }
            } else {
                self.beginSegment()
            }
        }
        lock.lock()
        tasks[index] = task
        lock.unlock()
    }

    /// Start the next request before ending the previous one, so no audio
    /// falls between them.
    private func rotate() {
        lock.lock()
        let previous = segmentIndex - 1
        let running = isRunning
        lock.unlock()
        guard running else { return }
        beginSegment()
        lock.lock()
        let old = requests[previous]
        lock.unlock()
        old?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
    }

    func finish() async -> String {
        stopTimers()
        for request in endAllRequests() { request.endAudio() }

        // Give the recognizer a moment to commit the tail.
        for _ in 0..<20 {
            if hasNoRunningTasks() { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let text = currentText
        cancel()
        return text
    }

    /// Locking helpers, kept out of the async function above: taking an
    /// `NSLock` around a suspension point is unsafe under Swift concurrency.
    private func endAllRequests() -> [SFSpeechAudioBufferRecognitionRequest] {
        lock.lock()
        isRunning = false
        let open = Array(requests.values)
        lock.unlock()
        return open
    }

    private func hasNoRunningTasks() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tasks.isEmpty
    }

    func cancel() {
        stopTimers()
        lock.lock()
        isRunning = false
        let running = Array(tasks.values)
        tasks.removeAll()
        requests.removeAll()
        request = nil
        lock.unlock()
        for task in running { task.cancel() }
    }

    private func stopTimers() {
        rotationTimer?.invalidate()
        rotationTimer = nil
    }
}
