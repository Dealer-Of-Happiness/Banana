//
//  DocumentProcessor.swift
//  BananaAI
//
//  Process documents (PDF, text) and extract content for knowledge base
//

import Foundation
import PDFKit

/// Processes various document types for the knowledge base
class DocumentProcessor {
    private let knowledgeBase: KnowledgeBase
    private let chunkSize = 500 // Characters per chunk
    private let chunkOverlap = 50 // Overlap between chunks

    init(knowledgeBase: KnowledgeBase) {
        self.knowledgeBase = knowledgeBase
    }

    /// Process a file and add it to the knowledge base
    func processFile(_ url: URL, statusUpdate: @escaping (String) -> Void) async throws -> Document {
        let fileName = url.lastPathComponent
        let fileType = url.pathExtension.lowercased()

        statusUpdate("Reading file...")

        // Extract text based on file type
        let content: String
        switch fileType {
        case "pdf":
            content = try extractPDFText(from: url, statusUpdate: statusUpdate)
        case "txt", "text", "md", "markdown":
            content = try String(contentsOf: url, encoding: .utf8)
        case "rtf":
            content = try extractRTFText(from: url)
        default:
            throw ProcessingError.unsupportedFormat(fileType)
        }

        guard !content.isEmpty else {
            throw ProcessingError.emptyDocument
        }

        statusUpdate("Splitting into chunks...")

        // Split into chunks
        let chunks = splitIntoChunks(content)

        statusUpdate("Creating embeddings...")

        // Create document record
        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        let document = Document(
            id: UUID().uuidString,
            name: fileName,
            type: fileType,
            size: fileSize,
            chunks: chunks.count,
            addedDate: Date()
        )

        statusUpdate("Saving to knowledge base...")

        // Add to knowledge base
        try await knowledgeBase.addDocument(document, chunks: chunks)

        return document
    }

    // MARK: - PDF Processing

    private func extractPDFText(from url: URL, statusUpdate: @escaping (String) -> Void) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw ProcessingError.failedToRead("Could not open PDF")
        }

        var fullText = ""
        let pageCount = document.pageCount

        for i in 0..<pageCount {
            if i % 10 == 0 {
                statusUpdate("Reading page \(i + 1) of \(pageCount)...")
            }

            if let page = document.page(at: i),
               let pageText = page.string {
                fullText += pageText + "\n\n"
            }
        }

        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - RTF Processing

    private func extractRTFText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let attributedString = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) {
            return attributedString.string
        }
        throw ProcessingError.failedToRead("Could not parse RTF")
    }

    // MARK: - Text Chunking

    private func splitIntoChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        let sentences = splitIntoSentences(text)

        var currentChunk = ""

        for sentence in sentences {
            // If adding this sentence would exceed chunk size, save current chunk
            if currentChunk.count + sentence.count > chunkSize && !currentChunk.isEmpty {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))

                // Keep overlap from end of current chunk
                let overlapStart = max(0, currentChunk.count - chunkOverlap)
                currentChunk = String(currentChunk.suffix(from: currentChunk.index(currentChunk.startIndex, offsetBy: overlapStart)))
            }

            currentChunk += sentence + " "
        }

        // Don't forget the last chunk
        if !currentChunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return chunks
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        let cleanedText = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")

        // Simple sentence splitting
        let pattern = "[.!?]+\\s+"
        let regex = try? NSRegularExpression(pattern: pattern)

        var lastEnd = cleanedText.startIndex

        regex?.enumerateMatches(
            in: cleanedText,
            range: NSRange(cleanedText.startIndex..., in: cleanedText)
        ) { match, _, _ in
            if let range = match?.range, let swiftRange = Range(range, in: cleanedText) {
                let sentence = String(cleanedText[lastEnd..<swiftRange.upperBound])
                sentences.append(sentence.trimmingCharacters(in: .whitespaces))
                lastEnd = swiftRange.upperBound
            }
        }

        // Get remaining text
        if lastEnd < cleanedText.endIndex {
            let remaining = String(cleanedText[lastEnd...])
            if !remaining.trimmingCharacters(in: .whitespaces).isEmpty {
                sentences.append(remaining.trimmingCharacters(in: .whitespaces))
            }
        }

        return sentences
    }
}

// MARK: - Errors

enum ProcessingError: LocalizedError {
    case unsupportedFormat(String)
    case emptyDocument
    case failedToRead(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Unsupported file format: \(format)"
        case .emptyDocument:
            return "The document appears to be empty"
        case .failedToRead(let reason):
            return "Failed to read document: \(reason)"
        }
    }
}
