//
//  DocumentIndex.swift
//  AIGoodbye
//
//  The document brain: fully offline retrieval over attached documents.
//
//  Whole documents are extracted once, stored on disk, split into
//  overlapping chunks, and scored per question with a two-stage ranker:
//  a fast keyword pass over every chunk (works in every language, zero
//  assets), then Apple's on-device sentence embeddings over only the top
//  candidates. The best chunks become the model's context for that
//  question, so the AI can answer about a 300-page PDF without ever
//  sending a byte anywhere.
//
//  All indexing and ranking runs off the main actor: a large document
//  would otherwise freeze the UI at the exact moment the user hits send.
//

import Foundation
import NaturalLanguage

/// A passage of a document, with its keyword tokens precomputed once.
/// Plain data, deliberately `nonisolated`: it is produced inside the
/// `DocumentIndex` actor and read from background ranking work, so isolating
/// its stored properties to the main actor would force a hop per field.
nonisolated struct DocumentChunk: Sendable {
    let documentName: String
    let text: String
    let position: Int
    let tokens: Set<String>
}

/// Off-main-actor store and ranker. Chunking, embedding and file I/O all
/// happen inside this actor.
actor DocumentIndex {

    static let shared = DocumentIndex()
    private init() {}

    /// Chunk cache, bounded so a session with many documents can't grow
    /// without limit next to a multi-gigabyte model.
    ///
    /// Bounded by total characters rather than document count: a chat can
    /// reference more documents than a count-based cache holds, and then
    /// every single message re-reads and re-chunks all of them from disk.
    private var chunkCache: [UUID: [DocumentChunk]] = [:]
    private var cacheOrder: [UUID] = []
    private var cachedCharacters = 0
    private var nameCache: [UUID: String] = [:]
    private static let maxCachedCharacters = 2_000_000

    /// Reused embedding models (loading one is expensive). Each is tens of
    /// megabytes, so only a couple are kept.
    private var embeddings: [NLLanguage: NLEmbedding] = [:]
    private var embeddingOrder: [NLLanguage] = []
    private static let maxCachedEmbeddings = 2

    /// Release everything re-creatable. Called on a memory warning, when the
    /// alternative is the system killing the app outright.
    func purgeCaches() {
        chunkCache.removeAll()
        cacheOrder.removeAll()
        cachedCharacters = 0
        embeddings.removeAll()
        embeddingOrder.removeAll()
    }

    // MARK: - Storage

    /// Documents live in Application Support (not backed up: this is a
    /// local cache of the user's own files, and the app promises the text
    /// stays on the device).
    static func documentsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("AiGoodbyeDocs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    private static func textURL(for id: UUID) -> URL {
        documentsDirectory().appendingPathComponent("\(id.uuidString).txt")
    }

    private static func nameURL(for id: UUID) -> URL {
        documentsDirectory().appendingPathComponent("\(id.uuidString).name")
    }

    /// Store a document's full extracted text. Returns its id.
    func store(name: String, fullText: String) -> UUID {
        let id = UUID()
        let textURL = Self.textURL(for: id)
        try? fullText.write(to: textURL, atomically: true, encoding: .utf8)
        // Encrypt at rest while the device is locked.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: textURL.path
        )
        try? name.write(to: Self.nameURL(for: id), atomically: true, encoding: .utf8)
        cache(Self.chunk(fullText, documentName: name), for: id)
        nameCache[id] = name
        return id
    }

    func documentName(for id: UUID) -> String? {
        if let cached = nameCache[id] { return cached }
        let name = try? String(contentsOf: Self.nameURL(for: id), encoding: .utf8)
        if let name { nameCache[id] = name }
        return name
    }

    func removeDocument(_ id: UUID) {
        if let existing = chunkCache[id] {
            cachedCharacters -= existing.reduce(0) { $0 + $1.text.count }
        }
        chunkCache[id] = nil
        cacheOrder.removeAll { $0 == id }
        nameCache[id] = nil
        try? FileManager.default.removeItem(at: Self.textURL(for: id))
        try? FileManager.default.removeItem(at: Self.nameURL(for: id))
    }

    /// Delete stored text for documents no longer referenced by any chat.
    ///
    /// Anything written in the last few minutes is spared regardless. The
    /// launch sweep races the share extension's handoff: a document stored
    /// milliseconds earlier isn't attached to any conversation yet, and
    /// deleting it leaves the user looking at a document chip for a file
    /// that no longer exists.
    func removeDocuments(notIn keepIds: Set<UUID>) {
        let dir = Self.documentsDirectory()
        let cutoff = Date().addingTimeInterval(-300)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for file in files {
            let base = (file as NSString).deletingPathExtension
            guard let id = UUID(uuidString: base), !keepIds.contains(id) else { continue }
            let url = dir.appendingPathComponent(file)
            if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
               created > cutoff {
                continue
            }
            removeDocument(id)
        }
    }

    private func cache(_ chunks: [DocumentChunk], for id: UUID) {
        if let existing = chunkCache[id] {
            cachedCharacters -= existing.reduce(0) { $0 + $1.text.count }
        }
        chunkCache[id] = chunks
        cachedCharacters += chunks.reduce(0) { $0 + $1.text.count }
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        // Evict by size, and never evict the document just added.
        while cachedCharacters > Self.maxCachedCharacters, cacheOrder.count > 1 {
            let evicted = cacheOrder.removeFirst()
            if let dropped = chunkCache[evicted] {
                cachedCharacters -= dropped.reduce(0) { $0 + $1.text.count }
            }
            chunkCache[evicted] = nil
        }
    }

    private func chunks(for id: UUID) -> [DocumentChunk] {
        if let cached = chunkCache[id] {
            // Refresh recency.
            cacheOrder.removeAll { $0 == id }
            cacheOrder.append(id)
            return cached
        }
        guard let text = try? String(contentsOf: Self.textURL(for: id), encoding: .utf8) else { return [] }
        let name = documentName(for: id) ?? "document"
        let chunks = Self.chunk(text, documentName: name)
        cache(chunks, for: id)
        return chunks
    }

    // MARK: - Retrieval

    /// The most relevant document passages for a question, formatted as
    /// context for the model. Returns nil when nothing is attached or
    /// nothing matches. Runs entirely off the main actor.
    func context(for question: String, documentIds: [UUID], budget: Int = 6000) -> String? {
        let allChunks = documentIds.flatMap { chunks(for: $0) }
        guard !allChunks.isEmpty else { return nil }

        let ranked = rank(chunks: allChunks, question: question)
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
    /// boundaries where possible. Tokens are computed once, here, so
    /// ranking never re-tokenizes the document.
    nonisolated static func chunk(
        _ text: String,
        documentName: String,
        size: Int = 900,
        overlap: Int = 150
    ) -> [DocumentChunk] {
        let cleaned = text.replacingOccurrences(of: "\r", with: "")
        guard cleaned.count > size else {
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? []
                : [DocumentChunk(documentName: documentName, text: trimmed,
                                 position: 0, tokens: tokens(of: trimmed))]
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
                chunks.append(DocumentChunk(documentName: documentName, text: piece,
                                            position: position, tokens: tokens(of: piece)))
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

    /// Two-stage ranking: a cheap keyword pass over every chunk, then
    /// on-device sentence embeddings over only the best candidates (running
    /// an embedding model over hundreds of chunks would take seconds).
    func rank(chunks: [DocumentChunk], question: String, topK: Int = 6) -> [DocumentChunk] {
        let questionTokens = Self.tokens(of: question)
        guard !questionTokens.isEmpty else { return Array(chunks.prefix(topK)) }
        let questionWeight = Double(questionTokens.reduce(0) { $0 + $1.count })

        // Stage 1: keyword overlap, weighted by token length.
        var keywordScored: [(chunk: DocumentChunk, score: Double)] = []
        for chunk in chunks where !chunk.tokens.isEmpty {
            let overlap = questionTokens.intersection(chunk.tokens)
            guard !overlap.isEmpty else { continue }
            let score = overlap.reduce(0.0) { $0 + Double($1.count) } / max(questionWeight, 1)
            keywordScored.append((chunk, score))
        }
        // Nothing matched by keyword: fall back to the opening of the
        // document so summaries and vague questions still have material.
        guard !keywordScored.isEmpty else { return Array(chunks.prefix(topK)) }

        keywordScored.sort { $0.score > $1.score }
        let candidates = Array(keywordScored.prefix(30))

        // Stage 2: semantic re-rank of the shortlist only.
        guard let embedding = embedding(for: question),
              let questionVector = embedding.vector(for: question) else {
            return candidates.prefix(topK).map(\.chunk)
        }

        let reranked = candidates.map { candidate -> (chunk: DocumentChunk, score: Double) in
            guard let vector = embedding.vector(for: String(candidate.chunk.text.prefix(512))) else {
                return candidate
            }
            return (candidate.chunk, candidate.score + 0.8 * Self.cosine(questionVector, vector))
        }

        return reranked
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map(\.chunk)
    }

    /// Cached sentence-embedding model for the question's language. Bounded:
    /// each model is tens of megabytes and they would otherwise accumulate
    /// one per language ever seen, next to a multi-gigabyte model.
    private func embedding(for text: String) -> NLEmbedding? {
        let language = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
        if let cached = embeddings[language] {
            embeddingOrder.removeAll { $0 == language }
            embeddingOrder.append(language)
            return cached
        }
        guard let model = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        embeddings[language] = model
        embeddingOrder.append(language)
        while embeddingOrder.count > Self.maxCachedEmbeddings {
            embeddings[embeddingOrder.removeFirst()] = nil
        }
        return model
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

    /// Lowercased word tokens, script-aware: CJK characters are kept
    /// individually so overlap works without spaces.
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
