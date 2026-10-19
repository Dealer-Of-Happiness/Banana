//
//  MLXIntegration.swift
//  AIGoodbye
//
//  mlx-swift-lm 3.x no longer bundles a tokenizer or a Hugging Face client:
//  it asks for a `TokenizerLoader` and, to download, a `Downloader`. These
//  adapt swift-transformers (Tokenizers and Hub), the same implementations
//  2.x used internally, so tokenization and chat templates behave as before.
//
//  The app normally loads from a directory the prefetcher has already
//  filled; the downloader is only the fallback for a file an older download
//  never fetched, and it writes into that same directory.
//

import Foundation
import Hub
import MLXLMCommon
import Tokenizers

/// swift-transformers' tokenizer behind mlx-swift-lm's protocol.
nonisolated struct TransformersTokenizer: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers calls it `decode(tokens:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Loads the tokenizer from a model's own folder.
nonisolated struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizer(try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// Downloads through the app's own `HubApi`, so the files land in the same
/// `<downloadBase>/models/<id>` folder the prefetcher fills and the loader
/// reads. A downloader pointed anywhere else would fetch the whole model a
/// second time.
nonisolated struct AppHubDownloader: MLXLMCommon.Downloader {
    let hub: HubApi

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await hub.snapshot(
            from: id,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

/// What every chat template is rendered with, and the guard on what comes
/// back.
nonisolated enum ChatTemplateOptions {

    /// Qwen3.5 4B and 9B think out loud by default - pages of "Thinking
    /// Process:" before a one-line answer, half a minute on a phone - while
    /// 0.8B and 2B don't; their templates differ only in that default.
    /// Thinking is never wanted here (voice, translation and Describe
    /// Surroundings need the answer now), and templates that don't know the
    /// flag ignore it.
    static let context: [String: any Sendable] = ["enable_thinking": false]

    /// The part of a model's output a person should see. A model whose
    /// template ignores the flag above (one added from Hugging Face, say)
    /// can still reason first: hide a leading `<think>` block while it is
    /// open, and everything up to its `</think>` once it closes.
    static func visibleAnswer(_ raw: String) -> String {
        if let close = raw.range(of: "</think>", options: .backwards) {
            return String(raw[close.upperBound...]).trimmingLeadingWhitespace()
        }
        if raw.trimmingLeadingWhitespace().hasPrefix("<think>") {
            return ""
        }
        return raw
    }
}

private extension String {
    nonisolated func trimmingLeadingWhitespace() -> String {
        String(drop(while: { $0.isWhitespace }))
    }
}
