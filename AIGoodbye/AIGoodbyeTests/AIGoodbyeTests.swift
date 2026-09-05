//
//  AIGoodbyeTests.swift
//  AIGoodbyeTests
//
//  Unit tests for the v3.0 engine logic.
//

import Testing
import Foundation
@testable import AIGoodbye

struct HistoryTrimmingTests {

    @Test func keepsRecentMessagesWithinBudget() {
        let history: [(role: String, content: String)] = (0..<40).map {
            (role: $0 % 2 == 0 ? "user" : "assistant", content: "Message \($0) " + String(repeating: "x", count: 500))
        }
        let trimmed = MLXService.trimHistory(history, tokenBudget: 4096)

        #expect(!trimmed.isEmpty)
        #expect(trimmed.count < history.count)
        // Most recent message must survive.
        #expect(trimmed.last?.content.hasPrefix("Message 39") == true)
        // Order preserved.
        let indices = trimmed.compactMap { entry in
            Int(entry.content.split(separator: " ")[1])
        }
        #expect(indices == indices.sorted())
    }

    @Test func capsOversizedSingleMessages() {
        let huge = String(repeating: "a", count: 20_000)
        let trimmed = MLXService.trimHistory([("user", huge)], tokenBudget: 32_768)
        #expect(trimmed.count == 1)
        #expect(trimmed[0].content.count < 5_000)
        #expect(trimmed[0].content.contains("[Truncated]"))
    }

    @Test func emptyHistoryStaysEmpty() {
        let trimmed = MLXService.trimHistory([], tokenBudget: 8192)
        #expect(trimmed.isEmpty)
    }
}

struct ModelCatalogTests {

    @Test func modelIdsAreUnique() {
        let ids = AIModel.allModels.map(\.id) + [AIModel.appleIntelligence.id]
        #expect(Set(ids).count == ids.count)
    }

    @Test func lookupFindsEveryModel() {
        for model in AIModel.allModels {
            #expect(AIModel.model(withId: model.id)?.id == model.id)
        }
        #expect(AIModel.model(withId: AIModel.appleIntelligence.id)?.backend == .appleIntelligence)
        #expect(AIModel.model(withId: "does-not-exist") == nil)
    }

    @Test func downloadableModelsHaveHuggingFaceIds() {
        for model in AIModel.allModels {
            #expect(model.backend == .mlx)
            #expect(model.huggingFaceId?.isEmpty == false)
            #expect(model.sizeBytes > 0)
        }
    }

    @Test func recommendedModelMatchesDeviceTier() {
        let recommended = AIModel.recommendedDownloadModel
        if DeviceCapability.physicalMemoryGB >= 6 {
            #expect(recommended.id == AIModel.qwen3VL2B.id)
        } else {
            #expect(recommended.id == AIModel.smolVLM2.id)
        }
        #expect(!recommended.isLegacy)
    }
}

struct LegalTextTests {

    @Test func legalCopyIsCompleteAndOffline() {
        #expect(LegalText.sections.count == 6)
        let allText = LegalText.sections.map { $0.title + " " + $0.body }.joined(separator: " ")
        // The one source of truth must reflect the offline reality.
        #expect(!allText.lowercased().contains("api key"))
        #expect(allText.contains("aigoodbye.ai"))
        #expect(allText.contains("marketing@dealerofhappiness.com"))
    }
}

struct LocalizationTests {

    /// Every non-automatic app language must ship a resource bundle;
    /// without one, L10n silently falls back to English.
    @Test func everyLanguageHasABundle() {
        for language in AppLanguage.allCases where language != .automatic && language != .english {
            let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj")
            #expect(path != nil, "Missing lproj for \(language.rawValue)")
        }
    }

    /// Guard against the 3.0.0 bug class: hand-written positional catalog
    /// keys (%1$@) that String(localized:) never generates at runtime,
    /// leaving translations dead. If this multi-argument key resolves to
    /// Russian, the runtime and catalog key formats agree.
    @Test @MainActor func multiArgumentKeysResolveInOtherLanguages() {
        L10n.apply(.russian)
        defer { L10n.apply(.automatic) }
        let text = L10n.text("Couldn't read \("f"): \("e")")
        #expect(text != "Couldn't read f: e", "Multi-arg key fell back to English — key format mismatch")
    }

    /// A translated language must actually resolve differently from English
    /// through the instant-switch bundle routing.
    @Test @MainActor func bundleRoutingResolvesTranslations() {
        L10n.apply(.russian)
        defer { L10n.apply(.automatic) }
        let russian = L10n.text("Settings")
        #expect(russian != "Settings", "Russian bundle should override English")
    }
}

struct DocumentIndexTests {

    @Test func chunkingCoversWholeDocumentWithOverlap() {
        let sentence = "The quick brown fox jumps over the lazy dog. "
        let text = String(repeating: sentence, count: 200) // ~9,000 chars
        let chunks = DocumentIndex.chunk(text, documentName: "test.txt")

        #expect(chunks.count > 5)
        // Every chunk is reasonably sized.
        for chunk in chunks {
            #expect(chunk.text.count <= 1000)
            #expect(!chunk.text.isEmpty)
        }
        // Positions are sequential.
        #expect(chunks.map(\.position) == Array(0..<chunks.count))
    }

