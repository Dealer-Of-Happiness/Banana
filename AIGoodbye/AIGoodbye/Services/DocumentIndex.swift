//
//  DocumentIndex.swift
//  AIGoodbye
//
//  The document brain: fully offline retrieval over attached documents.
//
//  Whole documents are extracted once, stored on disk, split into
//  overlapping chunks, and scored per question with a hybrid ranker:
//  keyword overlap (works in every language, zero assets) boosted by
//  Apple's on-device sentence embeddings when the language supports them.
//  The top chunks become the model's hidden context for that question,
//  so the AI can answer about a 300-page PDF without ever sending a byte
//  anywhere.
//

import Foundation
import NaturalLanguage

struct DocumentChunk {
    let documentName: String
    let text: String
    let position: Int
}

@MainActor
final class DocumentIndex {

    static let shared = DocumentIndex()
    private init() {}

    /// In-memory chunk cache per document id.
    private var chunkCache: [UUID: [DocumentChunk]] = [:]
    private var nameCache: [UUID: String] = [:]

    // MARK: - Storage

    static var documentsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = documents.appendingPathComponent("docs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func textURL(for id: UUID) -> URL {
        documentsDirectory.appendingPathComponent("\(id.uuidString).txt")
    }

    private static func nameURL(for id: UUID) -> URL {
        documentsDirectory.appendingPathComponent("\(id.uuidString).name")
    }

    /// Store a document's full extracted text. Returns its id.
    func store(name: String, fullText: String) -> UUID {
        let id = UUID()
        try? fullText.write(to: Self.textURL(for: id), atomically: true, encoding: .utf8)
        try? name.write(to: Self.nameURL(for: id), atomically: true, encoding: .utf8)
        chunkCache[id] = Self.chunk(fullText, documentName: name)
        nameCache[id] = name
        return id
    }

    func documentName(for id: UUID) -> String? {
        if let cached = nameCache[id] { return cached }
        let name = try? String(contentsOf: Self.nameURL(for: id), encoding: .utf8)
        if let name { nameCache[id] = name }
        return name
    }

    func hasDocument(_ id: UUID) -> Bool {
        chunkCache[id] != nil || FileManager.default.fileExists(atPath: Self.textURL(for: id).path)
    }

    func removeDocument(_ id: UUID) {
        chunkCache[id] = nil
        nameCache[id] = nil
        try? FileManager.default.removeItem(at: Self.textURL(for: id))
        try? FileManager.default.removeItem(at: Self.nameURL(for: id))
    }

    private func chunks(for id: UUID) -> [DocumentChunk] {
        if let cached = chunkCache[id] { return cached }
        guard let text = try? String(contentsOf: Self.textURL(for: id), encoding: .utf8) else { return [] }
        let name = documentName(for: id) ?? "document"
        let chunks = Self.chunk(text, documentName: name)
        chunkCache[id] = chunks
        return chunks
    }

    // MARK: - Retrieval

    /// The most relevant document passages for a question, formatted as
    /// hidden context for the model. Returns nil when nothing is attached
    /// or nothing matches.
    func context(for question: String, documentIds: [UUID], budget: Int = 6000) -> String? {
        let allChunks = documentIds.flatMap { chunks(for: $0) }
        guard !allChunks.isEmpty else { return nil }

        let ranked = Self.rank(chunks: allChunks, question: question)
        guard !ranked.isEmpty else { return nil }

        var used = 0
        var parts: [String] = []
        for chunk in ranked {
            let cost = chunk.text.count
            if used + cost > budget { break }
            parts.append("[\(chunk.documentName), part \(chunk.position + 1)]\n\(chunk.text)")
            used += cost
        }
        guard !parts.isEmpty else { return nil }

        return """
        Relevant passages from the user's attached documents:

        \(parts.joined(separator: "\n\n---\n\n"))
        """
    }

    // MARK: - Chunking

    /// Overlapping chunks of roughly `size` characters, split on sentence
    /// boundaries where possible.
    nonisolated static func chunk(
        _ text: String,
        documentName: String,
        size: Int = 900,
        overlap: Int = 150
    ) -> [DocumentChunk] {
        let cleaned = text.replacingOccurrences(of: "\r", with: "")
        guard cleaned.count > size else {
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [DocumentChunk(documentName: documentName, text: trimmed, position: 0)]
        }

        var chunks: [DocumentChunk] = []
        var start = cleaned.startIndex
        var position = 0

        while start < cleaned.endIndex {
            let hardEnd = cleaned.index(start, offsetBy: size, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            var end = hardEnd
            // Prefer to break at a sentence/paragraph boundary near the end.
            if hardEnd < cleaned.endIndex {
                let windowStart = cleaned.index(hardEnd, offsetBy: -min(200, size / 3), limitedBy: start) ?? start
                if let boundary = cleaned[windowStart..<hardEnd].lastIndex(where: { ".!?\n。！？".contains($0) }) {
                    end = cleaned.index(after: boundary)
                }
            }

            let piece = cleaned[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                chunks.append(DocumentChunk(documentName: documentName, text: piece, position: position))
                position += 1
            }

            if end >= cleaned.endIndex { break }
            // Step back by `overlap` for context continuity, but always make
            // forward progress relative to the previous chunk start.
            let stepped = cleaned.index(end, offsetBy: -overlap, limitedBy: start)
            if let stepped, stepped > start {
                start = stepped
            } else {
                start = end
            }
        }
        return chunks
    }

    // MARK: - Ranking

    /// Hybrid ranking: keyword overlap in every language, plus Apple's
    /// on-device sentence embeddings when available for the language.
    nonisolated static func rank(chunks: [DocumentChunk], question: String, topK: Int = 6) -> [DocumentChunk] {
        let questionTokens = tokens(of: question)
        guard !questionTokens.isEmpty else { return Array(chunks.prefix(topK)) }

        // Optional semantic scores.
        let embedding = sentenceEmbedding(for: question)
        let questionVector = embedding?.vector(for: question)

        var scored: [(chunk: DocumentChunk, score: Double)] = []
        for chunk in chunks {
            let chunkTokens = tokens(of: chunk.text)
            guard !chunkTokens.isEmpty else { continue }
            let overlap = questionTokens.intersection(chunkTokens)
            // Keyword score: overlap weighted by rarity-ish (longer tokens count more).
            var score = overlap.reduce(0.0) { $0 + Double($1.count) }
                / Double(questionTokens.reduce(0) { $0 + $1.count })

            if let embedding, let questionVector,
               let chunkVector = embedding.vector(for: String(chunk.text.prefix(512))) {
                score += 0.8 * cosine(questionVector, chunkVector)
            }
            scored.append((chunk, score))
        }

        return scored
            .filter { $0.score > 0.02 }
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map(\.chunk)
    }

    nonisolated private static func sentenceEmbedding(for text: String) -> NLEmbedding? {
        let language = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
        return NLEmbedding.sentenceEmbedding(for: language)
    }

    nonisolated private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }

    /// Lowercased word tokens, script-aware: CJK text is split into
    /// bigrams so overlap works without spaces.
    nonisolated static func tokens(of text: String) -> Set<String> {
        var result = Set<String>()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = text[range].lowercased()
            if token.count >= 2 {
                result.insert(token)
            } else if let scalar = token.unicodeScalars.first,
                      scalar.value >= 0x2E80 {
                // Single CJK character: keep it (they carry word-level meaning).
                result.insert(token)
            }
            return true
        }
        return result
    }
}
