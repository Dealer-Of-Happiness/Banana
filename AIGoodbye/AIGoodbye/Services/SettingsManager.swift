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
        static let hapticFeedback = "haptic_feedback"
    }

    // MARK: - AI Settings

    /// Sampling temperature (0.1...1.0). Lower = more precise, higher = more creative.
    @Published var temperature: Double {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }

    /// Context window in tokens (4096...32768). How much history the model re-reads.
    @Published var contextWindow: Int {
        didSet { defaults.set(contextWindow, forKey: Keys.contextWindow) }
    }

    // MARK: - Feedback Settings

    @Published var hapticFeedbackEnabled: Bool {
        didSet { defaults.set(hapticFeedbackEnabled, forKey: Keys.hapticFeedback) }
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

        self.hapticFeedbackEnabled = defaults.object(forKey: Keys.hapticFeedback) == nil
            ? true
            : defaults.bool(forKey: Keys.hapticFeedback)
    }

    // MARK: - Reset

    func resetToDefaults() {
        temperature = 0.7
        contextWindow = 8192
        hapticFeedbackEnabled = true
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
