//
//  AppSettings.swift
//  AIGoodbye
//
//  App settings and configuration models
//

import Foundation

// MARK: - Supported Languages

enum SupportedLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case russian = "ru"
    case korean = "ko"
    case chinese = "zh"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        case .french: return "Français"
        case .russian: return "Русский"
        case .korean: return "한국어"
        case .chinese: return "中文"
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
        case .russian: return "ru-RU"
        case .korean: return "ko-KR"
        case .chinese: return "zh-CN"
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