    @Test func shortDocumentIsOneChunk() {
        let chunks = DocumentIndex.chunk("Hello world.", documentName: "hi.txt")
        #expect(chunks.count == 1)
        #expect(chunks[0].text == "Hello world.")
    }

    private func makeChunk(_ text: String, _ position: Int) -> DocumentChunk {
        DocumentChunk(documentName: "doc", text: text, position: position,
                      tokens: DocumentIndex.tokens(of: text))
    }

    @Test func rankingFindsTheRelevantChunk() async {
        var chunks: [DocumentChunk] = (0..<20).map {
            makeChunk("Filler paragraph about weather, sports and cooking recipes number \($0).", $0)
        }
        chunks.append(makeChunk(
            "The warranty period for the espresso machine is 24 months from purchase.", 20
        ))

        let ranked = await DocumentIndex.shared.rank(
            chunks: chunks, question: "How long is the espresso machine warranty?"
        )
        #expect(ranked.first?.position == 20, "The warranty chunk should rank first")
    }

    /// The whole document must be searchable, not just the opening: a fact
    /// buried at the very end has to come back for a targeted question.
    @Test func retrievesFactFromTheEndOfALongDocument() async {
        let filler = String(repeating: "This paragraph discusses general background information. ", count: 400)
        let text = filler + "\n\nThe activation code for the roof module is QX-4417.\n"
        let id = await DocumentIndex.shared.store(name: "manual.txt", fullText: text)
        defer { Task { await DocumentIndex.shared.removeDocument(id) } }

        let context = await DocumentIndex.shared.context(
            for: "What is the activation code for the roof module?", documentIds: [id]
        )
        #expect(context?.contains("QX-4417") == true, "Retrieval must find facts anywhere in the document")
    }

    @Test func chunkCarriesPrecomputedTokens() {
        let chunks = DocumentIndex.chunk("Espresso machine warranty details.", documentName: "d.txt")
        #expect(chunks.first?.tokens.contains("warranty") == true)
    }

    @Test func cjkTokensWork() {
        let tokens = DocumentIndex.tokens(of: "咖啡机的保修期是24个月")
        #expect(!tokens.isEmpty)
    }
}

struct SpeechChunkerTests {

    @Test func detectsCompleteSentences() {
        let text = "First sentence is here. Second one is still stre"
        let slice = SpeechChunker.speakableSlice(of: text, from: text.startIndex)
        #expect(slice != nil)
        #expect(String(text[slice!]) == "First sentence is here.")
    }

    @Test func waitsWhenNoBoundary() {
        let text = "no boundary yet"
        #expect(SpeechChunker.speakableSlice(of: text, from: text.startIndex) == nil)
    }
}

struct SpeechCleanupTests {

    /// The model is told to use Markdown, so the synthesizer must not read
    /// "pound pound", "asterisk", or entire code blocks aloud.
    @Test func stripsMarkdownBeforeSpeaking() {
        let markdown = """
        ## Heading here

        Some **bold** and `inline code` text.

        - First item
        - Second item

        ```swift
        let secret = 42
        print(secret)
        ```
        """
        let spoken = VoiceService.plainSpeech(from: markdown)
        #expect(!spoken.contains("#"))
        #expect(!spoken.contains("**"))
        #expect(!spoken.contains("`"))
        #expect(!spoken.contains("let secret"), "Code block contents must not be read aloud")
        #expect(spoken.contains("Heading here"))
        #expect(spoken.contains("First item"))
    }

    @Test func emptyAndPlainTextSurvive() {
        #expect(VoiceService.plainSpeech(from: "").isEmpty)
        #expect(VoiceService.plainSpeech(from: "Hello there.").contains("Hello there"))
    }
}

struct SpeechVoiceSelectionTests {

    /// Voice codes must be BCP-47 and map to codes iOS actually ships
    /// (zh-Hans has no voice; zh-CN does), otherwise answers are read by an
    /// English voice in every language.
    @Test @MainActor func mapsAppLanguagesToRealVoiceCodes() {
        #expect(!VoiceService.speechCode(for: .mandarin).contains("Hans"))
        for language in [AppLanguage.russian, .japanese, .korean, .french, .german, .mandarin] {
            let code = VoiceService.speechCode(for: language)
            #expect(!code.contains("_"), "\(code) must be BCP-47")
            #expect(!code.isEmpty)
        }
    }
}

struct WeightedLengthTests {

    @Test func cjkTextCostsMoreThanLatin() {
        let latin = String(repeating: "a", count: 100)
        let cjk = String(repeating: "中", count: 100)
        #expect(MLXService.weightedLength(of: latin) == 100)
        #expect(MLXService.weightedLength(of: cjk) > 200)
    }

    @Test func cjkHistoryTrimsTighterThanLatin() {
        let latinHistory: [(role: String, content: String)] = (0..<40).map {
            ($0 % 2 == 0 ? "user" : "assistant", String(repeating: "hello ", count: 100))
        }
        let cjkHistory: [(role: String, content: String)] = (0..<40).map {
            ($0 % 2 == 0 ? "user" : "assistant", String(repeating: "你好啊那么", count: 120))
        }
        let latinTrimmed = MLXService.trimHistory(latinHistory, tokenBudget: 4096)
        let cjkTrimmed = MLXService.trimHistory(cjkHistory, tokenBudget: 4096)
        // Same visual length, but CJK carries more tokens per character, so
        // fewer messages must fit.
        #expect(cjkTrimmed.count < latinTrimmed.count)
    }
}
