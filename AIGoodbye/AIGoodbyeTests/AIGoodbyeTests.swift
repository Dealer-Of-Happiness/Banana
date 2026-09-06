//
//  AIGoodbyeTests.swift
//  AIGoodbyeTests
//
//  Unit tests for the v3.0 engine logic.
//

import Testing
import Foundation
import UIKit
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

struct HandsFreeTranslationTests {

    /// Hands-free alternates turns, but must recover when someone speaks out
    /// of order - the words decide, not the schedule.
    @Test @MainActor func detectsWhichSideIsSpeaking() {
        let mine = AppLanguage.english
        let theirs = AppLanguage.spanish

        #expect(TranslateModeView.detectedSide(
            of: "Could you tell me where the train station is, please?",
            mine: mine, theirs: theirs) == true)

        #expect(TranslateModeView.detectedSide(
            of: "Buenos días, ¿dónde está la estación de tren por favor?",
            mine: mine, theirs: theirs) == false)
    }

    @Test @MainActor func staysUndecidedOnShortOrForeignInput() {
        // Too short to judge: keep the scheduled turn.
        #expect(TranslateModeView.detectedSide(of: "Ok", mine: .english, theirs: .spanish) == nil)
        // Neither configured language: don't guess.
        #expect(TranslateModeView.detectedSide(
            of: "これは日本語の文章です。駅はどこですか。",
            mine: .english, theirs: .spanish) == nil)
    }

    @Test @MainActor func cleanTranslationKeepsTimesAndRatios() {
        #expect(TranslateModeView.cleanTranslation("Il est 10:30 du matin") == "Il est 10:30 du matin")
        #expect(TranslateModeView.cleanTranslation("Translation: Hola amigo") == "Hola amigo")
        #expect(TranslateModeView.cleanTranslation("\"Hola amigo\"") == "Hola amigo")
    }
}

struct RecordingSummarizerTests {

    /// A meeting transcript is far longer than any small model's context, so
    /// it is sliced - and not one word may be lost on the way.
    @Test func slicesCoverTheWholeTranscript() {
        let sentences = (0..<200).map { "This is sentence number \($0) of the meeting." }
        let transcript = sentences.joined(separator: " ")
        let slices = RecordingSummarizer.slices(of: transcript, maxCharacters: 500)

        #expect(slices.count > 1)
        for slice in slices {
            #expect(slice.count <= 500)
            #expect(!slice.isEmpty)
        }
        let rejoined = slices.joined(separator: " ")
        for sentence in [sentences[0], sentences[97], sentences[199]] {
            #expect(rejoined.contains(sentence), "Lost: \(sentence)")
        }
    }

    @Test func shortTranscriptIsOneSlice() {
        let slices = RecordingSummarizer.slices(of: "We agreed to ship on Friday.")
        #expect(slices == ["We agreed to ship on Friday."])
        #expect(RecordingSummarizer.slices(of: "   ").isEmpty)
    }

    /// Some recognizers return a wall of words with no punctuation at all;
    /// that must still be sliced rather than sent whole or dropped.
    @Test func splitsUnpunctuatedSpeech() {
        let wall = String(repeating: "word ", count: 500)   // 2,500 chars, no periods
        let slices = RecordingSummarizer.slices(of: wall, maxCharacters: 400)
        #expect(slices.count >= 6)
        for slice in slices { #expect(slice.count <= 400) }
    }

    @Test func cleanTitleStripsLabelsQuotesAndExtraLines() {
        #expect(RecordingSummarizer.cleanTitle("\"Budget review meeting\"") == "Budget review meeting")
        #expect(RecordingSummarizer.cleanTitle("Title: Budget review") == "Budget review")
        #expect(RecordingSummarizer.cleanTitle("## Budget review\n\nHere is why...") == "Budget review")
    }

    @Test @MainActor func fallbackTitleUsesTheOpeningWords() {
        let title = RecordingSummarizer.fallbackTitle(
            from: "Okay so today we are reviewing the quarterly budget and the hiring plan."
        )
        #expect(title.hasPrefix("Okay so today"))
        #expect(title.count <= 60)
        #expect(!RecordingSummarizer.fallbackTitle(from: "").isEmpty)
    }
}

struct RecordingExportTests {

    @Test @MainActor func durationIsReadable() {
        #expect(ConversationExporter.durationText(0) == "0:00")
        #expect(ConversationExporter.durationText(65) == "1:05")
        #expect(ConversationExporter.durationText(3725) == "1:02:05")
    }

    @Test @MainActor func markdownKeepsSummaryAndTranscript() {
        let recording = Recording(
            title: "Budget review",
            duration: 125,
            transcript: "We agreed to ship on Friday.",
            summary: "## Summary\nA budget review.",
            audioFileName: nil,
            languageCode: "en-US"
        )
        let markdown = ConversationExporter.markdown(for: recording)
        #expect(markdown.contains("# Budget review"))
        #expect(markdown.contains("A budget review."))
        #expect(markdown.contains("We agreed to ship on Friday."))
        #expect(markdown.contains("2:05"))
    }
}

struct ContextWindowTests {

