//
//  RecordingService.swift
//  AIGoodbye
//
//  Long-form audio capture with continuous on-device transcription.
//
//  Recognition is handled by Transcriber, which prefers the iOS 26
//  SpeechTranscriber for long-form accuracy and falls back to the older
//  recognizer for languages it does not cover. This file owns the audio
//  graph, the level meter, the optional audio file, and the recording
//  lifecycle. Nothing is ever sent to a server.
//
//  The audio render thread does the absolute minimum: hand the buffer to the
//  recognizer, measure the level, and pass a copy to a writer queue. Encoding
//  AAC or touching the filesystem on that thread causes dropouts.
//

import Foundation
import AVFoundation
import Combine

/// Shared with the real-time audio thread, so every access is lock-guarded
/// and nothing here may touch main-actor state.
final class AudioCaptureSink: @unchecked Sendable {
    /// Where audio goes to be recognized. Set to nil to stop feeding it.
    private let requestLock = NSLock()
    private var transcriber: Transcriber?

    /// Separate from the request lock so the UI's level meter never waits
    /// behind the recognizer.
    private let levelLock = NSLock()
    private var level: Double = 0
    private var peakLevel: Double = 0

    /// File writing happens off the render thread: AAC encoding and disk I/O
    /// there would glitch the audio. The audio thread only ever reads the
    /// small state flags below, never the queue.
    private let writerQueue = DispatchQueue(label: "aig.recorder.writer", qos: .userInitiated)
    private var file: AVAudioFile?          // writerQueue only

    private let stateLock = NSLock()
    private var hasFile = false
    private var writeFailed = false
    private var queuedBuffers = 0
    private var droppedBuffers = 0

    /// If the writer falls this far behind, drop buffers rather than grow
    /// memory without bound - about 22 seconds of backlog at 48 kHz.
    ///
    /// Dropping is deliberately not the same as failing. A transient stall
    /// four minutes into a four-hour meeting used to end audio writing for
    /// good; now it costs a few seconds and recovers.
    private let maximumQueuedBuffers = 256

    func setTranscriber(_ newTranscriber: Transcriber?) {
        requestLock.lock(); transcriber = newTranscriber; requestLock.unlock()
    }

    /// Called from the main actor only. Synchronous so that passing nil also
    /// drains the queue and closes the file before the caller continues.
    func setFile(_ newFile: AVAudioFile?) {
        stateLock.lock()
        hasFile = newFile != nil
        if newFile != nil { writeFailed = false; queuedBuffers = 0; droppedBuffers = 0 }
        stateLock.unlock()
        writerQueue.sync { file = newFile }
    }

    func currentLevel() -> Double {
        levelLock.lock(); defer { levelLock.unlock() }; return level
    }

    /// The loudest moment so far. Distinguishes "the microphone gave us
    /// silence" from "we heard plenty but recognized none of it" - two very
    /// different problems that used to get the same message.
    func peakLevelSoFar() -> Double {
        levelLock.lock(); defer { levelLock.unlock() }; return peakLevel
    }

    func resetPeakLevel() {
        levelLock.lock(); peakLevel = 0; levelLock.unlock()
    }

