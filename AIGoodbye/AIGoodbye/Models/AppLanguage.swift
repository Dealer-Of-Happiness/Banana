//
//  AppLanguage.swift
//  AIGoodbye
//
//  App-wide language selection. Changing the language switches the UI and
//  also tells the AI which language to respond in.
//

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case automatic = "auto"
    case english = "en"
    case mandarin = "zh-Hans"
    case cantonese = "zh-HK"
    case russian = "ru"
    case ukrainian = "uk"
    case korean = "ko"
    case japanese = "ja"
    case french = "fr"
    case german = "de"
    case greek = "el"
    case italian = "it"
    case spanish = "es"
    case portuguese = "pt-BR"

    var id: String { rawValue }

    /// How the language names itself (shown in the picker; intentionally
    /// not localized so every user can find their own language).
    var displayName: String {
        switch self {
        case .automatic: return L10n.text("Automatic (match device)")
        case .english: return "English"
        case .mandarin: return "简体中文 · Mandarin"
        case .cantonese: return "廣東話 · Cantonese"
        case .russian: return "Русский"
        case .ukrainian: return "Українська"
        case .korean: return "한국어"
        case .japanese: return "日本語"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .greek: return "Ελληνικά"
        case .italian: return "Italiano"
        case .spanish: return "Español"
        case .portuguese: return "Português"
        }
    }

    /// Locale used for the SwiftUI environment when this language is active.
    var locale: Locale? {
        self == .automatic ? nil : Locale(identifier: rawValue)
    }

    /// The instruction fragment that tells the model which language to answer in.
    /// English name of the language, for prompts sent to the model.
    var englishName: String {
        switch self {
        case .automatic: return "the user's language"
        case .english: return "English"
        case .mandarin: return "Mandarin Chinese (Simplified characters)"
        case .cantonese: return "Cantonese (Traditional characters)"
        case .russian: return "Russian"
        case .ukrainian: return "Ukrainian"
        case .korean: return "Korean"
        case .japanese: return "Japanese"
        case .french: return "French"
        case .german: return "German"
        case .greek: return "Greek"
        case .italian: return "Italian"
        case .spanish: return "Spanish"
        case .portuguese: return "Brazilian Portuguese"
        }
    }

    var modelInstruction: String {
        switch self {
        case .automatic:
            return "Always respond in the same language the user writes to you."
        case .english:
            return "Always respond in English, unless the user explicitly asks for another language."
        case .mandarin:
            return "Always respond in Mandarin Chinese using Simplified characters (简体中文), unless the user explicitly asks for another language."
        case .cantonese:
            return "Always respond in Cantonese (廣東話) using Traditional Chinese characters, with natural Cantonese vocabulary and grammar, unless the user explicitly asks for another language."
        case .russian:
            return "Always respond in Russian (русский язык), unless the user explicitly asks for another language."
        case .ukrainian:
            return "Always respond in Ukrainian (українська мова), unless the user explicitly asks for another language."
        case .korean:
            return "Always respond in Korean (한국어), unless the user explicitly asks for another language."
        case .japanese:
            return "Always respond in Japanese (日本語), unless the user explicitly asks for another language."
        case .french:
            return "Always respond in French (français), unless the user explicitly asks for another language."
        case .german:
            return "Always respond in German (Deutsch), unless the user explicitly asks for another language."
        case .greek:
            return "Always respond in Greek (ελληνικά), unless the user explicitly asks for another language."
        case .italian:
            return "Always respond in Italian (italiano), unless the user explicitly asks for another language."
        case .spanish:
            return "Always respond in Spanish (español), unless the user explicitly asks for another language."
        case .portuguese:
            return "Always respond in Brazilian Portuguese (português), unless the user explicitly asks for another language."
        }
    }

    /// Languages offered in the picker, in display order.
    static var pickerOrder: [AppLanguage] {
        [.automatic, .english, .mandarin, .cantonese, .russian, .ukrainian,
         .korean, .japanese, .french, .german, .greek, .italian, .spanish, .portuguese]
    }
}