    /// The context slider promises a bound on memory. Without a cap the
    /// key-value cache grows for the whole conversation and the app is
    /// killed mid-answer, so a big model must get a smaller window than the
    /// user asked for.
    /// A fixed budget, so the result doesn't depend on whatever machine the
    /// test happens to run on.
    private let budgetGB = 6

    @Test @MainActor func bigModelsGetASmallerWindowThanRequested() {
        let bigWindow = MLXService.effectiveContextWindow(
            for: .qwen3VL8BPro, requested: 32_768, usableMemoryGB: budgetGB
        )
        let smallWindow = MLXService.effectiveContextWindow(
            for: .smolVLM2, requested: 32_768, usableMemoryGB: budgetGB
        )

        #expect(bigWindow < 32_768, "A 5.8 GB model must not get the full 32K window")
        #expect(bigWindow < smallWindow, "A 5.8 GB model must not get the same window as a 500 MB one")
        // Never so small that a conversation is impossible.
        #expect(bigWindow >= 2048)
    }

    @Test @MainActor func aModestRequestIsHonoured() {
        let window = MLXService.effectiveContextWindow(
            for: .smolVLM2, requested: 4096, usableMemoryGB: budgetGB
        )
        #expect(window == 4096)
    }
}

struct SceneDescriptionRepetitionTests {

    /// Continuous mode must not say the same thing every two seconds while
    /// the user stands still - that is the fastest way to get switched off.
    @Test @MainActor func nearIdenticalDescriptionsAreSuppressed() {
        let first = "A kitchen counter with a white mug and a kettle."
        let reworded = "A white mug and a kettle sitting on a kitchen counter."
        #expect(SceneDescriptionView.isSubstantiallySame(reworded, as: first))
    }

    @Test @MainActor func genuinelyNewScenesAreSpoken() {
        let first = "A kitchen counter with a white mug and a kettle."
        let different = "A busy pavement with cars passing and a bicycle leaning on a railing."
        #expect(!SceneDescriptionView.isSubstantiallySame(different, as: first))
        // Nothing said yet is never a repeat.
        #expect(!SceneDescriptionView.isSubstantiallySame(first, as: ""))
    }

    /// The fast first impression is a subset of the fuller description that
    /// follows it. Suppressing the fuller one would silence the answer the
    /// user was actually waiting for.
    @Test @MainActor func aFullerDescriptionIsNotTreatedAsARepeat() {
        let impression = "A kitchen counter."
        let fuller = "A kitchen counter with a white mug, a kettle, a wooden bowl of fruit and a window behind."
        #expect(!SceneDescriptionView.isSubstantiallySame(fuller, as: impression))
    }

    /// Chinese and Japanese have no spaces, so word-splitting on whitespace
    /// makes a whole description one token and suppression never fires.
    @Test @MainActor func chineseRepetitionIsAlsoSuppressed() {
        let first = "厨房台面上有一个白色杯子和一个水壶。"
        let reworded = "台面上有一个水壶和一个白色杯子。"
        let different = "繁忙的人行道上有汽车经过和一辆自行车。"
        #expect(SceneDescriptionView.isSubstantiallySame(reworded, as: first))
        #expect(!SceneDescriptionView.isSubstantiallySame(different, as: first))
    }
}

struct ImageOrientationTests {

    /// A portrait photo carries `.right`; handing its raw `cgImage` to a
    /// vision model feeds the model a picture rotated 90 degrees while the
    /// user sees it upright on screen.
    @Test @MainActor func rotatedImagesAreMadeUpright() {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let size = CGSize(width: 40, height: 20)
        let base = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        guard let cgImage = base.cgImage else { return }
        let rotated = UIImage(cgImage: cgImage, scale: 1, orientation: .right)

        // A portrait capture reports swapped dimensions but keeps the raw
        // landscape bitmap - which is exactly what used to reach the model.
        #expect(rotated.imageOrientation == .right)
        #expect(rotated.size.width < rotated.size.height)
        #expect(cgImage.width > cgImage.height)

        let upright = ImageNormalizer.upright(rotated)
        #expect(upright.imageOrientation == .up)
        #expect(upright.size == rotated.size)
        // The pixels themselves are now portrait, so `cgImage` is safe to use.
        #expect(upright.cgImage.map { $0.width < $0.height } == true)
    }

    @Test @MainActor func alreadyUprightImagesAreUntouched() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        #expect(ImageNormalizer.upright(image) === image)
        #expect(ImageNormalizer.cgOrientation(.right) == .right)
    }
}

struct CustomModelTests {

