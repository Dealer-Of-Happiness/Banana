//
//  VoiceAIService.swift
//  AIGoodbye
//
//  Text-to-Speech service for AI voice responses
//

import Foundation
import AVFoundation
import Combine

@MainActor
class VoiceAIService: NSObject, ObservableObject {
    static let shared = VoiceAIService()

    @Published var isSpeaking = false
    @Published var isEnabled = true
    @Published var selectedVoice: AVSpeechSynthesisVoice?
    @Published var speechRate: Float = 0.5 // 0.0 - 1.0
    @Published var speechPitch: Float = 1.0 // 0.5 - 2.0
    @Published var availableVoices: [VoiceOption] = []

    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?

    override private init() {
        super.init()
        synthesizer.delegate = self
        loadAvailableVoices()
        loadPreferences()
    }

    // MARK: - Voice Options

    struct VoiceOption: Identifiable, Hashable {
        let id: String
        let name: String
        let language: String
        let quality: Quality
        let voice: AVSpeechSynthesisVoice

        enum Quality: String {
            case enhanced = "Enhanced"
            case standard = "Standard"
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: VoiceOption, rhs: VoiceOption) -> Bool {
            lhs.id == rhs.id
        }
    }

    private func loadAvailableVoices() {
        let voices = AVSpeechSynthesisVoice.speechVoices()

        // Filter for English voices, remove duplicates by name, and sort by quality
        var seenNames: Set<String> = []
        availableVoices = voices
            .filter { $0.language.starts(with: "en") }
            .filter { voice in
                // Only keep first occurrence of each voice name
                if seenNames.contains(voice.name) {
                    return false
                }
                seenNames.insert(voice.name)
                return true
            }
            .map { voice in
                let quality: VoiceOption.Quality = voice.quality == .enhanced ? .enhanced : .standard
                return VoiceOption(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    quality: quality,
                    voice: voice
                )
            }
            .sorted { ($0.quality == .enhanced ? 0 : 1) < ($1.quality == .enhanced ? 0 : 1) }

        // Set default voice
        if selectedVoice == nil {
            // Prefer Samantha (enhanced) or default English
            selectedVoice = voices.first { $0.name.contains("Samantha") && $0.quality == .enhanced }
                ?? voices.first { $0.language == "en-US" && $0.quality == .enhanced }
                ?? voices.first { $0.language == "en-US" }
        }
    }

    private func loadPreferences() {
        if let voiceId = UserDefaults.standard.string(forKey: "voiceAI.voiceId"),
           let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            selectedVoice = voice
        }

        if UserDefaults.standard.object(forKey: "voiceAI.rate") != nil {
            speechRate = UserDefaults.standard.float(forKey: "voiceAI.rate")
        }

        if UserDefaults.standard.object(forKey: "voiceAI.pitch") != nil {
            speechPitch = UserDefaults.standard.float(forKey: "voiceAI.pitch")
        }

        isEnabled = UserDefaults.standard.bool(forKey: "voiceAI.enabled")
    }

    func savePreferences() {
        UserDefaults.standard.set(selectedVoice?.identifier, forKey: "voiceAI.voiceId")
        UserDefaults.standard.set(speechRate, forKey: "voiceAI.rate")
        UserDefaults.standard.set(speechPitch, forKey: "voiceAI.pitch")
        UserDefaults.standard.set(isEnabled, forKey: "voiceAI.enabled")
    }

    // MARK: - Speech Control

    func speak(_ text: String) {
        guard isEnabled else { return }

        // Stop any current speech
        stop()

        // Configure audio session
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }

        // Create utterance
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = selectedVoice ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * speechRate
        utterance.pitchMultiplier = speechPitch
        utterance.preUtteranceDelay = 0.1
        utterance.postUtteranceDelay = 0.1

        currentUtterance = utterance
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        currentUtterance = nil
    }

    func pause() {
        if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
        }
    }

    func resume() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
        }
    }

    func toggle() {
        if synthesizer.isSpeaking {
            stop()
        } else if let text = currentUtterance?.speechString {
            speak(text)
        }
    }

    // MARK: - Voice Selection

    func selectVoice(_ option: VoiceOption) {
        selectedVoice = option.voice
        savePreferences()
    }

    var currentVoiceName: String {
        selectedVoice?.name ?? "Default"
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceAIService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.currentUtterance = nil

            // Deactivate audio session
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.currentUtterance = nil
        }
    }
}
