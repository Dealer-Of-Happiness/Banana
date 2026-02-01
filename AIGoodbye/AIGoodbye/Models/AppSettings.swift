//
//  AppSettings.swift
//  AIGoodbye
//
//  App settings and configuration models
//

import Foundation

// MARK: - Supported Languages
// Qwen2-VL supports 29+ languages - these are the most commonly used

enum SupportedLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh"
    case arabic = "ar"
    case hindi = "hi"
    case vietnamese = "vi"
    case thai = "th"
    case turkish = "tr"
    case polish = "pl"
    case dutch = "nl"
    case indonesian = "id"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .italian: return "Italiano"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .chinese: return "中文"
        case .arabic: return "العربية"
        case .hindi: return "हिन्दी"
        case .vietnamese: return "Tiếng Việt"
        case .thai: return "ไทย"
        case .turkish: return "Türkçe"
        case .polish: return "Polski"
        case .dutch: return "Nederlands"
        case .indonesian: return "Bahasa Indonesia"
        }
    }

    /// Full language name in English (for system prompt)
    var englishName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .russian: return "Russian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .chinese: return "Chinese"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .vietnamese: return "Vietnamese"
        case .thai: return "Thai"
        case .turkish: return "Turkish"
        case .polish: return "Polish"
        case .dutch: return "Dutch"
        case .indonesian: return "Indonesian"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var speechRecognitionLocale: String {
        switch self {
        case .english: return "en-US"
        case .spanish: return "es-ES"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .italian: return "it-IT"
        case .portuguese: return "pt-BR"
        case .russian: return "ru-RU"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .chinese: return "zh-CN"
        case .arabic: return "ar-SA"
        case .hindi: return "hi-IN"
        case .vietnamese: return "vi-VN"
        case .thai: return "th-TH"
        case .turkish: return "tr-TR"
        case .polish: return "pl-PL"
        case .dutch: return "nl-NL"
        case .indonesian: return "id-ID"
        }
    }
}

// MARK: - Voice Input Mode

enum VoiceInputMode: String, CaseIterable {
    case pushToTalk = "push_to_talk"
    case handsFree = "hands_free"

    var displayName: String {
        switch self {
        case .pushToTalk: return "Push to Talk"
        case .handsFree: return "Hands-free"
        }
    }
}

// MARK: - Cloud AI Provider

enum CloudAIProvider: String, CaseIterable, Identifiable {
    case chatGPT = "openai"
    case claude = "anthropic"
    case google = "google"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        case .google: return "Google AI"
        }
    }

    var iconName: String {
        switch self {
        case .chatGPT: return "bubble.left.fill"
        case .claude: return "sparkles"
        case .google: return "g.circle.fill"
        }
    }
}

// MARK: - Knowledge Base Source

enum KnowledgeBaseSource: String, CaseIterable, Identifiable {
    case calendar
    case reminders

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        }
    }

    var iconName: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        }
    }

    var description: String {
        switch self {
        case .calendar: return "Access your calendar events and schedule"
        case .reminders: return "Manage your reminders"
        }
    }
}

// MARK: - Export Format

enum ExportFormat: String, CaseIterable {
    case txt
    case pdf
    case json

    var displayName: String {
        switch self {
        case .txt: return "Plain Text (.txt)"
        case .pdf: return "PDF Document (.pdf)"
        case .json: return "JSON (.json)"
        }
    }

    var fileExtension: String { rawValue }
}