    @Test func normalizesEveryWayPeopleWriteAModelAddress() {
        let expected = "mlx-community/Qwen3-VL-2B-Instruct-4bit"
        for input in [
            "mlx-community/Qwen3-VL-2B-Instruct-4bit",
            "  mlx-community/Qwen3-VL-2B-Instruct-4bit  ",
            "https://huggingface.co/mlx-community/Qwen3-VL-2B-Instruct-4bit",
            "huggingface.co/mlx-community/Qwen3-VL-2B-Instruct-4bit/tree/main",
            "https://huggingface.co/mlx-community/Qwen3-VL-2B-Instruct-4bit?library=mlx"
        ] {
            #expect(HuggingFaceValidator.normalize(input) == expected, "Failed on \(input)")
        }
    }

    /// The repo id becomes a directory name, so a path-traversal component
    /// must never survive normalisation.
    @Test func rejectsMalformedAndTraversingAddresses() {
        for input in ["", "justaname", "owner/", "/name", "owner/..", "../owner/name",
                      "https://evil.com/owner/name", "owner/na me"] {
            #expect(HuggingFaceValidator.normalize(input) == nil, "Should reject \(input)")
        }
    }

    @Test func detectsVisionModelsFromConfigOrName() {
        #expect(HuggingFaceValidator.looksLikeVisionModel(
            config: ["vision_config": ["depth": 32]], repoId: "someone/mystery-model"))
        #expect(HuggingFaceValidator.looksLikeVisionModel(
            config: ["architectures": ["Idefics3ForConditionalGeneration"]], repoId: "a/b"))
        #expect(HuggingFaceValidator.looksLikeVisionModel(
            config: [:], repoId: "mlx-community/Qwen3-VL-2B-Instruct-4bit"))
        #expect(!HuggingFaceValidator.looksLikeVisionModel(
            config: ["model_type": "llama"], repoId: "mlx-community/Llama-3.2-3B-Instruct-4bit"))
    }

    /// A text model sent to the vision factory can only fail to load - and
    /// the failed load also evicts whatever model was working.
    @Test func doesNotMistakeTextModelsForVisionModels() {
        // Gemma 3 ships both; the text-only members say so in `model_type`.
        #expect(!HuggingFaceValidator.looksLikeVisionModel(
            config: ["model_type": "gemma3_text",
                     "architectures": ["Gemma3ForCausalLM"]],
            repoId: "mlx-community/gemma-3-1b-it-4bit"))
        // "vl" must be a whole word, not two letters inside an owner's name.
        #expect(!HuggingFaceValidator.looksLikeVisionModel(
            config: ["model_type": "llama"], repoId: "vlad/Llama-3.2-3B-4bit"))
        // ...but a real one is still recognized from the repo id alone.
        #expect(HuggingFaceValidator.looksLikeVisionModel(
            config: [:], repoId: "mlx-community/gemma-3-4b-it-vl-4bit"))
    }

    /// The working set is what has to fit in memory; the tier is what the
    /// UI shows. Conflating them is how an app gets killed mid-answer.
    @Test func memoryEstimatesAreConservativeAndOrdered() {
        let twoB: Int64 = 1_780_000_000
        let eightB: Int64 = 5_760_000_000
        #expect(AIModel.workingSetGB(forModelBytes: twoB) < AIModel.workingSetGB(forModelBytes: eightB))
        #expect(AIModel.workingSetGB(forModelBytes: eightB) >= 7)
        #expect(AIModel.recommendedRAMGB(forModelBytes: eightB) >= 12)
        // Never below the model's own size.
        #expect(AIModel.workingSetGB(forModelBytes: eightB) >= 6)
    }

    @Test func customModelIdsCannotCollideWithBuiltIns() {
        let spec = CustomModelSpec(repoId: "mlx-community/Anything-4bit",
                                   displayName: "Anything", sizeBytes: 1_000_000_000,
                                   supportsVision: false)
        let model = AIModel(custom: spec)
        #expect(model.isCustom)
        #expect(!AIModel.builtInModels.contains { $0.id == model.id })
        #expect(model.huggingFaceId == spec.repoId)
        #expect(!model.supportsVision)
    }
}

struct TextRecognizerTests {

    /// More languages make Vision slower and less accurate, and English is
    /// always worth having as a fallback for Latin script.
    @Test @MainActor func recognitionLanguagesAreCappedAndIncludeEnglish() {
        for language in [AppLanguage.russian, .japanese, .mandarin, .cantonese, .greek] {
            let codes = TextRecognizer.languages(for: language).map(\.minimalIdentifier)
            #expect(codes.count <= 3)
            #expect(!codes.isEmpty)
            #expect(codes.contains { $0.hasPrefix("en") })
            #expect(Set(codes).count == codes.count, "Duplicates in \(codes)")
        }
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
