//
//  SettingsManager.swift
//  BananaAI
//
//  Manage app settings with persistence
//

import Foundation
import SwiftUI

/// Manages persistent app settings
class SettingsManager: ObservableObject {
    private let defaults = UserDefaults.standard

    // MARK: - Settings Keys

    private enum Keys {
        static let useInternet = "useInternet"
        static let onlineProvider = "onlineProvider"
        static let apiKey = "apiKey"
        static let selectedModel = "selectedModel"
        static let temperature = "temperature"
        static let maxTokens = "maxTokens"
    }

    // MARK: - Published Properties

    @Published var useInternet: Bool {
        didSet { defaults.set(useInternet, forKey: Keys.useInternet) }
    }

    @Published var onlineProvider: String {
        didSet { defaults.set(onlineProvider, forKey: Keys.onlineProvider) }
    }

    @Published var selectedModel: String {
        didSet { defaults.set(selectedModel, forKey: Keys.selectedModel) }
    }

    @Published var temperature: Double {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }

    @Published var maxTokens: Int {
        didSet { defaults.set(maxTokens, forKey: Keys.maxTokens) }
    }

    // MARK: - Secure Storage (Keychain)

    var apiKey: String? {
        get { KeychainHelper.load(key: Keys.apiKey) }
        set {
            if let value = newValue {
                KeychainHelper.save(key: Keys.apiKey, value: value)
            } else {
                KeychainHelper.delete(key: Keys.apiKey)
            }
        }
    }

    // MARK: - Initialization

    init() {
        self.useInternet = defaults.bool(forKey: Keys.useInternet)
        self.onlineProvider = defaults.string(forKey: Keys.onlineProvider) ?? "openai"
        self.selectedModel = defaults.string(forKey: Keys.selectedModel) ?? "Llama 3.2 3B"
        self.temperature = defaults.double(forKey: Keys.temperature) != 0
            ? defaults.double(forKey: Keys.temperature)
            : 0.7
        self.maxTokens = defaults.integer(forKey: Keys.maxTokens) != 0
            ? defaults.integer(forKey: Keys.maxTokens)
            : 2048
    }

    // MARK: - Reset

    func resetToDefaults() {
        useInternet = false
        onlineProvider = "openai"
        selectedModel = "Llama 3.2 3B"
        temperature = 0.7
        maxTokens = 2048
        apiKey = nil
    }
}

// MARK: - Keychain Helper

/// Simple keychain wrapper for secure storage
enum KeychainHelper {
    static func save(key: String, value: String) {
        let data = value.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
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
