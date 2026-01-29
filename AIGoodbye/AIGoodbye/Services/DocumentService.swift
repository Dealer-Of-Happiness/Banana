//
//  DocumentService.swift
//  AIGoodbye
//
//  Document processing service for PDF, Word, and text files
//

import Foundation
import PDFKit

actor DocumentService {
    private let chunkSize = 500
    private let chunkOverlap = 50
    static let maxFileSizeBytes: Int = 25 * 1024 * 1024 // 25 MB limit

    // MARK: - Process Document

    func processDocument(at url: URL) async throws -> ProcessedDocument {
        guard url.startAccessingSecurityScopedResource() else {
            throw DocumentError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        // Check file size limit
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? Int ?? 0
        guard fileSize <= Self.maxFileSizeBytes else {
            let sizeMB = Double(fileSize) / (1024 * 1024)
            throw DocumentError.fileTooLarge(String(format: "%.1f MB (max 25 MB)", sizeMB))
        }

        let fileName = url.lastPathComponent
        let fileExtension = url.pathExtension.lowercased()

        // Extract text based on file type
        let content: String
        switch fileExtension {
        case "pdf":
            content = try extractPDFText(from: url)
        case "docx":
            content = try extractDocxText(from: url)
        case "txt", "md", "markdown":
            content = try String(contentsOf: url, encoding: .utf8)
        case "rtf":
            content = try extractRTFText(from: url)
        default:
            throw DocumentError.unsupportedFormat(fileExtension)
        }

        guard !content.isEmpty else {
            throw DocumentError.emptyDocument
        }

        // Split into chunks for RAG
        let chunks = splitIntoChunks(content)

        return ProcessedDocument(
            id: UUID(),
            name: fileName,
            type: DocumentType(rawValue: fileExtension) ?? .txt,
            size: fileSize,
            chunks: chunks,
            fullText: content
        )
    }

    // MARK: - PDF Extraction

    private func extractPDFText(from url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw DocumentError.failedToRead("Could not open PDF")
        }

        var fullText = ""

        for pageIndex in 0..<document.pageCount {
            if let page = document.page(at: pageIndex),
               let pageText = page.string {
                fullText += pageText + "\n\n"
            }
        }

        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - DOCX Extraction

    private func extractDocxText(from url: URL) throws -> String {
        // DOCX is a ZIP file containing XML
        // On iOS, we need to manually extract the content
        let data = try Data(contentsOf: url)

        // Try to find readable text in the raw data
        // DOCX files contain document.xml with the text content
        if let content = String(data: data, encoding: .utf8) {
            // Extract text between XML tags
            let cleaned = content
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !cleaned.isEmpty && cleaned.count > 50 {
                return cleaned
            }
        }

        // If raw extraction fails, try reading as plain data
        // For full DOCX support, add a ZIP library like ZIPFoundation
        throw DocumentError.failedToRead("DOCX support requires iOS 17+. Try converting to PDF or TXT.")
    }

    // MARK: - RTF Extraction

    private func extractRTFText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)

        if let attributedString = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) {
            return attributedString.string
        }

        throw DocumentError.failedToRead("Could not parse RTF")
    }

    // MARK: - Text Chunking

    private func splitIntoChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        let sentences = splitIntoSentences(text)
        var currentChunk = ""

        for sentence in sentences {
            if currentChunk.count + sentence.count > chunkSize && !currentChunk.isEmpty {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))

                // Keep overlap
                let overlapStart = max(0, currentChunk.count - chunkOverlap)
                let startIndex = currentChunk.index(currentChunk.startIndex, offsetBy: overlapStart)
                currentChunk = String(currentChunk[startIndex...])
            }

            currentChunk += sentence + " "
        }

        if !currentChunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return chunks
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []

        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }

        return sentences
    }

    // MARK: - Search in Document

    func search(query: String, in document: ProcessedDocument) -> [String] {
        let queryWords = Set(query.lowercased().components(separatedBy: .whitespaces))

        var scored: [(score: Int, chunk: String)] = []

        for chunk in document.chunks {
            let chunkWords = Set(chunk.lowercased().components(separatedBy: .whitespaces))
            let score = queryWords.intersection(chunkWords).count
            if score > 0 {
                scored.append((score, chunk))
            }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(5)
            .map { $0.chunk }
    }
}

// MARK: - Processed Document

struct ProcessedDocument {
    let id: UUID
    let name: String
    let type: DocumentType
    let size: Int
    let chunks: [String]
    let fullText: String
}

// MARK: - Errors

enum DocumentError: LocalizedError {
    case accessDenied
    case unsupportedFormat(String)
    case emptyDocument
    case failedToRead(String)
    case fileTooLarge(String)
    case invalidDocument

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Cannot access this file"
        case .unsupportedFormat(let format):
            return "Unsupported format: \(format)"
        case .emptyDocument:
            return "The document is empty"
        case .failedToRead(let reason):
            return "Failed to read: \(reason)"
        case .fileTooLarge(let size):
            return "File too large: \(size)"
        case .invalidDocument:
            return "Invalid or corrupted document"
        }
    }
}
