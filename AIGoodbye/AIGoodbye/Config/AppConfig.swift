//
//  AppConfig.swift
//  AIGoodbye
//
//  Centralized configuration for app-wide constants
//

import Foundation
import UIKit

/// Centralized configuration struct for app-wide constants
/// Eliminates hardcoded values scattered throughout the codebase
/// All properties are nonisolated(unsafe) to allow access from any actor context
enum AppConfig {

    // MARK: - Image Processing

    enum Image {
        /// Maximum dimension for image resizing (width or height)
        nonisolated(unsafe) static let maxDimension: CGFloat = 512

        /// JPEG compression quality for processed images
        nonisolated(unsafe) static let compressionQuality: CGFloat = 0.8

        /// Resize image to prevent memory crashes when combined with loaded model
        @MainActor
        static func resizeForMemory(_ image: UIImage, maxDimension: CGFloat = Image.maxDimension) -> UIImage {
            let size = image.size

            if size.width <= maxDimension && size.height <= maxDimension {
                return image
            }

            let ratio = min(maxDimension / size.width, maxDimension / size.height)
            let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)

            return autoreleasepool {
                let renderer = UIGraphicsImageRenderer(size: newSize)
                return renderer.image { _ in
                    image.draw(in: CGRect(origin: .zero, size: newSize))
                }
            }
        }
    }

    // MARK: - Memory Management

    enum Memory {
        /// GPU cache limit in bytes (20MB default)
        nonisolated(unsafe) static let gpuCacheLimit: Int = 20 * 1024 * 1024

        /// Maximum conversation history entries to keep in memory
        nonisolated(unsafe) static let historyLimit: Int = 10

        /// Maximum tokens for AI response generation
        nonisolated(unsafe) static let maxTokens: Int = 256
    }

    // MARK: - Document Processing

    enum Document {
        /// Maximum file size for document processing (25MB)
        nonisolated(unsafe) static let maxFileSizeBytes: Int = 25 * 1024 * 1024

        /// Chunk size for text processing
        nonisolated(unsafe) static let chunkSize: Int = 500

        /// Overlap between chunks for context continuity
        nonisolated(unsafe) static let chunkOverlap: Int = 50

        /// Content limit for document truncation in chat
        nonisolated(unsafe) static let contentLimit: Int = 6000
    }

    // MARK: - Model Parameters

    enum Model {
        /// Default temperature for AI generation
        nonisolated(unsafe) static let defaultTemperature: Float = 0.7

        /// Top-p sampling parameter
        nonisolated(unsafe) static let topP: Float = 0.9

        /// Download buffer size for streaming downloads (1MB)
        nonisolated(unsafe) static let downloadBufferSize: Int = 1024 * 1024
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
