//
//  VoiceService.swift
//  AIGoodbye
//
//  Fully offline voice: on-device speech recognition in (the same
//  `Transcriber` the recorder uses: SpeechAnalyzer on iOS 26, the older
//  on-device recognizer where it isn't available), on-device text-to-speech
//  out. Powers hands-free voice conversations, the translator, and spoken
//  answers in live camera mode.
//
//  Nothing here touches the network: recognition is on-device only, and
//  when a language's on-device recognizer isn't available, the feature says
//  so instead of quietly using a server.
//

import Foundation
import AVFoundation
import AudioToolbox
import Speech
import Combine
import UIKit

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
        /// The speech engine is being readied. On the first use of a
        /// language this can include downloading its model.
        case preparing
        case listening
        case unavailable(String)
    }

    @Published private(set) var listeningState: ListeningState = .idle
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var isSpeaking = false
    /// Audio level 0...1 for the listening indicator.
    @Published private(set) var micLevel: Double = 0
    /// 0...1 while a speech model downloads during `.preparing`.
    @Published private(set) var preparingProgress: Double = 0

    /// Called when the user stops talking (silence endpoint) with final text.
    var onFinalTranscript: ((String) -> Void)?
    /// Called when the synthesizer finishes everything queued.
    var onFinishedSpeaking: (() -> Void)?
    /// Called when listening ended without a transcript (recognizer gave up,
    /// interruption, etc.) so the UI can recover instead of hanging.
    var onListeningEnded: (() -> Void)?
    /// Called, on the main actor, when speech in progress was cut off by an
    /// audio-session interruption (phone call, Siri, alarm) or a media
    /// services reset. The synthesizer never reports an utterance it was
    /// stopped from finishing, so without this the owning screen sat on
    /// "Speaking" forever with nothing playing. `onFinishedSpeaking` is NOT
    /// called in this case.
    var onSpeechInterrupted: (() -> Void)?

    /// Play the system begin/end-recording tones when the microphone opens
    /// and closes. Set by the owning screen from `settings.listeningSounds`;
    /// the service deliberately doesn't reach into app state itself.
    var playsListeningSounds = false

    /// Speaking rate for everything this service says. Set by the owning
    /// screen from `settings.speechRate`; blind and low-vision users often
    /// listen far faster than the default.
    var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate

    /// `var`, not `let`: after a media-services reset every audio object is
    /// invalid and the engine has to be built again, or every later start
    /// throws for the rest of the screen's life.
    private var audioEngine = AVAudioEngine()
    /// The same engine the recorder uses: SpeechAnalyzer on iOS 26, the
    /// older recognizer for languages it doesn't cover. One speech stack,
    /// one set of fixes.
    private let transcriber = Transcriber()
    /// Identifies the current `startListening`. A start that was stopped or
    /// superseded while it was still preparing must not go live later.
    private var listenGeneration = 0
    private var startTask: Task<Void, Never>?
    private var silenceTimer: Timer?
    private var levelTimer: Timer?
    private var lastTranscriptChange = Date()
    private var listenStartedAt = Date()
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
    /// How long to listen to silence before ending an empty turn.
    private let emptyListenLimit: TimeInterval = 30

    override init() {
        super.init()
        synthesizer.delegate = self
        registerForAudioNotifications()
    }

    // MARK: - Permissions

    /// Only the microphone is asked for here. Where the speech engine in use
    /// needs the older recognizer's authorization, the transcriber asks for
    /// it itself, at the moment it is needed - and never on the modern
    /// engine, whose system dialog would claim speech is sent to Apple.
    static func requestPermissions() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
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

    // MARK: - Listening

    /// Whether a listen is under way in any form: readying the engine or
    /// actually hearing the user.
    var isListeningOrPreparing: Bool {
        listeningState == .listening || listeningState == .preparing
    }

    /// Start listening for one turn. Asynchronous by nature - the first use
    /// of a language may download its speech model - so the result arrives
    /// through `listeningState`: `.listening` when the microphone is live,
    /// `.unavailable` with a reason the screen can show when it is not.
    func startListening(language: AppLanguage) {
        stopSpeaking()
        stopListening(notify: false)

        listenGeneration += 1
        let generation = listenGeneration
        let locale = Self.voiceLocale(for: language)
        // Speak back in the app's language (recognition locale may differ if
        // the requested one is unsupported).
        voiceLanguageCode = Self.speechCode(for: language)
        liveTranscript = ""
        preparingProgress = 0
        listeningState = .preparing

        // Starts are serialized. Two overlapping starts on one transcriber
        // would race for its input stream; the second waits for the first to
        // settle, and by then the generation check makes the first a no-op.
        let previous = startTask
        startTask = Task { [weak self] in
            await previous?.value
            guard let self, generation == self.listenGeneration else { return }
            await self.goLive(locale: locale, generation: generation)
        }
    }

    private func goLive(locale: Locale, generation: Int) async {
        transcriber.onInstallProgress = { [weak self] fraction in
            self?.preparingProgress = fraction
        }
        let engine = await transcriber.prepare(locale: locale)
        guard generation == listenGeneration, listeningState == .preparing else { return }

        guard engine != .none else {
            let reason = Transcriber.legacyRecognitionDenied
                ? L10n.text("Speech recognition is turned off for AiGoodbye. You can turn it on in the Settings app.")
                : L10n.text("Offline voice recognition isn't available for this language yet. Adding the language under Settings > General > Keyboard > Dictation Languages usually enables it.")
            listeningState = .unavailable(reason)
            return
        }

        transcriber.onText = { [weak self] text in
            self?.transcriptChanged(text, generation: generation)
        }
        transcriber.onRecognitionFailed = { [weak self] in
            self?.recognitionFailed(generation: generation)
        }

        do {
            try activateSession(for: .record)

            // A 0 Hz/0-channel format means no usable microphone (common in
            // the Simulator, or when another app holds the mic). Checked
            // before the speech engine is started, so a dead microphone
            // fails fast rather than after a model load.
            guard usableInputFormat() != nil else {
                failStart()
                return
            }

            try await transcriber.start(locale: locale)
            // Stopped or restarted while the engine was starting: whoever did
            // that owns the audio graph now.
            guard generation == listenGeneration, listeningState == .preparing else { return }

            // The tap is installed only NOW, right before the engine starts,
            // with the format read at this moment. Starting the speech
            // engine above takes hundreds of milliseconds (seconds on a
            // language's first use), and AirPods connecting in that window
            // change the hardware format; starting the engine with a tap in
            // the old format raises an AVFoundation exception - a crash, not
            // a Swift error. Installing a tap with a 0 Hz format raises too,
            // hence the second check.
            guard let format = usableInputFormat() else {
                failStart()
                return
            }

            // The tap runs on the real-time audio thread: it must NOT touch
            // main-actor state. It hands the buffer straight to the
            // transcriber (which converts and queues it there and then, as
            // the buffer dies with the callback) and to a lock-protected
            // level box.
            let levelBox = self.levelBox
            let transcriber = self.transcriber
            audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                transcriber.append(buffer)
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

            lastTranscriptChange = Date()
            listenStartedAt = Date()
            listeningState = .listening
            startTimers()
            // The moment the microphone is really live, not when the listen
            // was asked for: eyes-off (walking, a phone on the table, a blind
            // user) this tone is the only way to know when to start talking.
            playListeningSound(Self.beginListeningSound)
        } catch {
            guard generation == listenGeneration else { return }
            failStart()
        }
    }

    /// The microphone's current format, or nil when there is no usable input.
    private func usableInputFormat() -> AVAudioFormat? {
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        return format
    }

    /// Abandon a start that cannot go live and tell the screen why.
    private func failStart() {
        cleanUpAudio()
        listeningState = .unavailable(L10n.text("The microphone couldn't be started. Check that another app isn't using it."))
    }

    private func transcriptChanged(_ text: String, generation: Int) {
        guard generation == listenGeneration, listeningState == .listening else { return }
        if text != liveTranscript {
            liveTranscript = text
            lastTranscriptChange = Date()
        }
    }

    /// The engine died mid-turn. With words in hand, that is simply the end
    /// of the turn; with none, it is an error the user must see. It used to
    /// be treated as "the user stopped talking" either way, which sent voice
    /// mode and the translator quietly back to idle with no explanation -
    /// the whole feature looked dead.
    private func recognitionFailed(generation: Int) {
        guard generation == listenGeneration, listeningState == .listening else { return }
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            finishListening()
            return
        }
        cleanUpAudio()
        listeningState = .unavailable(L10n.text("Speech recognition stopped before anything was heard. Tap to try again."))
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
                } else if self.liveTranscript.isEmpty,
                          Date().timeIntervalSince(self.listenStartedAt) >= self.emptyListenLimit {
                    // Nothing said at all. The old recognizer used to give
                    // up on its own after a while; the modern engine will
                    // listen to silence forever, so the turn is ended here.
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

    /// "Tap to send": end the user's turn now instead of waiting for the
    /// pause. What was heard so far is delivered through
    /// `onFinalTranscript`; with nothing heard (or the engine still getting
    /// ready) the listen simply ends through `onListeningEnded`. Tapping the
    /// lit microphone used to call `stopListening`, which threw the sentence
    /// away and made the speaker say it all again.
    func finishListeningNow() {
        switch listeningState {
        case .listening:
            finishListening()
        case .preparing:
            stopListening(notify: true)
        case .idle, .unavailable:
            break
        }
    }

    /// Ends the turn and delivers the final transcript.
    private func finishListening() {
        guard listeningState == .listening else { return }
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopListening(notify: false)
        // "Heard you, the microphone is closed" - before the answer starts.
        playListeningSound(Self.endListeningSound)
        if !text.isEmpty {
            onFinalTranscript?(text)
        } else {
            // Nothing was said: let the UI recover instead of hanging.
            onListeningEnded?()
        }
    }

    func stopListening(notify: Bool = true) {
        let wasListening = isListeningOrPreparing
        // Any start still in flight must not go live after this.
        listenGeneration += 1
        cleanUpAudio()
        if wasListening {
            listeningState = .idle
            if notify { onListeningEnded?() }
        }
    }

    /// The system's own begin/end dictation tones, so they sound like the
    /// rest of iOS rather than something the app invented.
    private static let beginListeningSound: SystemSoundID = 1113
    private static let endListeningSound: SystemSoundID = 1114

    private func playListeningSound(_ sound: SystemSoundID) {
        guard playsListeningSounds else { return }
        AudioServicesPlaySystemSound(sound)
    }

    /// Tear down recognition + audio graph. Safe to call repeatedly.
    private func cleanUpAudio() {
        silenceTimer?.invalidate(); silenceTimer = nil
        levelTimer?.invalidate(); levelTimer = nil
        transcriber.cancel()
        if audioEngine.isRunning { audioEngine.stop() }
        if didInstallTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            didInstallTap = false
        }
        micLevel = 0
        levelBox.set(0)
        preparingProgress = 0
        if !isSpeaking { deactivateSession() }
    }

    // MARK: - Audio session

    private func activateSession(for use: SessionUse) throws {
        let session = AVAudioSession.sharedInstance()
        switch use {
        case .record:
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.defaultToSpeaker, .duckOthers, .allowBluetoothHFP])
            // iOS mutes system sounds and haptics while an app records, which
            // would swallow the listening tones and the screens' haptics at
            // exactly the moments they exist for. Best effort.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
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
        ) { [weak self] note in
            // Same as above: only the reason crosses into the task.
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let service = self
            Task { @MainActor in service?.handleRouteChange(raw) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Keep the callbacks: the screen can recover by listening again.
            let service = self
            Task { @MainActor in service?.handleMediaServicesReset() }
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
            // `stopSpeaking` suppresses the synthesizer's callbacks and the
            // watchdog, so the owner is told separately that its speech was
            // cut off - otherwise voice mode sat on "Speaking" for good and
            // hands-free translate never listened again.
            let wasSpeaking = isSpeaking
            stopSpeaking()
            stopListening()
            if wasSpeaking { onSpeechInterrupted?() }
        default:
            break
        }
    }

    private func handleRouteChange(_ rawReason: UInt?) {
        guard let raw = rawReason,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Only a device coming or going. Every category switch this service
        // makes itself (.playback to speak, .playAndRecord to listen) and
        // every activation posts a route change too, and acting on those
        // killed each hands-free listen as it started - with AirPods, every
        // listen, because the A2DP-to-HFP switch posts yet another one.
        guard reason == .oldDeviceUnavailable || reason == .newDeviceAvailable else { return }
        // Never kill a start in flight. The tap is installed with the format
        // read immediately before the engine starts, so a change before
        // that point costs nothing.
        guard listeningState == .listening else { return }
        // The tap's format belongs to the old route, so the engine has to be
        // rebuilt. What was already heard is delivered, not dropped.
        if !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishListening()
        } else {
            stopListening()
        }
    }

    /// Media services died: every audio object is invalid. The engine is
    /// built again - a start on the old one throws for the rest of the
    /// screen's life - and the screen is told, so it leaves "Listening".
    private func handleMediaServicesReset() {
        let wasSpeaking = isSpeaking
        speechWatchdog?.cancel(); speechWatchdog = nil
        pendingUtterances = 0
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
        // The old engine and its tap died with the services; forget them
        // rather than poke at them. The session is gone too.
        didInstallTap = false
        sessionIsActive = false
        audioEngine = AVAudioEngine()
        // Notifies the screen if a listen was under way, so it does not stay
        // on "Listening" with no microphone.
        stopListening()
        if wasSpeaking { onSpeechInterrupted?() }
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
        if isListeningOrPreparing {
            stopListening(notify: false)
        }

        if !sessionIsActive {
            try? activateSession(for: .playback)
        }

        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = AVSpeechSynthesisVoice(language: voiceLanguageCode)
        utterance.rate = min(max(speechRate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        // A VoiceOver user has usually spent years tuning VoiceOver's voice
        // and rate; when it is running, those win over ours, so the app does
        // not suddenly speak in a different, slower voice.
        if UIAccessibility.isVoiceOverRunning {
            utterance.prefersAssistiveTechnologySettings = true
        }
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
        listenGeneration += 1
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
        onSpeechInterrupted = nil
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
            // Before the marker stripping below: an address can contain "*"
            // or "__", and the link syntax needs its brackets intact.
            cleaned = speakableLinks(in: cleaned)
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

    /// "[the guide](https://...)" is read as "the guide", and a bare address
    /// as the word "link" - spelling one out ("h t t p s colon slash
    /// slash...") took ten seconds of every answer that contained one.
    nonisolated private static func speakableLinks(in line: String) -> String {
        guard line.contains("](") || line.contains("://") else { return line }
        // Markdown links and images: keep the label (or alt text).
        var result = line.replacingOccurrences(
            of: #"!?\[([^\]]*)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        // Bare and <angle-bracketed> addresses. Escaped, because a
        // translated word is used as a regex replacement template.
        let word = NSRegularExpression.escapedTemplate(for: L10n.text("link"))
        result = result.replacingOccurrences(
            of: #"<?https?://[^\s<>)\]]+>?"#,
            with: word,
            options: [.regularExpression, .caseInsensitive]
        )
        return result
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
            let next = text.index(after: index)
            if boundaries.contains(text[index]), endsSentence(text, at: index, next: next) {
                lastBoundary = index
            }
            index = next
        }
        guard let boundary = lastBoundary else { return nil }
        let end = text.index(after: boundary)
        // Avoid speaking tiny fragments like "1." mid-list.
        if text.distance(from: start, to: end) < 12 { return nil }
        return start..<end
    }

    /// A Latin full stop ends a sentence only when whitespace follows it.
    /// Without the look-ahead a snapshot ending in "costs 3." was spoken
    /// before "5 dollars" streamed in ("three. five dollars"), and decimals
    /// like "3.14" split the same way. A full stop at the very end of the text
    /// waits for the next snapshot - or for the end of the answer, whose
    /// remainder the caller speaks anyway. "。" and the other marks never
    /// appear inside numbers, so they need no look-ahead (and CJK text has
    /// no space after "。" to look for).
    private static func endsSentence(_ text: String, at index: String.Index, next: String.Index) -> Bool {
        guard text[index] == "." else { return true }
        guard next < text.endIndex else { return false }
        return text[next].isWhitespace
    }
}
