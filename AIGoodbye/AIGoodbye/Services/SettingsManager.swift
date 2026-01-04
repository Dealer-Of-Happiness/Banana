//
//  SettingsManager.swift
//  AIGoodbye
//
//  Centralized settings management with persistence
//

import Foundation
import SwiftUI
import Combine

class SettingsManager: ObservableObject {
    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let temperature = "ai_temperature"
        static let contextWindow = "ai_context_window"
        static let inputLanguage = "input_language"
        static let outputLanguage = "output_language"
        static let hapticFeedback = "haptic_feedback"
        static let voiceInputMode = "voice_input_mode"
        static let speechRate = "speech_rate"
        static let iCloudSync = "icloud_sync"
        static let chatGPTEnabled = "chatgpt_enabled"
        static let claudeEnabled = "claude_enabled"
        static let googleEnabled = "google_enabled"
    }

    // MARK: - AI Settings

    @Published var temperature: Double {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }

    @Published var contextWindow: Int {
        didSet { defaults.set(contextWindow, forKey: Keys.contextWindow) }
    }

    // MARK: - Language Settings

    @Published var inputLanguage: SupportedLanguage {
        didSet { defaults.set(inputLanguage.rawValue, forKey: Keys.inputLanguage) }
    }

    @Published var outputLanguage: SupportedLanguage {
        didSet { defaults.set(outputLanguage.rawValue, forKey: Keys.outputLanguage) }
    }

    // MARK: - Voice Settings

    @Published var hapticFeedbackEnabled: Bool {
        didSet { defaults.set(hapticFeedbackEnabled, forKey: Keys.hapticFeedback) }
    }

    @Published var voiceInputMode: VoiceInputMode {
        didSet { defaults.set(voiceInputMode.rawValue, forKey: Keys.voiceInputMode) }
    }

    @Published var speechRate: Double {
        didSet { defaults.set(speechRate, forKey: Keys.speechRate) }
    }

    // MARK: - Cloud Settings

    @Published var chatGPTEnabled: Bool {
        didSet { defaults.set(chatGPTEnabled, forKey: Keys.chatGPTEnabled) }
    }

    @Published var claudeEnabled: Bool {
        didSet { defaults.set(claudeEnabled, forKey: Keys.claudeEnabled) }
    }

    @Published var googleEnabled: Bool {
        didSet { defaults.set(googleEnabled, forKey: Keys.googleEnabled) }
    }

    // MARK: - Data Settings

    @Published var iCloudSyncEnabled: Bool {
        didSet { defaults.set(iCloudSyncEnabled, forKey: Keys.iCloudSync) }
    }

    // MARK: - Secure Storage (API Keys)

    var chatGPTApiKey: String? {
        get { KeychainHelper.load(key: "chatgpt_api_key") }
        set {
            if let value = newValue {
                KeychainHelper.save(key: "chatgpt_api_key", value: value)
            } else {
                KeychainHelper.delete(key: "chatgpt_api_key")
            }
        }
    }

    var claudeApiKey: String? {
        get { KeychainHelper.load(key: "claude_api_key") }
        set {
            if let value = newValue {
                KeychainHelper.save(key: "claude_api_key", value: value)
            } else {
                KeychainHelper.delete(key: "claude_api_key")
            }
        }
    }

    var googleApiKey: String? {
        get { KeychainHelper.load(key: "google_api_key") }
        set {
            if let value = newValue {
                KeychainHelper.save(key: "google_api_key", value: value)
            } else {
                KeychainHelper.delete(key: "google_api_key")
            }
        }
    }

    // MARK: - Initialization

    init() {
        // Load saved values or use defaults
        self.temperature = defaults.double(forKey: Keys.temperature) != 0
            ? defaults.double(forKey: Keys.temperature)
            : 0.7

        self.contextWindow = defaults.integer(forKey: Keys.contextWindow) != 0
            ? defaults.integer(forKey: Keys.contextWindow)
            : 8192

        self.inputLanguage = SupportedLanguage(rawValue: defaults.string(forKey: Keys.inputLanguage) ?? "en") ?? .english
        self.outputLanguage = SupportedLanguage(rawValue: defaults.string(forKey: Keys.outputLanguage) ?? "en") ?? .english

        self.hapticFeedbackEnabled = defaults.object(forKey: Keys.hapticFeedback) == nil
            ? true
            : defaults.bool(forKey: Keys.hapticFeedback)

        self.voiceInputMode = VoiceInputMode(rawValue: defaults.string(forKey: Keys.voiceInputMode) ?? "") ?? .pushToTalk

        self.speechRate = defaults.double(forKey: Keys.speechRate) != 0
            ? defaults.double(forKey: Keys.speechRate)
            : 1.0

        self.chatGPTEnabled = defaults.bool(forKey: Keys.chatGPTEnabled)
        self.claudeEnabled = defaults.bool(forKey: Keys.claudeEnabled)
        self.googleEnabled = defaults.bool(forKey: Keys.googleEnabled)
        self.iCloudSyncEnabled = defaults.bool(forKey: Keys.iCloudSync)
    }

    // MARK: - Reset

    func resetToDefaults() {
        temperature = 0.7
        contextWindow = 8192
        inputLanguage = .english
        outputLanguage = .english
        hapticFeedbackEnabled = true
        voiceInputMode = .pushToTalk
        speechRate = 1.0
        chatGPTEnabled = false
        claudeEnabled = false
        googleEnabled = false
        iCloudSyncEnabled = false

        // Clear API keys
        chatGPTApiKey = nil
        claudeApiKey = nil
        googleApiKey = nil
    }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}
