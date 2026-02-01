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
