//
//  VoiceService.swift
//  AIGoodbye
//
//  Fully offline voice: on-device speech recognition (Apple Speech with
//  on-device mode) in, on-device text-to-speech out. Powers hands-free
//  voice conversations and spoken answers in live camera mode.
//
//  Nothing here touches the network: recognition is forced on-device, and
//  when a language's on-device recognizer isn't available, the feature says
//  so instead of quietly using a server.
//

import Foundation
import AVFoundation
import Speech
import Combine

/// Thread-safe level meter written from the audio render thread.
final class MicLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    func set(_ newValue: Double) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Double { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class VoiceService: NSObject, ObservableObject {

    enum ListeningState: Equatable {
        case idle
        case listening
        case unavailable(String)
    }

    @Published private(set) var listeningState: ListeningState = .idle
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var isSpeaking = false
    /// Audio level 0...1 for the listening indicator.
    @Published private(set) var micLevel: Double = 0

    /// Called when the user stops talking (silence endpoint) with final text.
    var onFinalTranscript: ((String) -> Void)?
    /// Called when the synthesizer finishes everything queued.
    var onFinishedSpeaking: (() -> Void)?
    /// Called when listening ended without a transcript (recognizer gave up,
    /// interruption, etc.) so the UI can recover instead of hanging.
    var onListeningEnded: (() -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var levelTimer: Timer?
    private var lastTranscriptChange = Date()
    private var didInstallTap = false
    private var sessionIsActive = false

    private let levelBox = MicLevelBox()

    private let synthesizer = AVSpeechSynthesizer()
    private var voiceLanguageCode = "en-US"
    private var pendingUtterances = 0
    private var speechWatchdog: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// How long a pause ends the user's turn.
    private let silenceEndpoint: TimeInterval = 1.4

    override init() {
        super.init()
        synthesizer.delegate = self
        registerForAudioNotifications()
    }

    // MARK: - Permissions

    static func requestPermissions() async -> Bool {
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { return false }
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        return speech
    }

    // MARK: - Language

    /// Locale for recognition given the app language setting.
    static func voiceLocale(for language: AppLanguage) -> Locale {
        if language == .automatic {
            return Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
        }
        return Locale(identifier: language.rawValue)
    }

    /// BCP-47 code for speech synthesis, mapped to codes iOS actually ships
    /// voices for (e.g. zh-Hans has no voice; zh-CN does).
    static func speechCode(for language: AppLanguage) -> String {
        let raw: String
        switch language {
        case .automatic:
            raw = Locale.preferredLanguages.first ?? "en-US"
        case .mandarin:
            raw = "zh-CN"
        case .cantonese:
            raw = "zh-HK"
        default:
            raw = language.rawValue
        }
        let bcp47 = raw.replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: "@")[0]

        // Prefer an installed voice whose language matches exactly, then by
        // language prefix, so "ru" finds "ru-RU".
        let voices = AVSpeechSynthesisVoice.speechVoices().map(\.language)
        if voices.contains(bcp47) { return bcp47 }
        let prefix = bcp47.components(separatedBy: "-")[0]
        if let match = voices.first(where: { $0.hasPrefix(prefix + "-") }) { return match }
        return AVSpeechSynthesisVoice.currentLanguageCode()
    }

    /// Whether fully offline recognition is possible for this locale.
    static func supportsOfflineRecognition(locale: Locale) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    // MARK: - Listening

    func startListening(language: AppLanguage) {
        stopSpeaking()
        stopListening(notify: false)

        let locale = Self.voiceLocale(for: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            listeningState = .unavailable(L10n.text("Voice recognition isn't available on this device."))
            return
        }
        guard recognizer.isAvailable else {
            listeningState = .unavailable(L10n.text("Voice recognition isn't available right now."))
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            listeningState = .unavailable(L10n.text("Offline voice recognition isn't available for this language yet."))
            return
        }
        self.recognizer = recognizer
        // Speak back in the app's language (recognition locale may differ if
        // the requested one is unsupported).
        voiceLanguageCode = Self.speechCode(for: language)

        do {
            try activateSession(for: .record)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true   // privacy: never a server
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            // A 0 Hz/0-channel format means no usable microphone (common in
            // the Simulator, or when another app holds the mic). Installing a
            // tap with it raises an exception - bail out gracefully instead.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                recognitionRequest = nil
                deactivateSession()
                listeningState = .unavailable(L10n.text("The microphone couldn't be started. Check that another app isn't using it."))
                return
            }

            // The tap runs on the real-time audio thread: it must NOT touch
            // main-actor state. Capture the request and a lock-protected
            // level box directly instead of `self`.
            let levelBox = self.levelBox
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [request] buffer, _ in
                request.append(buffer)
                if let channel = buffer.floatChannelData?[0] {
                    let frames = Int(buffer.frameLength)
                    var sum: Float = 0
                    for i in stride(from: 0, to: frames, by: 16) { sum += channel[i] * channel[i] }
                    let rms = sqrt(sum / Float(max(frames / 16, 1)))
                    levelBox.set(min(Double(rms) * 12, 1))
                }
            }
            didInstallTap = true

