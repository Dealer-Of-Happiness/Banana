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

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var lastTranscriptChange = Date()

    private let synthesizer = AVSpeechSynthesizer()
    private var voiceLanguageCode = "en-US"
    private var pendingUtterances = 0

    /// How long a pause ends the user's turn.
    private let silenceEndpoint: TimeInterval = 1.4

    override init() {
        super.init()
        synthesizer.delegate = self
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

    /// Locale for recognition/speech given the app language setting.
    static func voiceLocale(for language: AppLanguage) -> Locale {
        if language == .automatic { return Locale.current }
        return Locale(identifier: language.rawValue)
    }

    /// Whether fully offline recognition is possible for this locale.
    static func supportsOfflineRecognition(locale: Locale) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    // MARK: - Listening

    func startListening(language: AppLanguage) {
        stopSpeaking()
        stopListening()

        let locale = Self.voiceLocale(for: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
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
        voiceLanguageCode = locale.identifier

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.defaultToSpeaker, .duckOthers, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

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
                listeningState = .unavailable(L10n.text("The microphone couldn't be started. Check that another app isn't using it."))
                return
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
                // Cheap RMS level for the UI.
                if let channel = buffer.floatChannelData?[0] {
                    let frames = Int(buffer.frameLength)
                    var sum: Float = 0
                    for i in stride(from: 0, to: frames, by: 16) { sum += channel[i] * channel[i] }
                    let rms = sqrt(sum / Float(max(frames / 16, 1)))
                    Task { @MainActor in
                        self?.micLevel = min(Double(rms) * 12, 1)
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()

            liveTranscript = ""
            lastTranscriptChange = Date()
            listeningState = .listening
            startSilenceTimer()

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
            listeningState = .unavailable(L10n.text("The microphone couldn't be started. Check that another app isn't using it."))
            stopListening()
        }
    }

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.listeningState == .listening else { return }
                let quiet = Date().timeIntervalSince(self.lastTranscriptChange)
                if !self.liveTranscript.isEmpty && quiet >= self.silenceEndpoint {
                    self.finishListening()
                }
            }
        }
    }

    /// Ends the turn and delivers the final transcript.
    private func finishListening() {
        guard listeningState == .listening else { return }
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopListening()
        if !text.isEmpty {
            onFinalTranscript?(text)
        }
    }

    func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        micLevel = 0
        if listeningState == .listening { listeningState = .idle }
    }

    // MARK: - Speaking

    /// Queue text to be spoken with the on-device voice for the language.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: voiceLanguageCode)
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        pendingUtterances += 1
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Configure the speaking language without listening first (camera mode).
    func setSpeechLanguage(_ language: AppLanguage) {
        voiceLanguageCode = Self.voiceLocale(for: language).identifier
    }

    func stopSpeaking() {
        pendingUtterances = 0
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    func shutdown() {
        stopListening()
        stopSpeaking()
        listeningState = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Synthesizer delegate

extension VoiceService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            pendingUtterances = max(pendingUtterances - 1, 0)
            if pendingUtterances == 0 {
                isSpeaking = false
                onFinishedSpeaking?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            pendingUtterances = 0
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
