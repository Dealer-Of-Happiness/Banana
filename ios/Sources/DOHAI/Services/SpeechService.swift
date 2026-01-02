//
//  SpeechService.swift
//  DOH AI
//
//  Text-to-speech service with multi-language support
//

import AVFoundation
import Foundation
import Combine
import UIKit

class SpeechService: NSObject, ObservableObject {
    private var settings: SettingsManager?
    private let synthesizer = AVSpeechSynthesizer()

    @Published var isSpeaking = false

    override init() {
        super.init()
    }

    convenience init(settings: SettingsManager) {
        self.init()
        self.settings = settings
        synthesizer.delegate = self
    }

    // MARK: - Speak Text

    func speak(_ text: String, language: SupportedLanguage? = nil) {
        stop()

        let lang = language ?? settings?.outputLanguage ?? .english
        let utterance = AVSpeechUtterance(string: text)

        utterance.voice = AVSpeechSynthesisVoice(language: lang.speechRecognitionLocale)
        utterance.rate = Float(settings?.speechRate ?? 1.0) * AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        // Configure audio session
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        synthesizer.speak(utterance)
        isSpeaking = true

        // Haptic feedback if enabled
        if settings?.hapticFeedbackEnabled ?? false {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    // MARK: - Available Voices

    static func availableVoices(for language: SupportedLanguage) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.starts(with: language.rawValue)
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }
}
