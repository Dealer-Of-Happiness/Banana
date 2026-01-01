//
//  KnowledgeBase.swift
//  BananaAI
//
//  Vector-based knowledge storage for RAG
//  Stores document chunks with embeddings for semantic search
//

import Foundation
import GRDB

/// Local knowledge base for document storage and retrieval
actor KnowledgeBase {
    private var database: DatabaseQueue?
    private let embeddingModel: EmbeddingModel

    init() {
        self.embeddingModel = EmbeddingModel()
    }

    // MARK: - Initialization

    func initialize() async throws {
        let dbPath = try getDatabasePath()
        database = try DatabaseQueue(path: dbPath)

        try await database?.write { db in
            // Documents table
            try db.create(table: "documents", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("added_date", .datetime).notNull()
            }

            // Chunks table (for RAG)
            try db.create(table: "chunks", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("document_id", .text).notNull().references("documents", onDelete: .cascade)
                t.column("content", .text).notNull()
                t.column("embedding", .blob) // Serialized float array
                t.column("chunk_index", .integer).notNull()
            }

            // Create index for faster lookups
            try db.create(index: "idx_chunks_document", on: "chunks", columns: ["document_id"], ifNotExists: true)
        }
    }

    private func getDatabasePath() throws -> String {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dbDir = documentsPath.appendingPathComponent("database")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        return dbDir.appendingPathComponent("knowledge.sqlite").path
    }

    // MARK: - Document Management

    func addDocument(_ document: Document, chunks: [String]) async throws {
        guard let db = database else { throw KnowledgeError.notInitialized }

        try await db.write { db in
            // Insert document
            try db.execute(
                sql: "INSERT INTO documents (id, name, type, size, added_date) VALUES (?, ?, ?, ?, ?)",
                arguments: [document.id, document.name, document.type, document.size, document.addedDate]
            )

            // Insert chunks with embeddings
            for (index, chunk) in chunks.enumerated() {
                let embedding = await self.embeddingModel.embed(chunk)
                let embeddingData = embedding.withUnsafeBytes { Data($0) }

                try db.execute(
                    sql: "INSERT INTO chunks (document_id, content, embedding, chunk_index) VALUES (?, ?, ?, ?)",
                    arguments: [document.id, chunk, embeddingData, index]
                )
            }
        }
    }

    func getAllDocuments() async -> [Document] {
        guard let db = database else { return [] }

        do {
            return try await db.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.*, COUNT(c.id) as chunk_count
                    FROM documents d
                    LEFT JOIN chunks c ON c.document_id = d.id
                    GROUP BY d.id
                    ORDER BY d.added_date DESC
                """)

                return rows.map { row in
                    Document(
                        id: row["id"],
                        name: row["name"],
                        type: row["type"],
                        size: row["size"],
                        chunks: row["chunk_count"],
                        addedDate: row["added_date"]
                    )
                }
            }
        } catch {
            return []
        }
    }

    func deleteDocument(id: String) async {
        guard let db = database else { return }
        try? await db.write { db in
            try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [id])
        }
    }

    func getTotalChunks() async -> Int {
        guard let db = database else { return 0 }
        return (try? await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? 0
        }) ?? 0
    }

    func getStorageSize() async -> String {
        guard let db = database else { return "0 MB" }
        do {
            let path = try getDatabasePath()
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size = attrs[.size] as? Int64 ?? 0
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        } catch {
            return "Unknown"
        }
    }

    func clearAll() async {
        guard let db = database else { return }
        try? await db.write { db in
            try db.execute(sql: "DELETE FROM chunks")
            try db.execute(sql: "DELETE FROM documents")
        }
    }

    // MARK: - Semantic Search

    func search(query: String, topK: Int = 5) async -> [String] {
        guard let db = database else { return [] }

        let queryEmbedding = await embeddingModel.embed(query)

        do {
            return try await db.read { db in
                let rows = try Row.fetchAll(db, sql: "SELECT content, embedding FROM chunks")

                // Calculate cosine similarity for each chunk
                var scored: [(score: Float, content: String)] = []

                for row in rows {
                    let content: String = row["content"]
                    if let embeddingData: Data = row["embedding"] {
                        let embedding = embeddingData.withUnsafeBytes { ptr in
                            Array(ptr.bindMemory(to: Float.self))
                        }
                        let similarity = cosineSimilarity(queryEmbedding, embedding)
                        scored.append((similarity, content))
                    }
                }

                // Sort by similarity and return top K
                return scored
                    .sorted { $0.score > $1.score }
                    .prefix(topK)
                    .map { $0.content }
            }
        } catch {
            return []
        }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 0 ? dotProduct / denominator : 0
    }
}

// MARK: - Embedding Model

/// Simple embedding model for semantic similarity
/// In production, use a proper model like all-MiniLM-L6-v2 via CoreML
class EmbeddingModel {
    private let dimensions = 384 // Standard embedding size

    func embed(_ text: String) async -> [Float] {
        // In production, this would use a real embedding model
        // For now, we use a simple hash-based embedding as placeholder

        var embedding = [Float](repeating: 0, count: dimensions)

        // Simple bag-of-words style embedding
        let words = text.lowercased().components(separatedBy: .whitespacesAndNewlines)
        for word in words {
            let hash = abs(word.hashValue)
            let index = hash % dimensions
            embedding[index] += 1
        }

        // Normalize
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            embedding = embedding.map { $0 / norm }
        }

        return embedding
    }
}

// MARK: - Errors

enum KnowledgeError: LocalizedError {
    case notInitialized
    case documentNotFound

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Knowledge base not initialized"
        case .documentNotFound:
            return "Document not found"
        }
    }
}