    func fileWriteFailed() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return writeFailed
    }

    /// How many buffers were dropped because the writer was behind. Non-zero
    /// means a gap in the audio, not a dead file.
    func droppedBufferCount() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }; return droppedBuffers
    }

    var isWritingFile: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return hasFile
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        requestLock.lock()
        let sink = transcriber
        requestLock.unlock()
        sink?.append(buffer)

        if let channel = buffer.floatChannelData?[0] {
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for index in stride(from: 0, to: frames, by: 16) {
                sum += channel[index] * channel[index]
            }
            let rms = sqrt(sum / Float(max(frames / 16, 1)))
            levelLock.lock()
            level = min(Double(rms) * 12, 1)
            peakLevel = max(peakLevel, level)
            levelLock.unlock()
        }

        stateLock.lock()
        let shouldWrite = hasFile && !writeFailed
        let backedUp = queuedBuffers >= maximumQueuedBuffers
        if shouldWrite && backedUp { droppedBuffers += 1 }
        stateLock.unlock()

        // The tap's buffer is only valid for the duration of this callback.
        // Copied before the queue count is incremented: a failed allocation
        // used to leave the count raised forever, and 256 of those silently
        // ended audio writing for the rest of the recording.
        guard shouldWrite, !backedUp, let copy = Self.copy(of: buffer) else { return }
        stateLock.lock()
        queuedBuffers += 1
        stateLock.unlock()

        writerQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.queuedBuffers = max(self.queuedBuffers - 1, 0)
                self.stateLock.unlock()
            }
            guard let file = self.file else { return }
            // A format mismatch makes AVAudioFile.write raise an
            // Objective-C exception, which Swift cannot catch - so check.
            //
            // Compared field by field, not with `isEqual`, which also
            // compares the channel layout: a tap on Bluetooth or a USB
            // interface carries a layout tag the file's own format does not,
            // and every byte-identical buffer was being rejected - producing
            // an empty file and an "out of space" message on a device with
            // plenty of space.
            guard Self.isWritable(copy.format, into: file.processingFormat) else {
                self.markFailed()
                return
            }
            do {
                try file.write(from: copy)
            } catch {
                // Stop trying: a full disk would otherwise throw per buffer.
                self.markFailed()
            }
        }
    }

    /// Whether `AVAudioFile.write(from:)` will accept a buffer in this format.
    private static func isWritable(_ format: AVAudioFormat, into fileFormat: AVAudioFormat) -> Bool {
        format.sampleRate == fileFormat.sampleRate
            && format.channelCount == fileFormat.channelCount
            && format.commonFormat == fileFormat.commonFormat
            && format.isInterleaved == fileFormat.isInterleaved
    }

    /// writerQueue only.
    private func markFailed() {
        file = nil
        stateLock.lock()
        writeFailed = true
        hasFile = false
        stateLock.unlock()
    }

    /// Copies through the audio buffer list, so interleaved and multi-channel
    /// formats are handled correctly rather than reading past the end of a
    /// single channel pointer.
    private static func copy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                          frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for (from, to) in zip(source, destination) {
            guard let sourceData = from.mData, let destinationData = to.mData else { return nil }
            memcpy(destinationData, sourceData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}

@MainActor
final class RecordingService: NSObject, ObservableObject {

    /// `.preparing` covers the window between the tap and the first byte of
    /// audio: permission prompts, and on first use of a language a speech
    /// model download that can take minutes. Without it the screen looked
    /// completely idle and inviting a second tap, which started a second
    /// session on top of the first.
    enum Phase: Equatable { case idle, preparing, recording, paused, finishing }

    @Published private(set) var phase: Phase = .idle
    /// 0...1 while a speech model downloads during `.preparing`.
    @Published private(set) var preparingProgress: Double = 0
    @Published private(set) var transcript: String = ""
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Double = 0
    /// Non-fatal problems worth telling the user about mid-recording.
    @Published private(set) var notice: String?
    /// False when this language has no offline recognizer: audio is still
    /// captured, but there will be no transcript.
    @Published private(set) var transcribes = true
    /// Set when the length cap is hit so the screen can save and close.
    @Published private(set) var reachedLimit = false

    /// Hard ceiling so a forgotten recording can't fill the device.
    static let maximumDuration: TimeInterval = 4 * 60 * 60
    /// Free space required before starting.
    static let requiredFreeBytes: Int64 = 250 * 1024 * 1024

    private var audioEngine = AVAudioEngine()
    private let sink = AudioCaptureSink()

    /// Owns whichever speech engine this language supports.
    private let transcriber = Transcriber()
    /// Which engine is in use, so the UI can be honest about accuracy.
    @Published private(set) var engine: Transcriber.Engine = .none

    private var tickTimer: Timer?
    private var noticeExpiry: Task<Void, Never>?
    private var systemResumeTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var didInstallTap = false
    private var sessionIsActive = false
    private var observers: [NSObjectProtocol] = []

    /// Monotonic: a clock change must not corrupt the duration.
    private var startedAt: TimeInterval?
    private var accumulated: TimeInterval = 0
    /// True only when the system paused us, so an interruption ending never
    /// re-opens the microphone the user deliberately closed.
    private var pausedBySystem = false
    private var isFinishing = false

    private(set) var audioFileName: String?
    private var audioFileURL: URL?
    /// Format the audio file was created with (nil when no file is kept).
    private var audioFormat: AVAudioFormat?
    /// Format the current tap was installed with, to notice route changes.
    private var tapFormat: AVAudioFormat?
    private var language: AppLanguage = .automatic
    /// Identity and wall-clock start of the recording in progress, so a
    /// crash checkpoint can be turned back into a real recording.
    private var recordingId: UUID?
    private var recordingStartedAtWallClock: Date?
    /// What the user asked for. Audio is captured regardless; this decides
    /// whether it survives `finish()`.
    private var userWantsAudio = false
    /// Whether the microphone delivered any sound at all during the last
    /// recording, so the screen can tell "silence" from "words not recognized".
    private(set) var heardAudio = true

    override init() {
        super.init()
        registerForAudioNotifications()
    }

    // MARK: - Preconditions

    static func hasRoomToRecord() -> Bool {
        let url = RecordingStore.directory
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return true }
        return available > requiredFreeBytes
    }

    // MARK: - Lifecycle

    /// Begin a new recording. Returns false when it couldn't start; `notice`
    /// explains why. `transcriptionAllowed` is false when the user declined
    /// speech recognition but still wants an audio recording.
    func start(
        language: AppLanguage,
        keepAudio: Bool,
        transcriptionAllowed: Bool = true,
        customVocabulary: [String] = []
    ) async -> Bool {
        guard phase == .idle else { return false }
        // Set synchronously, before the first `await`. The guard above is
        // otherwise useless: everything below suspends, and a second tap
        // during a speech-model download used to pass straight through it.
        phase = .preparing
        preparingProgress = 0

        guard Self.hasRoomToRecord() else {
            notice = L10n.text("There isn't enough free space to record. Free up some space and try again.")
            phase = .idle
            return false
        }

        self.language = language
        transcript = ""
        accumulated = 0
        elapsed = 0
        notice = nil
        reachedLimit = false
        isFinishing = false
        pausedBySystem = false
        audioFileName = nil
        audioFileURL = nil
        audioFormat = nil

        // Pick the best engine this language has, and install its model if
        // needed. On iOS 26 that is SpeechTranscriber, which is far more
        // accurate on long recordings than the older recognizer.
        let locale = VoiceService.voiceLocale(for: language)
        transcriber.customVocabulary = customVocabulary
        transcriber.onText = { [weak self] text in
            self?.transcript = text
        }
        transcriber.onInstallProgress = { [weak self] fraction in
            self?.preparingProgress = fraction
        }
        transcriber.onRecognitionFailed = { [weak self] in
            self?.handleRecognitionFailure()
        }
        engine = transcriptionAllowed ? await transcriber.prepare(locale: locale) : .none
        transcribes = engine != .none

        // The user may have closed the screen while the model downloaded.
        guard phase == .preparing else {
            transcriber.cancel()
            return false
        }

        do {
            try activateSession()

            let format = try installTap()

            // Recognition is started before the file is created, because
            // whether the file is needed depends on whether recognition
            // actually works.
            if transcribes {
                do {
                    try await transcriber.start(locale: locale)
                    // Checked again: starting the speech session suspends,
                    // and the screen closing during it calls `cancel()`,
                    // which tears the audio down. Continuing past that point
                    // would build a second audio file and re-arm the engine
                    // behind a screen that is no longer there.
                    guard phase == .preparing else {
                        transcriber.cancel()
                        return false
                    }
                    // The transcriber may have dropped to its fallback
                    // engine while starting; the screen should say which.
                    engine = transcriber.engine
                    sink.setTranscriber(transcriber)
                } catch {
                    // A speech engine that won't start is no reason to refuse
                    // to record. Degrade to audio only and say so - telling
                    // someone about to record a consultation that the
                    // microphone is busy, when it isn't, costs them the whole
                    // recording.
                    engine = .none
                    transcribes = false
                    notice = L10n.text("Transcription isn't available right now, so this recording will be audio only.")
                }
            }

            // The audio is ALWAYS captured while recording, whatever the
            // preference says. It is the insurance policy: a recognizer can
            // report itself available and then produce nothing (measured
            // live - three minutes of clear speech, an empty transcript, and
            // the user told to check their microphone), and by then it is
            // far too late to start recording. If the user didn't want the
            // audio and the transcript comes out fine, `finish()` deletes it.
            userWantsAudio = keepAudio
            prepareAudioFile(format: format)
            if audioFileURL == nil {
                notice = L10n.text("The audio file couldn't be created, so only the transcript will be saved.")
            }
            sink.resetPeakLevel()

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            sink.setTranscriber(nil)
            transcriber.cancel()
            discardAudioFile()
            tearDownAudio()
            if notice == nil {
                notice = L10n.text("The microphone couldn't be started. Check that another app isn't using it.")
            }
            phase = .idle
            return false
        }

        // Last check before going live, for the same reason.
        guard phase == .preparing else {
            sink.setTranscriber(nil)
            transcriber.cancel()
            discardAudioFile()
            tearDownAudio()
            return false
        }

        if !transcribes && notice == nil {
            notice = Transcriber.legacyRecognitionDenied
                ? L10n.text("Speech recognition is turned off for AiGoodbye, so this recording will be audio only. You can turn it on in the Settings app.")
                : L10n.text("Offline transcription isn't available for this language, so this recording will be audio only.")
        }

        startedAt = ProcessInfo.processInfo.systemUptime
        recordingId = UUID()
        recordingStartedAtWallClock = Date()
        phase = .recording
        preparingProgress = 0
        startTimers()
        startCheckpointing()
        return true
    }

    // MARK: - Crash recovery

    /// Snapshot the transcript to disk every few seconds.
    ///
    /// Everything up to this point lived only in memory until `finish()`
    /// returned. An out-of-memory kill at minute 179 of a three-hour meeting
    /// lost every word - which is the single worst thing this feature could
    /// do to the people it was built for.
    private func startCheckpointing() {
        checkpointTask?.cancel()
        checkpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.phase == .recording || self.phase == .paused else { continue }
                self.writeCheckpoint()
            }
        }
    }

    private func writeCheckpoint() {
        guard let id = recordingId, let startedAtWallClock = recordingStartedAtWallClock else { return }
        RecordingStore.shared.writeCheckpoint(
            RecordingCheckpoint(
                id: id,
                startedAt: startedAtWallClock,
                transcript: transcript,
                duration: elapsed,
                audioFileName: audioFileName,
                languageCode: language.rawValue
            )
        )
    }

    private func stopCheckpointing() {
        checkpointTask?.cancel()
        checkpointTask = nil
    }

    /// Recognition died mid-recording. Audio capture is untouched, so keep
    /// recording and be honest rather than letting the transcript freeze
    /// silently for the next two hours.
    private func handleRecognitionFailure() {
        guard phase == .recording || phase == .paused else { return }
        guard transcribes else { return }
        transcribes = false
        // Audio is already being captured (it always is), so this is now
        // purely about being honest with the user.
        userWantsAudio = true
        engine = .none
        sink.setTranscriber(nil)
        notice = transcript.isEmpty
            ? L10n.text("Speech couldn't be recognized for this language right now, so this recording is audio only. It is being saved.")
            : L10n.text("Transcription stopped, but recording is continuing. The audio is being saved.")
    }

    func pause() {
        guard phase == .recording else { return }
        systemResumeTask?.cancel()
        pausedBySystem = false
        performPause()
    }

    /// - Parameter releaseSession: whether to give up the audio session.
    ///   Deliberately false for pauses the system caused: releasing it drops
    ///   the app's background-audio assertion, and a backgrounded recorder
    ///   that loses that gets suspended - so the interruption-ended
    ///   notification arrives only when the user next opens the app, hours
    ///   later, with nothing recorded in between.
    private func performPause(releaseSession: Bool = true) {
        guard phase == .recording else { return }
        accumulated += ProcessInfo.processInfo.systemUptime - (startedAt ?? ProcessInfo.processInfo.systemUptime)
        startedAt = nil
        phase = .paused
        stopTimers()
        // Stop feeding audio, but keep the recognition session alive so
        // resuming continues the same transcript.
        sink.setTranscriber(nil)
        if audioEngine.isRunning { audioEngine.stop() }
        level = 0
        // Don't hold the microphone (and the "in use" indicator) while the
        // user has deliberately paused.
        if releaseSession { deactivateSession() }
    }

    func resume() {
        guard phase == .paused, !reachedLimit else { return }
        pausedBySystem = false
        do {
            try activateSession()
            // The route may have changed while paused, so the tap has to be
            // rebuilt against the current hardware format.
            let format = try installTap()
            if let existing = audioFormat, !format.isEqual(existing) {
                // The file can only hold its original format; keep what was
                // written and continue with the transcript alone.
                sink.setFile(nil)
                // Cleared, or the same notice fires again on every later
                // resume for a file that no longer exists.
                audioFormat = nil
                notice = L10n.text("The audio device changed, so only the transcript continues from here.")
            }
            // Reconnected before the engine starts, so the first buffers
            // after a resume are transcribed rather than silently dropped.
            if transcribes { sink.setTranscriber(transcriber) }
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            sink.setTranscriber(nil)
            deactivateSession()
            notice = L10n.text("The microphone couldn't be started. Check that another app isn't using it.")
            return
        }
        clearNoticeSoon()
        startedAt = ProcessInfo.processInfo.systemUptime
        phase = .recording
        startTimers()
        startCheckpointing()
    }

    /// Stop capture and wait briefly for the last words to be recognized.
    /// Ownership of the audio file passes to the caller.
    func finish() async -> (transcript: String, duration: TimeInterval, audioFileName: String?) {
        guard !isFinishing else {
            return (transcript, accumulated, audioFileName)
        }
        isFinishing = true
        systemResumeTask?.cancel()
        stopCheckpointing()

        if phase == .recording {
            accumulated += ProcessInfo.processInfo.systemUptime - (startedAt ?? ProcessInfo.processInfo.systemUptime)
            startedAt = nil
        }
        phase = .finishing
        stopTimers()
        sink.setTranscriber(nil)
        let duration = accumulated

        // Finalize the recognition session and wait for the tail. Ending the
        // audio input alone does not commit it.
        var text = ""
        if transcribes {
            text = await transcriber.finish()
        }

        let dropped = sink.droppedBufferCount()
        tearDownAudio()
        phase = .idle

        if sink.fileWriteFailed() {
            // Keep whatever was written - hours of audio are worth more than
            // a tidy error - and say so honestly.
            notice = transcribes
                ? L10n.text("The audio couldn't be saved to the end (the device may be out of space), but the transcript is complete.")
                : L10n.text("The audio couldn't be saved to the end. The device may be out of space.")
        } else if dropped > 0 {
            // A stall dropped some audio. That is a gap, not a dead file, and
            // saying so is better than an ominous silence.
            let seconds = max(1, Int((Double(dropped) * 4096 / 48_000).rounded()))
            notice = L10n.text("About \(seconds) seconds of audio were dropped because the device couldn't keep up. The transcript is unaffected.")
        }

        transcript = text
        elapsed = duration

        // Decide what to keep, now that the outcome is known.
        //
        // - Words recognized and the user didn't want audio: delete it, as
        //   asked. Transcription proved itself, so it was only insurance.
        // - No words and no sound ever reached the microphone: nothing to
        //   keep, and "check the microphone" is now a true statement.
        // - No words but there WAS sound: keep the audio whatever the
        //   preference. Deleting a three-minute meeting because the
        //   recognizer failed - and then telling the user their microphone
        //   was covered - is the one outcome this must never produce.
        let heardSomething = sink.peakLevelSoFar() > 0.03
        heardAudio = heardSomething
        if !text.isEmpty && !userWantsAudio {
            discardAudioFile()
        } else if text.isEmpty && !heardSomething {
            discardAudioFile()
        } else if text.isEmpty, audioFileName != nil, notice == nil {
            notice = L10n.text("No words were recognized, so the audio was saved instead.")
        }
        let fileName = audioFileName

        // One last checkpoint, deliberately left on disk. If the save that
        // follows fails, this is the only remaining copy of the transcript,
        // and the caller clears it once the recording is safely stored.
        writeCheckpoint()

        // The caller owns the file now; this service must never delete it.
        audioFileName = nil
        audioFileURL = nil
        isFinishing = false
        return (text, duration, fileName)
    }

    /// Throw the recording away without saving anything. Refused while
    /// `finish()` is in flight: the screen closing during that window would
    /// otherwise delete the recording the user just asked to save.
    func cancel() {
        guard !isFinishing else { return }
        systemResumeTask?.cancel()
        stopCheckpointing()
        RecordingStore.shared.clearCheckpoint()
        stopTimers()
        sink.setTranscriber(nil)
        transcriber.cancel()
        tearDownAudio()
        discardAudioFile()
        transcript = ""
        elapsed = 0
        accumulated = 0
        startedAt = nil
        recordingId = nil
        recordingStartedAtWallClock = nil
        reachedLimit = false
        preparingProgress = 0
        phase = .idle
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()

        let tick = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            let service = self
            Task { @MainActor in
                guard let self = service, self.phase == .recording else { return }
                self.level = self.sink.currentLevel()
                // Only count time the engine is actually capturing.
                guard self.audioEngine.isRunning else {
                    // Same recovery as a route change, and for the same
                    // reason: this tick often wins the race against the
                    // route-change notification, and when it did, the
                    // automatic recovery never ran - a phone face-down on a
                    // meeting table stayed paused for the rest of the hour.
                    self.recoverFromStoppedEngine()
                    return
                }
                self.elapsed = self.accumulated
                    + ProcessInfo.processInfo.systemUptime - (self.startedAt ?? ProcessInfo.processInfo.systemUptime)
                if self.elapsed >= Self.maximumDuration {
                    self.notice = L10n.text("This recording reached the four hour limit and was saved.")
                    self.reachedLimit = true
                    self.performPause()
                }
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick
    }

    private func stopTimers() {
        tickTimer?.invalidate(); tickTimer = nil
    }

    /// A notice must not hide the recording indicator forever.
    private func clearNoticeSoon() {
        noticeExpiry?.cancel()
        noticeExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - Audio plumbing

    @discardableResult
    private func installTap() throws -> AVAudioFormat {
        removeTap()
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A 0 Hz/0-channel format means no usable microphone (common in the
        // Simulator, or when another app holds the mic). Installing a tap
        // with it raises an exception.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecordingError.noMicrophone
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [sink] buffer, _ in
            sink.append(buffer)
        }
        didInstallTap = true
        tapFormat = format
        return format
    }

    private func removeTap() {
        guard didInstallTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        didInstallTap = false
        tapFormat = nil
    }

    private enum RecordingError: Error { case noMicrophone }

    private func prepareAudioFile(format: AVAudioFormat) {
        let name = "\(UUID().uuidString).m4a"
        let url = RecordingStore.audioURL(named: name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        // Built with the tap's own common format and interleaving so the
        // file's processing format matches the buffers by construction,
        // rather than by luck.
        guard let file = try? AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        ) else { return }
        sink.setFile(file)
        audioFileName = name
        audioFileURL = url
        audioFormat = format
        // `.completeUnlessOpen` and not `.complete`: the whole point of this
        // feature is recording while the screen is locked, and `.complete`
        // invalidates the open file handle seconds after the device locks.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path
        )
    }

    private func discardAudioFile() {
        sink.setFile(nil)
        if let audioFileURL {
            try? FileManager.default.removeItem(at: audioFileURL)
        }
        audioFileURL = nil
        audioFileName = nil
        audioFormat = nil
    }

    private func tearDownAudio() {
        stopTimers()
        sink.setTranscriber(nil)
        sink.setFile(nil)
        if audioEngine.isRunning { audioEngine.stop() }
        removeTap()
        level = 0
        deactivateSession()
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        sessionIsActive = true
    }

    private func deactivateSession() {
        guard sessionIsActive else { return }
        sessionIsActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Interruptions and hardware changes

    private func registerForAudioNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            // A Notification is not Sendable, so the single value that
            // matters is read here, on the delivery queue, and only that
            // crosses into the task.
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let service = self
            Task { @MainActor in service?.handleInterruption(type: raw, options: options) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            let service = self
            Task { @MainActor in service?.handleMediaServicesReset() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            let service = self
            Task { @MainActor in service?.handleRouteChange() }
        })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            let service = self
            Task { @MainActor in service?.handleRouteChange() }
        })
    }

    private func handleInterruption(type rawType: UInt?, options rawOptions: UInt?) {
        guard let raw = rawType,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if phase == .recording {
                performPause(releaseSession: false)
                pausedBySystem = true
                notice = L10n.text("Recording paused because another app needed the microphone. It will continue automatically.")
            }
        case .ended:
            // Only resume something the system paused - never a pause the
            // user chose, which in this app may well be deliberate privacy.
            //
            // `.shouldResume` is deliberately NOT required. iOS routinely
            // omits it for recording sessions after a phone call, and
            // honouring it literally meant a 90-minute meeting recorded five
            // minutes and then sat paused in someone's pocket.
            guard phase == .paused, pausedBySystem else { return }
            let shouldResume = rawOptions.map {
                AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume)
            } ?? false
            resumeAfterSystemPause(immediately: shouldResume)
        @unknown default:
            break
        }
    }

    /// Resume a system-initiated pause, retrying briefly.
    ///
    /// `setActive` often fails for a moment right after a call tears down,
    /// and one failed attempt used to end the recording for good.
    private func resumeAfterSystemPause(immediately: Bool) {
        systemResumeTask?.cancel()
        let wasSystemPause = pausedBySystem
        systemResumeTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            for attempt in 0..<4 {
                guard let self, !Task.isCancelled else { return }
                guard self.phase == .paused, wasSystemPause else { return }
                self.pausedBySystem = wasSystemPause
                self.resume()
                if self.phase == .recording { return }
                try? await Task.sleep(nanoseconds: UInt64(600_000_000 * (attempt + 1)))
            }
        }
    }

    /// Headphones unplugged, Bluetooth dropped, or the engine reconfigured:
    /// the tap's format is stale, so capture silently stops.
    ///
    /// Recovery is automatic. AirPods disconnect constantly - battery, range,
    /// going back in the case - and requiring a tap meant the phone lying
    /// face-down on a meeting table recorded nothing after the first
    /// disconnection, with a notice nobody was there to see.
    private func handleRouteChange() {
        guard phase == .recording else { return }
        let current = audioEngine.inputNode.outputFormat(forBus: 0)
        let formatChanged = current.sampleRate <= 0 || !current.isEqual(tapFormat ?? current)
        guard formatChanged || !audioEngine.isRunning else { return }
        recoverFromStoppedEngine()
    }

    /// Capture has stopped for a hardware reason. Rebuild the tap against the
    /// current device and carry on; only fall back to a paused state with a
    /// notice if that doesn't work.
    private func recoverFromStoppedEngine() {
        guard phase == .recording else { return }
        performPause()
        pausedBySystem = true
        resume()
        if phase == .recording {
            notice = L10n.text("The audio device changed. Recording continued.")
            clearNoticeSoon()
        } else {
            // Not attributable to an interruption, so an unrelated ".ended"
            // must not silently reopen the microphone.
            pausedBySystem = false
            notice = L10n.text("The audio device changed, so recording paused. Tap resume to continue.")
        }
        writeCheckpoint()
    }

    /// Media services died: every audio object is invalid and must be built
    /// again, or resume would start a dead engine and record silence.
    private func handleMediaServicesReset() {
        let wasRecording = phase == .recording
        let wasWritingAudio = sink.isWritingFile
        didInstallTap = false
        tapFormat = nil
        sessionIsActive = false
        stopTimers()
        // Stop feeding audio; the recognition session survives, so resuming
        // continues the same transcript.
        sink.setTranscriber(nil)
        // An AVAudioFile cannot be reopened for appending, so whatever was
        // written is all the audio this recording will have.
        sink.setFile(nil)
        if wasWritingAudio { audioFormat = nil }
        audioEngine = AVAudioEngine()
        if wasRecording {
            accumulated += ProcessInfo.processInfo.systemUptime - (startedAt ?? ProcessInfo.processInfo.systemUptime)
            startedAt = nil
            phase = .paused
            level = 0
        }
        if phase == .paused {
            pausedBySystem = false
            notice = wasWritingAudio
                ? L10n.text("The audio device changed, so only the transcript continues from here.")
                : L10n.text("Audio was interrupted, so recording paused. Tap resume to continue.")
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