            audioEngine.prepare()
            try audioEngine.start()

            liveTranscript = ""
            lastTranscriptChange = Date()
            listeningState = .listening
            startTimers()

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        if text != self.liveTranscript {
                            self.liveTranscript = text
                            self.lastTranscriptChange = Date()
                        }
                        if result.isFinal {
                            self.finishListening()
                        }
                    }
                    if error != nil, self.listeningState == .listening {
                        // Recognizer gave up (e.g. long silence); treat as endpoint.
                        self.finishListening()
                    }
                }
            }
        } catch {
            cleanUpAudio()
            listeningState = .unavailable(L10n.text("The microphone couldn't be started. Check that another app isn't using it."))
        }
    }

    private func startTimers() {
        silenceTimer?.invalidate()
        let silence = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            let service = self
            Task { @MainActor in
                guard let self = service, self.listeningState == .listening else { return }
                let quiet = Date().timeIntervalSince(self.lastTranscriptChange)
                if !self.liveTranscript.isEmpty && quiet >= self.silenceEndpoint {
                    self.finishListening()
                }
            }
        }
        // .common so scrolling the transcript doesn't stall the endpoint.
        RunLoop.main.add(silence, forMode: .common)
        silenceTimer = silence

        levelTimer?.invalidate()
        let level = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            let service = self
            Task { @MainActor in
                guard let service else { return }
                service.micLevel = service.levelBox.get()
            }
        }
        RunLoop.main.add(level, forMode: .common)
        levelTimer = level
    }

    /// Ends the turn and delivers the final transcript.
    private func finishListening() {
        guard listeningState == .listening else { return }
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopListening(notify: false)
        if !text.isEmpty {
            onFinalTranscript?(text)
        } else {
            // Nothing was said: let the UI recover instead of hanging.
            onListeningEnded?()
        }
    }

    func stopListening(notify: Bool = true) {
        let wasListening = listeningState == .listening
        cleanUpAudio()
        if wasListening {
            listeningState = .idle
            if notify { onListeningEnded?() }
        }
    }

    /// Tear down recognition + audio graph. Safe to call repeatedly.
    private func cleanUpAudio() {
        silenceTimer?.invalidate(); silenceTimer = nil
        levelTimer?.invalidate(); levelTimer = nil
        recognitionTask?.cancel(); recognitionTask = nil
        recognitionRequest?.endAudio(); recognitionRequest = nil
        if audioEngine.isRunning { audioEngine.stop() }
        if didInstallTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            didInstallTap = false
        }
        micLevel = 0
        levelBox.set(0)
        if !isSpeaking { deactivateSession() }
    }

    // MARK: - Audio session

    private func activateSession(for use: SessionUse) throws {
        let session = AVAudioSession.sharedInstance()
        switch use {
        case .record:
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.defaultToSpeaker, .duckOthers, .allowBluetoothHFP])
        case .playback:
            try session.setCategory(.playback, mode: .spokenAudio,
                                    options: [.duckOthers])
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        sessionIsActive = true
    }

    private func deactivateSession() {
        guard sessionIsActive else { return }
        sessionIsActive = false
        // Deactivating can throw if audio is still winding down; harmless.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private enum SessionUse { case record, playback }

    // MARK: - Interruptions and route changes

    private func registerForAudioNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            // A Notification is not Sendable, so the single value that
            // matters is read here, on the delivery queue, and only that
            // crosses into the task.
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let service = self
            Task { @MainActor in service?.handleInterruption(raw) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            let service = self
            Task { @MainActor in service?.handleRouteChange() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Keep the callbacks: the screen can recover by listening again.
            let service = self
            Task { @MainActor in service?.pause() }
        })
    }

    private func removeAudioObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func handleInterruption(_ rawType: UInt?) {
        guard let raw = rawType,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // Phone call, Siri, etc. Stop cleanly and let the UI re-arm.
            stopSpeaking()
            stopListening()
        default:
            break
        }
    }

    private func handleRouteChange() {
        // The tap format is tied to the previous route; restart cleanly and
        // let the UI decide whether to listen again.
        if listeningState == .listening {
            stopListening()
        }
    }

    // MARK: - Speaking

    /// Queue text to be spoken with the on-device voice for the language.
    /// Returns false when there was nothing speakable, so a hands-free
    /// caller waiting on `onFinishedSpeaking` doesn't wait forever.
    @discardableResult
    func speak(_ text: String) -> Bool {
        let spoken = Self.plainSpeech(from: text)
        guard !spoken.isEmpty else { return false }

        // Never let the microphone be live while the speaker is: the
        // recognizer would transcribe our own voice and loop forever.
        if listeningState == .listening {
            stopListening(notify: false)
        }

        if !sessionIsActive {
            try? activateSession(for: .playback)
        }

        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = AVSpeechSynthesisVoice(language: voiceLanguageCode)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        pendingUtterances += 1
        isSpeaking = true
        synthesizer.speak(utterance)
        armSpeechWatchdog(for: spoken)
        return true
    }

    /// Configure the speaking language without listening first (camera mode).
    func setSpeechLanguage(_ language: AppLanguage) {
        voiceLanguageCode = Self.speechCode(for: language)
    }

    func stopSpeaking() {
        speechWatchdog?.cancel(); speechWatchdog = nil
        pendingUtterances = 0
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if isSpeaking {
            isSpeaking = false
            if listeningState != .listening { deactivateSession() }
        }
    }

    /// If a `didFinish` callback is ever lost (interruption, session going
    /// inactive), don't strand the conversation on "Speaking" forever.
    private func armSpeechWatchdog(for text: String) {
        speechWatchdog?.cancel()
        // Rough upper bound: ~12 characters per second, plus slack.
        let seconds = max(6.0, Double(text.count) / 12.0 + 5.0)
        speechWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isSpeaking,
                  !self.synthesizer.isSpeaking else { return }
            self.pendingUtterances = 0
            self.isSpeaking = false
            self.onFinishedSpeaking?()
        }
    }

    /// Stop all audio but KEEP the callbacks, so the owning screen can
    /// resume (e.g. after the app returns from the background).
    func pause() {
        speechWatchdog?.cancel(); speechWatchdog = nil
        pendingUtterances = 0
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
        cleanUpAudio()
        listeningState = .idle
        deactivateSession()
    }

    /// Permanent teardown: stops audio and drops the callbacks (breaking any
    /// reference cycle with the presenting view). Only call when the screen
    /// is going away for good.
    func shutdown() {
        pause()
        onFinalTranscript = nil
        onFinishedSpeaking = nil
        onListeningEnded = nil
        removeAudioObservers()
    }

    // MARK: - Markdown to speech

    /// Strip Markdown so the synthesizer doesn't read "pound pound",
    /// "asterisk", or entire code blocks aloud.
    nonisolated static func plainSpeech(from text: String) -> String {
        var result = ""
        var inFence = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                if inFence { result += L10n.text("Code block.") + " " }
                continue
            }
            if inFence { continue }

            var cleaned = trimmed
            // Headings and list markers.
            while cleaned.hasPrefix("#") { cleaned.removeFirst() }
            if cleaned.hasPrefix("- ") || cleaned.hasPrefix("* ") || cleaned.hasPrefix("+ ") {
                cleaned = String(cleaned.dropFirst(2))
            }
            // Table pipes and emphasis/inline-code markers.
            cleaned = cleaned.replacingOccurrences(of: "|", with: " ")
            cleaned = cleaned.replacingOccurrences(of: "**", with: "")
            cleaned = cleaned.replacingOccurrences(of: "__", with: "")
            cleaned = cleaned.replacingOccurrences(of: "`", with: "")
            cleaned = cleaned.replacingOccurrences(of: "*", with: "")
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            if cleaned.isEmpty { continue }
            result += cleaned + (cleaned.hasSuffix(".") ? " " : ". ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Synthesizer delegate

extension VoiceService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            pendingUtterances = max(pendingUtterances - 1, 0)
            if pendingUtterances == 0 {
                speechWatchdog?.cancel()
                speechWatchdog = nil
                isSpeaking = false
                if listeningState != .listening { deactivateSession() }
                onFinishedSpeaking?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            pendingUtterances = 0
            speechWatchdog?.cancel()
            speechWatchdog = nil
            isSpeaking = false
        }
    }
}

// MARK: - Sentence chunking for streaming speech

enum SpeechChunker {
    /// Boundary characters that end a speakable sentence (Latin + CJK).
    private static let boundaries: Set<Character> = [".", "!", "?", "\n", "。", "！", "？", "…"]

    /// Returns the range of text (from `start`) that forms complete
    /// sentences, or nil if no boundary has streamed in yet.
    static func speakableSlice(of text: String, from start: String.Index) -> Range<String.Index>? {
        guard start < text.endIndex else { return nil }
        var lastBoundary: String.Index?
        var index = start
        while index < text.endIndex {
            if boundaries.contains(text[index]) {
                lastBoundary = index
            }
            index = text.index(after: index)
        }
        guard let boundary = lastBoundary else { return nil }
        let end = text.index(after: boundary)
        // Avoid speaking tiny fragments like "1." mid-list.
        if text.distance(from: start, to: end) < 12 { return nil }
        return start..<end
    }
}
