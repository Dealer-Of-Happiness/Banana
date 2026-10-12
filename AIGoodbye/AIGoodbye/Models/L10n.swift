//
//  L10n.swift
//  AIGoodbye
//
//  Language-aware string lookup. When the user picks an in-app language,
//  strings resolved through here switch immediately (no relaunch needed),
//  because they read from that language's resource bundle directly.
//

import Foundation

/// Deliberately `nonisolated` throughout. Error messages are built inside
/// `LocalizedError.errorDescription`, which the protocol declares nonisolated,
/// and background work formats user-facing strings too; the state behind these
/// calls is a single bundle reference guarded by a lock.
enum L10n {

    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var _bundle: Bundle = .main
    /// The language code `apply` resolved (the device's for Automatic); nil
    /// until SettingsManager has applied a choice.
    nonisolated(unsafe) private static var _languageCode: String?
    /// `locale` is read for every date in a list; building it once per
    /// language/region pair keeps that cheap.
    nonisolated(unsafe) private static var _cachedLocale: (code: String?, region: String?, locale: Locale)?

    /// Bundle for the currently selected app language (.main when Automatic).
    /// Lock-guarded: written from the main thread, read from any thread
    /// (error paths, background tasks).
    nonisolated static var bundle: Bundle {
        lock.lock()
        defer { lock.unlock() }
        return _bundle
    }

    /// Point lookups at the given language. Called by SettingsManager.
    nonisolated static func apply(_ language: AppLanguage) {
        let resolved: Bundle
        let code = language == .automatic ? deviceLanguageCode : language.rawValue
        if let code,
           let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let languageBundle = Bundle(path: path) {
            resolved = languageBundle
        } else {
            resolved = .main
        }
        lock.lock()
        _bundle = resolved
        _languageCode = code
        _cachedLocale = nil
        lock.unlock()
    }

    /// Locale for formatting dates and numbers: the selected app language
    /// (the device language for Automatic) with the device's region.
    ///
    /// `Locale.current` is not enough: picking a language in the app only
    /// rewrites AppleLanguages, so `Locale.current` kept formatting in the
    /// device language and a Russian drawer read "Oct 11, 2026". The region
    /// stays the device's because it carries the user's own conventions
    /// (date order, 24-hour clock) that a language choice says nothing about.
    nonisolated static var locale: Locale {
        lock.lock()
        let applied = _languageCode
        let cached = _cachedLocale
        lock.unlock()

        let code = applied ?? deviceLanguageCode
        let region = Locale.current.region
        if let cached, cached.code == code, cached.region == region?.identifier {
            return cached.locale
        }
        let built = makeLocale(languageCode: code, region: region)
        lock.lock()
        _cachedLocale = (code, region?.identifier, built)
        lock.unlock()
        return built
    }

    /// Components rather than string concatenation: codes such as "pt-BR"
    /// and "zh-HK" already carry a region, and "pt-BR_US" is not a valid
    /// identifier. Keeping the language's own components keeps zh-HK in
    /// Traditional characters while the formatting region is the device's.
    nonisolated static func makeLocale(languageCode code: String?, region: Locale.Region?) -> Locale {
        guard let code else { return .current }
        var components = Locale.Components(identifier: code)
        if let region { components.region = region }
        return Locale(components: components)
    }

    /// The localization the DEVICE prefers, ignoring this app's own
    /// `AppleLanguages` override. `Bundle.main` caches its preferred
    /// localization once per process, so switching back to Automatic used
    /// to change nothing until the next launch.
    nonisolated static var deviceLanguageCode: String? {
        let global = UserDefaults.standard.volatileDomain(forName: UserDefaults.globalDomain)
        let preferred = (global["AppleLanguages"] as? [String]) ?? Locale.preferredLanguages
        let available = Bundle.main.localizations.filter { $0 != "Base" }
        return Bundle.preferredLocalizations(from: available, forPreferences: preferred).first
    }

    /// Localized string in the currently selected app language.
    nonisolated static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle)
    }
}

// MARK: - Dates in the app language

extension Date {
    /// `formatted(date:time:)` in the app language. Use this instead of the
    /// system call for anything the user reads, including VoiceOver labels
    /// and names that get stored (scan titles, recording titles).
    nonisolated func aigFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: L10n.locale))
    }

    /// Compact timestamp for list rows: the time for today, the weekday
    /// within the last week, day and month this year, the full date before
    /// that. A row reading "Oct 11, 2026" for a chat from five minutes ago
    /// told the user nothing.
    nonisolated func aigRelative(now: Date = Date()) -> String {
        let locale = L10n.locale
        let calendar = Calendar.autoupdatingCurrent
        let startOfToday = calendar.startOfDay(for: now)
        if calendar.isDate(self, inSameDayAs: now) {
            return formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
        }
        // Six days back, not the calendar week: a weekday name is only
        // unambiguous while it cannot mean last week's day of the same name.
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday),
           self >= weekAgo, self < startOfToday {
            return formatted(Date.FormatStyle(locale: locale).weekday(.wide))
        }
        if calendar.isDate(self, equalTo: now, toGranularity: .year) {
            return formatted(Date.FormatStyle(locale: locale).month(.abbreviated).day())
        }
        return formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale))
    }
}
