//
//  AppConfig.swift
//  AIGoodbye
//
//  Centralized configuration for app-wide constants
//

import Foundation

/// Centralized configuration struct for app-wide constants
/// Eliminates hardcoded values scattered throughout the codebase
enum AppConfig {

    // MARK: - Image Processing

    enum Image {
        /// Maximum dimension for image resizing (width or height)
        static let maxDimension: CGFloat = 512

        /// JPEG compression quality for processed images
        static let compressionQuality: CGFloat = 0.8
    }

    // MARK: - Memory Management

    enum Memory {
        /// GPU cache limit in bytes (20MB default)
        static let gpuCacheLimit: Int = 20 * 1024 * 1024

        /// Maximum conversation history entries to keep in memory
        static let historyLimit: Int = 10

        /// Maximum tokens for AI response generation
        static let maxTokens: Int = 256
    }

    // MARK: - Document Processing

    enum Document {
        /// Maximum file size for document processing (25MB)
        static let maxFileSizeBytes: Int = 25 * 1024 * 1024

        /// Chunk size for text processing
        static let chunkSize: Int = 500

        /// Overlap between chunks for context continuity
        static let chunkOverlap: Int = 50

        /// Content limit for document truncation in chat
        static let contentLimit: Int = 6000
    }

    // MARK: - Model Parameters

    enum Model {
        /// Default temperature for AI generation
        static let defaultTemperature: Float = 0.7

        /// Top-p sampling parameter
        static let topP: Float = 0.9

        /// Download buffer size for streaming downloads (1MB)
        static let downloadBufferSize: Int = 1024 * 1024
    }

    // MARK: - Contact Information

    enum Contact {
        /// Support email address
        static let supportEmail = "marketing@dealerofhappiness.com"

        /// Support email URL
        static var supportEmailURL: URL? {
            URL(string: "mailto:\(supportEmail)")
        }
    }

    // MARK: - UI Constants

    enum UI {
        /// Animation duration for standard transitions
        static let animationDuration: Double = 0.3

        /// Corner radius for cards and containers
        static let cornerRadius: CGFloat = 12

        /// Standard padding
        static let standardPadding: CGFloat = 16
    }
}
