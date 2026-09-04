//
//  L10n.swift
//  AIGoodbye
//
//  Language-aware string lookup. When the user picks an in-app language,
//  strings resolved through here switch immediately (no relaunch needed),
//  because they read from that language's resource bundle directly.
//

import Foundation

enum L10n {

    private static let lock = NSLock()
    private static var _bundle: Bundle = .main

    /// Bundle for the currently selected app language (.main when Automatic).
    /// Lock-guarded: written from the main thread, read from any thread
    /// (error paths, background tasks).
    static var bundle: Bundle {
        lock.lock()
        defer { lock.unlock() }
        return _bundle
    }

    /// Point lookups at the given language. Called by SettingsManager.
    static func apply(_ language: AppLanguage) {
        let resolved: Bundle
        if language == .automatic {
            resolved = .main
        } else if let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                  let languageBundle = Bundle(path: path) {
            resolved = languageBundle
        } else {
            resolved = .main
        }
        lock.lock()
        _bundle = resolved
        lock.unlock()
    }

    /// Localized string in the currently selected app language.
    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle)
    }
}
