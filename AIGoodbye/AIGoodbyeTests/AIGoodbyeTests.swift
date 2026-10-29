//
//  AIGoodbyeTests.swift
//  AIGoodbyeTests
//
//  Unit tests for the v3.0 engine logic.
//

import Testing
import Foundation
import UIKit
import SwiftUI
import Speech
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

    @Test @MainActor func recommendedModelMatchesDeviceTier() {
        let recommended = AIModel.recommendedDownloadModel
        if DeviceCapability.physicalMemoryGB >= 6 {
            #expect(recommended.id == AIModel.qwen3VL2B.id)
        } else {
            // Not Smol Vision any more: it couldn't do "3 apples, give one
            // away, buy four" at any setting. The 8-bit 0.8B where it fits,
            // the 4-bit Lite where only that does.
            #expect([AIModel.qwen35_08B8.id, AIModel.qwen35_08B.id].contains(recommended.id))
            if AIModel.qwen35_08B8.fitsThisDevice() { #expect(recommended.id == AIModel.qwen35_08B8.id) }
        }
        #expect(!recommended.isLegacy)
    }

    /// Every model must be offered where it fits and nowhere else. Budgets
    /// are what a model may use (`modelMemoryBudgetGB`): a 4 GB iPhone with
    /// about 2.5 GB for the whole app; a 6 GB iPhone with about 4.2 GB; an
    /// 8 or 12 GB iPhone with about 6.3 GB, as an iPhone 18 Pro Max
    /// reported; a 16 GB iPad or Mac with far more.
    @Test @MainActor func modelsLandOnTheirDeviceTier() {
        let phone4GB = 2.5 - 0.3, phone6GB = 4.2 - 0.3, phone12GB = 6.3 - 0.3, big = 10.0

        for model in [AIModel.qwen35_08B8, .qwen35_08B, .smolVLM2] {
            #expect(model.fitsThisDevice(budgetGB: phone4GB), "\(model.name) is for 4 GB iPhones")
        }
        // A 4 GB iPhone that gives the app less (about 2 GB, as some
        // reported) still gets the Lite version.
        #expect(!AIModel.qwen35_08B8.fitsThisDevice(budgetGB: 2.0 - 0.3))
        #expect(AIModel.qwen35_08B.fitsThisDevice(budgetGB: 2.0 - 0.3))
        for model in [AIModel.qwen35_2B, .qwen3VL2B] {
            #expect(model.fitsThisDevice(budgetGB: phone6GB), "\(model.name) is for 6 GB iPhones")
            #expect(!model.fitsThisDevice(budgetGB: phone4GB), "\(model.name) is too big for 4 GB iPhones")
        }
        for model in [AIModel.qwen35_4B, .gemma4E2B] {
            #expect(model.fitsThisDevice(budgetGB: phone12GB), "\(model.name) is for 8 and 12 GB iPhones")
            #expect(!model.fitsThisDevice(budgetGB: phone6GB), "\(model.name) is too big for 6 GB iPhones")
        }
        // The reason for this test: these were offered to 12 GB iPhones,
        // which give one app only about 6.3 GB, and could never load there.
        for model in [AIModel.qwen35_9BPro, .gemma4E4B, .qwen3VL8BPro] {
            #expect(model.fitsThisDevice(budgetGB: big), "\(model.name) is for 16 GB iPads and Macs")
            #expect(!model.fitsThisDevice(budgetGB: phone12GB), "\(model.name) can't load on a 12 GB iPhone")
        }
    }

    /// Every model we ship has a measured memory figure, not a guess from
    /// its file size, and the figures order the way the models do.
    @Test func everyBuiltInModelHasAMeasuredMemoryFigure() {
        for model in AIModel.builtInModels {
            #expect(AIModel.measuredMemoryGB[model.id] != nil, "\(model.name) has no measured memory figure")
        }
        #expect(AIModel.qwen35_08B.memoryNeededGB < AIModel.smolVLM2.memoryNeededGB,
                "The 0.8B model peaks lower than Smol Vision despite the newer architecture")
        #expect(AIModel.qwen35_9BPro.memoryNeededGB > AIModel.qwen35_4B.memoryNeededGB)
    }

    /// The smallest models answer simple questions reliably only with little
    /// randomness; the larger ones keep the Creativity setting as it is.
    @Test func smallModelsGetLessRandomness() {
        #expect(AIModel.qwen35_08B.temperatureScale < 0.5)
        #expect(AIModel.qwen35_08B8.temperatureScale < 0.5)
        #expect(AIModel.smolVLM2.temperatureScale < 0.5)
        for model in [AIModel.qwen3VL2B, .qwen35_2B, .qwen35_4B, .qwen35_9BPro, .gemma4E2B] {
            #expect(model.temperatureScale == 1.0, "\(model.name)")
        }
    }

    /// Thinking models must not show their reasoning: every Qwen3.5 repo's
    /// chat template closes an empty think block unless asked to think,
    /// and the app never asks. Guard the ids so a typo can't point at a
    /// thinking-by-default repo.
    @Test func newGenerationModelsPointAtTheTestedRepos() {
        #expect(AIModel.qwen35_08B.huggingFaceId == "mlx-community/Qwen3.5-0.8B-4bit")
        #expect(AIModel.qwen35_08B8.huggingFaceId == "mlx-community/Qwen3.5-0.8B-8bit")
        #expect(AIModel.qwen35_2B.huggingFaceId == "mlx-community/Qwen3.5-2B-4bit")
        #expect(AIModel.qwen35_4B.huggingFaceId == "mlx-community/Qwen3.5-4B-4bit")
        #expect(AIModel.qwen35_9BPro.huggingFaceId == "mlx-community/Qwen3.5-9B-4bit")
        #expect(AIModel.gemma4E2B.huggingFaceId == "mlx-community/gemma-4-e2b-it-4bit")
        #expect(AIModel.gemma4E4B.huggingFaceId == "mlx-community/gemma-4-e4b-it-4bit")
        for model in AIModel.builtInModels {
            #expect(model.supportsVision, "\(model.name): every built-in model sees images")
        }
    }
}

struct ThinkingTests {

    /// Every template is told not to think; Qwen3.5 4B and 9B do by default.
    @Test func templatesAreToldNotToThink() {
        #expect(ChatTemplateOptions.context["enable_thinking"] as? Bool == false)
    }

    @Test func reasoningIsNeverShown() {
        // Still thinking: nothing to show yet.
        #expect(ChatTemplateOptions.visibleAnswer("<think>\nLet me work this out") == "")
        #expect(ChatTemplateOptions.visibleAnswer("  <think>") == "")
        // Done thinking: only the answer.
        #expect(ChatTemplateOptions.visibleAnswer("<think>\nhmm\n</think>\n\nParis.") == "Paris.")
        // The template opened the block, so only the close tag arrives.
        #expect(ChatTemplateOptions.visibleAnswer("Thinking Process: ...\n</think>\n\nParis.") == "Paris.")
        // An empty block, as Qwen3.5 writes when thinking is off.
        #expect(ChatTemplateOptions.visibleAnswer("<think>\n\n</think>\n\nHello") == "Hello")
        // Ordinary answers pass through untouched.
        #expect(ChatTemplateOptions.visibleAnswer("Paris is on the Seine.") == "Paris is on the Seine.")
        #expect(ChatTemplateOptions.visibleAnswer("") == "")
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
    @Test func retrievesFactFromTheEndOfALongDocument() async throws {
        let filler = String(repeating: "This paragraph discusses general background information. ", count: 400)
        let text = filler + "\n\nThe activation code for the roof module is QX-4417.\n"
        let id = try await DocumentIndex.shared.store(name: "manual.txt", fullText: text)
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

struct ConversationListLayoutTests {
    /// The sidebar needs regular width AND room for a usable chat beside it.
    @Test func sidebarNeedsRegularWidthAndRoom() {
        // iPad landscape, iPhone Duo open like a book.
        #expect(MainView.usesSidebar(sizeClass: .regular, width: 1024))
        #expect(MainView.usesSidebar(sizeClass: .regular, width: 951))
        // iPad mini held upright: just wide enough.
        #expect(MainView.usesSidebar(sizeClass: .regular, width: 744))
        // iPhone Duo inner display held upright: regular, but too narrow.
        #expect(!MainView.usesSidebar(sizeClass: .regular, width: 669))
        // Half of a 13-inch iPad in landscape.
        #expect(!MainView.usesSidebar(sizeClass: .regular, width: 678))
        // Any compact window, however wide (iPhone landscape).
        #expect(!MainView.usesSidebar(sizeClass: .compact, width: 852))
        #expect(!MainView.usesSidebar(sizeClass: nil, width: 1024))
    }

    @Test func sidebarWidthStaysWithinReason() {
        #expect(MainView.sidebarWidth(for: 744) == 280)
        #expect(MainView.sidebarWidth(for: 1024) == 1024 * 0.34)
        #expect(MainView.sidebarWidth(for: 1366) == 360)
    }

    @Test func hiddenListClearsTheLeadingInset() {
        // Parked fully off-screen, including the inset beside the Dynamic Island.
        #expect(MainView.listOffset(reveal: 0, listWidth: 300, leadingInset: 59) == -359)
        // Fully revealed: flush with the window's leading edge.
        #expect(MainView.listOffset(reveal: 300, listWidth: 300, leadingInset: 59) == 0)
        // Half way through a drag.
        #expect(MainView.listOffset(reveal: 150, listWidth: 300, leadingInset: 0) == -150)
    }
}

struct MemoryCaptureTests {
    /// The Memory screen's tip is translated into every language, so the
    /// phrase it tells people to type must work in every language.
    @Test func recognizesTheRememberPhraseInEveryLanguage() {
        let samples: [(String, String)] = [
            ("Remember that I like tea", "I like tea"),
            ("Note that I like tea", "I like tea"),
            ("Merk dir, dass ich Vegetarier bin", "ich Vegetarier bin"),
            ("Recuerda que vivo en Madrid", "vivo en Madrid"),
            ("Retiens que je suis allergique aux noix", "je suis allergique aux noix"),
            ("Ricorda che lavoro di notte", "lavoro di notte"),
            ("Lembre-se de que moro em Lisboa", "moro em Lisboa"),
            ("Запомни, что я не ем мясо", "я не ем мясо"),
            ("Запам'ятай, що я з Києва", "я з Києва"),
            ("Θυμήσου ότι μένω στην Αθήνα", "μένω στην Αθήνα"),
            ("기억해 줘: 나는 커피를 안 마셔", "나는 커피를 안 마셔"),
            ("记住：我对花生过敏", "我对花生过敏"),
            ("私は猫を飼っているを覚えておいて", "私は猫を飼っている"),
            ("나는 채식주의자를 기억해 줘", "나는 채식주의자")
        ]
        for (input, expected) in samples {
            #expect(MemoryStore.requestedFact(in: input) == expected, "\(input)")
        }
        #expect(MemoryStore.requestedFact(in: "What is the weather like?") == nil)
        #expect(MemoryStore.requestedFact(in: "Remember that ") == nil)
    }
}

struct ConversationTitleTests {
    @Test func titleIsShortInLanguagesWithoutSpaces() {
        let long = String(repeating: "今天天气很好我们去公园散步吧", count: 20)
        let title = Conversation.title(from: long)
        #expect(title.count <= 44)
        #expect(title.hasSuffix("..."))
    }

    @Test func titleKeepsAboutSixWordsAndOneLine() {
        let title = Conversation.title(from: "Hi\nCan you help me plan a trip to Portugal next spring")
        #expect(!title.contains("\n"))
        #expect(title.hasSuffix("..."))
        #expect(title.split(separator: " ").count <= 7)
    }

    @Test func shortMessageIsItsOwnTitle() {
        #expect(Conversation.title(from: "Hello there") == "Hello there")
    }

    @Test func previewDropsMarkdownMarkers() {
        let markdown = "## Summary\n\n**Key terms**\n- 12-month lease from **November 1**\n1. First `step`\n> quoted *word*"
        let preview = Conversation.plainPreview(markdown)
        #expect(preview == "Summary Key terms 12-month lease from November 1 First step quoted word")
        #expect(Conversation.plainPreview("a 2*3 product_name x_y").contains("2*3"))
        #expect(Conversation.plainPreview(String(repeating: "word ", count: 50)).count <= 100)
    }
}

struct DocumentTextTests {
    @Test func readsLegacyWindowsEncodings() throws {
        let dir = FileManager.default.temporaryDirectory
        let cyrillic = dir.appendingPathComponent("cp1251.txt")
        let text = "Привет, мир"
        try text.data(using: .windowsCP1251)!.write(to: cyrillic)
        #expect(try DocumentText.read(cyrillic) == text)

        let utf16 = dir.appendingPathComponent("utf16.txt")
        try text.data(using: .utf16)!.write(to: utf16)
        #expect(try DocumentText.read(utf16) == text)
    }
}

// MARK: - Round 2 (product audit) regressions

struct SpokenTextTests {
    /// A streamed "costs 3." must not be spoken before "5 dollars" arrives.
    @Test func decimalsAreNotSentenceEnds() {
        let text = "It costs 3.5 dollars at the market"
        #expect(SpeechChunker.speakableSlice(of: text, from: text.startIndex) == nil)
        let streamed = "It costs 3."
        #expect(SpeechChunker.speakableSlice(of: streamed, from: streamed.startIndex) == nil)
    }

    @Test func linksAreSpokenAsTheirLabel() {
        let spoken = VoiceService.plainSpeech(from: "See [the guide](https://example.com/a) or https://example.com/b now.")
        #expect(spoken.contains("the guide"))
        #expect(!spoken.contains("https"))
        #expect(!spoken.contains("example.com"))
    }
}

struct TranslationCleanupTests {
    @Test func stripsOnlyKnownLabels() {
        #expect(TranslateModeView.cleanTranslation("Translation: Where is the station?") == "Where is the station?")
        #expect(TranslateModeView.cleanTranslation("Перевод: Где вокзал?") == "Где вокзал?")
        // A real leading clause is part of the sentence, not a label.
        #expect(TranslateModeView.cleanTranslation("Warning: wet floor") == "Warning: wet floor")
        #expect(TranslateModeView.cleanTranslation("Note: bring ID") == "Note: bring ID")
    }
}

struct RichDocumentTextTests {
    @Test func readsRTFAsPlainText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sample-\(UUID().uuidString).rtf")
        let rtf = #"{\rtf1\ansi\deff0 {\fonttbl {\f0 Helvetica;}}\f0\fs24 Hello \b world\b0 .}"#
        try rtf.data(using: .utf8)!.write(to: url)
        let text = try DocumentText.read(url)
        #expect(text.contains("Hello"))
        #expect(text.contains("world"))
        #expect(!text.contains("rtf1"))
    }

    @Test func readsHTMLAsPlainText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sample-\(UUID().uuidString).html")
        let html = "<html><head><style>p { color: red }</style><script>var x = 1;</script></head><body><h1>Title</h1><p>Hello &amp; welcome</p></body></html>"
        try html.data(using: .utf8)!.write(to: url)
        let text = try DocumentText.read(url)
        #expect(text.contains("Title"))
        #expect(text.contains("Hello & welcome"))
        #expect(!text.contains("<p>"))
        #expect(!text.contains("color: red"))
        #expect(!text.contains("var x"))
    }
}

struct MemoryCaptureBareFormsTests {
    /// Chinese and Korean users rarely type punctuation after "remember".
    @Test func bareChineseAndKoreanFormsWork() {
        #expect(MemoryStore.requestedFact(in: "记住我对花生过敏") == "我对花生过敏")
        #expect(MemoryStore.requestedFact(in: "請記住我住在台北") == "我住在台北")
        #expect(MemoryStore.requestedFact(in: "나는 채식주의자라는 걸 기억해 줘") != nil)
    }
}

struct AppLanguageDateTests {
    @Test func relativeDatesShowTimeTodayAndWeekdayThisWeek() {
        let now = Date()
        let today = now.addingTimeInterval(-60)
        let todayText = today.aigRelative(now: now)
        #expect(!todayText.isEmpty)
        #expect(todayText == today.aigFormatted(date: .omitted, time: .shortened))
        let longAgo = Calendar.current.date(byAdding: .year, value: -2, to: now)!
        #expect(longAgo.aigRelative(now: now) != todayText)
    }
}

/// Where Hugging Face is blocked (mainland China), built-in models come from
/// ModelScope instead, checked file by file against pinned SHA-256s.
struct DownloadSourceTests {

    @Test func everyBuiltInModelIsPinnedFileForFile() throws {
        for model in AIModel.builtInModels {
            let hfId = try #require(model.huggingFaceId)
            let pinned = try #require(BuiltInModelManifests.manifest(for: hfId), "\(model.name) has no pinned manifest")
            // The pinned files are the model's advertised size (the older
            // catalog entries give it rounded).
            let drift = abs(Double(pinned.totalBytes - model.sizeBytes)) / Double(model.sizeBytes)
            #expect(drift < 0.02, "\(model.name): pinned \(pinned.totalBytes) vs \(model.sizeBytes)")
            #expect(pinned.files.contains { $0.path == "config.json" })
            #expect(pinned.files.contains { $0.path.hasSuffix(".safetensors") })
            #expect(pinned.commit.count == 40)
            for file in pinned.files {
                #expect(file.sha256.count == 64 && file.sha256 == file.sha256.lowercased())
                #expect(file.size > 0)
                #expect(file.path.hasSuffix(".safetensors") || file.path.hasSuffix(".json") || file.path.hasSuffix(".jinja"))
            }
        }
    }

    @Test func onlyPinnedModelsEverUseModelScope() {
        #expect(ModelPrefetcher.sourceOrder(hasPinnedManifest: false, preferred: .modelScope) == [.huggingFace])
        #expect(ModelPrefetcher.sourceOrder(hasPinnedManifest: false, preferred: .huggingFace) == [.huggingFace])
        #expect(ModelPrefetcher.sourceOrder(hasPinnedManifest: true, preferred: .huggingFace) == [.huggingFace, .modelScope])
        #expect(ModelPrefetcher.sourceOrder(hasPinnedManifest: true, preferred: .modelScope) == [.modelScope, .huggingFace])
        // A model the user added has no pin.
        #expect(BuiltInModelManifests.manifest(for: "someone/their-model-4bit") == nil)
        // In mainland China ModelScope comes first, whatever worked before;
        // a user-added model still only has Hugging Face.
        #expect(ModelPrefetcher.sourceOrder(hasPinnedManifest: true, preferred: .huggingFace, inMainlandChina: true) == [.modelScope, .huggingFace])
        #expect(ModelPrefetcher.sourceOrder(hasPinnedManifest: false, preferred: .huggingFace, inMainlandChina: true) == [.huggingFace])
    }

    @Test func modelScopeHasASecondAddressForEveryFile() throws {
        let repo = "mlx-community/Qwen3.5-0.8B-4bit"
        let url = try #require(ModelPrefetcher.Source.modelScope.alternateFileURL(repo: repo, path: "config.json"))
        #expect(url.absoluteString == "https://www.modelscope.cn/api/v1/models/mlx-community/Qwen3.5-0.8B-4bit/repo?Revision=master&FilePath=config.json")
        #expect(ModelPrefetcher.Source.huggingFace.alternateFileURL(repo: repo, path: "config.json") == nil)
    }

    @Test func failuresAreSummarizedInCodes() {
        #expect(DownloadDiagnostics.shortReason(URLError(.timedOut)) == "network -1001")
        let atHost = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://huggingface.co/api/models/x")!])
        #expect(DownloadDiagnostics.shortReason(atHost) == "network -1004 at huggingface.co")
        #expect(DownloadDiagnostics.shortReason(PrefetchError.downloadFailed(status: 403)) == "HTTP 403")
        #expect(DownloadDiagnostics.shortReason(PrefetchError.checksumMismatch) == "checksum mismatch")
        // A failure of every source is final: nothing left to fall back to.
        #expect(!ModelPrefetcher.isUnreachable(PrefetchError.allSourcesFailed(summary: "x")))
        let message = ModelPrefetcher.friendlyMessage(for: PrefetchError.allSourcesFailed(summary: "Hugging Face: network -1001; ModelScope: HTTP 403"))
        #expect(message?.contains("(Hugging Face: network -1001; ModelScope: HTTP 403)") == true)
    }

    @Test func fileURLsPointAtEachSource() {
        let repo = "mlx-community/Qwen3.5-0.8B-4bit"
        #expect(ModelPrefetcher.Source.huggingFace.fileURL(repo: repo, encodedPath: "config.json")?.absoluteString
                == "https://huggingface.co/mlx-community/Qwen3.5-0.8B-4bit/resolve/main/config.json")
        #expect(ModelPrefetcher.Source.modelScope.fileURL(repo: repo, encodedPath: "config.json")?.absoluteString
                == "https://modelscope.cn/models/mlx-community/Qwen3.5-0.8B-4bit/resolve/master/config.json")
    }

    @Test func onlyAnUnreachableSourceTriesTheOther() {
        // A blocked or failing server: try the other source.
        #expect(ModelPrefetcher.isUnreachable(URLError(.cannotFindHost)))
        #expect(ModelPrefetcher.isUnreachable(URLError(.cannotConnectToHost)))
        #expect(ModelPrefetcher.isUnreachable(URLError(.timedOut)))
        #expect(ModelPrefetcher.isUnreachable(URLError(.secureConnectionFailed)))
        #expect(ModelPrefetcher.isUnreachable(URLError(.networkConnectionLost)))
        #expect(ModelPrefetcher.isUnreachable(PrefetchError.listingFailed(status: 503)))
        #expect(ModelPrefetcher.isUnreachable(PrefetchError.downloadFailed(status: 403)))
        #expect(ModelPrefetcher.isUnreachable(PrefetchError.sizeMismatch))
        // Nothing a second source can fix.
        #expect(!ModelPrefetcher.isUnreachable(URLError(.notConnectedToInternet)))
        #expect(!ModelPrefetcher.isUnreachable(URLError(.cancelled)))
        #expect(!ModelPrefetcher.isUnreachable(CancellationError()))
        #expect(!ModelPrefetcher.isUnreachable(PrefetchError.noFiles))
        #expect(!ModelPrefetcher.isUnreachable(CocoaError(.fileWriteOutOfSpace)))
    }

    @Test func modelScopeDownloadsAreLabelledInThePrivacyCenter() {
        let repo = "mlx-community/Qwen3.5-0.8B-4bit"
        #expect(NetworkEvent.purpose(host: "modelscope.cn", path: "/models/\(repo)/resolve/master/model.safetensors", downloadingRepo: repo) == L10n.text("Downloading AI model files"))
        #expect(NetworkEvent.purpose(host: "cdn-lfs-cn-1.modelscope.cn", path: "/prod/lfs-objects/f5/a0/abc", downloadingRepo: repo) == L10n.text("Downloading AI model files"))
        #expect(NetworkEvent.purpose(host: "modelscope.cn.example.com", path: "/x", downloadingRepo: repo) == L10n.text("Other"))
    }

    @Test func sha256MatchesAKnownValue() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aig-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let known = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(try ModelPrefetcher.sha256(of: url) == known)
        #expect(await ModelPrefetcher.matches(url, sha256: known))
        #expect(await ModelPrefetcher.matches(url, sha256: known.uppercased()))
        #expect(!(await ModelPrefetcher.matches(url, sha256: String(repeating: "0", count: 64))))
        #expect(await ModelPrefetcher.matches(url, sha256: nil))
    }

    @Test @MainActor func feedbackSaysWhereDownloadsComeFrom() {
        DownloadDiagnostics.record("mlx-community/Qwen3-VL-2B-Instruct-4bit - ModelScope: HTTP 403; Hugging Face: network -1001")
        let details = FeedbackMail.details(modelName: "Qwen3 Vision 2B", languageName: "English")
        #expect(details.contains("Downloads try first: "))
        #expect(details.contains("Last download: mlx-community/Qwen3-VL-2B-Instruct-4bit - ModelScope: HTTP 403; Hugging Face: network -1001"))
    }

    @Test func eachSourceParksItsOwnResumeData() {
        let file = URL(fileURLWithPath: "/tmp/model.safetensors")
        let hf = FileDownload.resumeDataFile(for: file, source: .huggingFace)
        let ms = FileDownload.resumeDataFile(for: file, source: .modelScope)
        #expect(hf == FileDownload.resumeDataFile(for: file))
        #expect(hf != ms)
    }
}

/// Real downloads from ModelScope. Opt-in (TEST_RUNNER_AIG_NETWORK_TESTS=1),
/// so the regular suite never touches the network.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AIG_NETWORK_TESTS"] == "1"))
struct ModelScopeNetworkTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aig-ms-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The small files of a model straight from ModelScope: right URL
    /// format, redirects followed, every file's SHA-256 checked.
    @Test @MainActor func modelScopeServesThePinnedFiles() async throws {
        let hfId = "mlx-community/Qwen3.5-0.8B-4bit"
        let full = try #require(BuiltInModelManifests.manifest(for: hfId))
        let small = PinnedModelManifest(commit: full.commit, files: full.files.filter { !$0.path.hasSuffix(".safetensors") })
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefetcher = ModelPrefetcher()
        prefetcher.wifiOnly = false
        try await prefetcher.prefetch(hfId: hfId, into: dir, from: .modelScope, pinned: small) { _, _ in }
        for file in small.files {
            let url = dir.appendingPathComponent(file.path)
            #expect(try ModelPrefetcher.sha256(of: url) == file.sha256, "\(file.path)")
        }
        // The loader's metadata sidecars carry Hugging Face's ids.
        let sidecar = dir.appendingPathComponent(".cache/huggingface/download/config.json.metadata")
        let contents = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(contents.hasPrefix(full.commit))
    }

    /// A whole model with Hugging Face blocked, through the same entry point
    /// the app uses: it must come from ModelScope, intact. 650 MB, so it
    /// needs TEST_RUNNER_AIG_NETWORK_TESTS_FULL=1 and
    /// TEST_RUNNER_AIG_BLOCK_HUGGINGFACE=1 as well.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIG_NETWORK_TESTS_FULL"] == "1"),
          .timeLimit(.minutes(20)))
    @MainActor func blockedHuggingFaceFallsBackToModelScope() async throws {
        #expect(ProcessInfo.processInfo.environment["AIG_BLOCK_HUGGINGFACE"] == "1")
        let hfId = "mlx-community/Qwen3.5-0.8B-4bit"
        let pinned = try #require(BuiltInModelManifests.manifest(for: hfId))
        let saved = ModelPrefetcher.preferredSource
        ModelPrefetcher.preferredSource = .huggingFace
        defer { ModelPrefetcher.preferredSource = saved }
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefetcher = ModelPrefetcher()
        prefetcher.wifiOnly = false
        try await prefetcher.prefetch(hfId: hfId, into: dir) { _, _ in }
        for file in pinned.files {
            #expect(try ModelPrefetcher.sha256(of: dir.appendingPathComponent(file.path)) == file.sha256, "\(file.path)")
        }
        // The next download starts where this one succeeded.
        #expect(ModelPrefetcher.preferredSource == .modelScope)
    }
}

/// The smallest models answer better with a short prompt (see
/// `AIModel.prefersCompactPrompt`); every other model keeps the full one.
struct CompactPromptTests {

    @Test func onlyTheSmallestQwenModelsGetTheShortPrompt() {
        #expect(AIModel.qwen35_08B8.prefersCompactPrompt)
        #expect(AIModel.qwen35_08B.prefersCompactPrompt)
        for model in [AIModel.qwen35_2B, .qwen3VL2B, .qwen35_4B, .qwen35_9BPro, .gemma4E2B, .smolVLM2, .appleIntelligence] {
            #expect(!model.prefersCompactPrompt, "\(model.name)")
        }
    }

    @Test @MainActor func theShortPromptAsksForCareAndSteps() {
        let small = MLXService.systemPrompt(for: .automatic, memoryTokens: 0, model: AIModel.qwen35_08B8)
        #expect(small.hasPrefix(MLXService.compactBasePrompt))
        #expect(small.contains("say so plainly instead of guessing"))
        #expect(small.contains("work out each step"))
        #expect(small.contains(AppLanguage.automatic.modelInstruction))
        #expect(!small.contains("aigoodbye.ai"))
        // Larger models, and no model at all (Apple Intelligence), keep the full prompt.
        #expect(MLXService.systemPrompt(for: .automatic, memoryTokens: 0, model: AIModel.qwen35_2B).hasPrefix(MLXService.basePrompt))
        #expect(MLXService.systemPrompt(for: .automatic, memoryTokens: 0).hasPrefix(MLXService.basePrompt))
    }
}

/// The note in front of each message (TurnContext): the answer's language,
/// the clock only when asked, and the "who is" reminder. From a tester's
/// German report on an iPhone SE.
struct TurnContextTests {
    /// Monday 26 October 2026, 11:11 in Berlin.
    let monday = ISO8601DateFormatter().date(from: "2026-10-26T10:11:00Z")!
    let berlin = TimeZone(identifier: "Europe/Berlin")!

    @Test func theTimeQuestionGetsTheRealTimeInGerman() {
        let sent = TurnContext.wrap("Wie spät ist es?", question: "Wie spät ist es?",
                                    appLanguage: .automatic, now: monday, timeZone: berlin)
        #expect(sent == "(Es ist jetzt Montag, 26. Oktober 2026 um 11:11. Antworte auf Deutsch.)\n\nWie spät ist es?")
    }

    @Test func sumsGetNoClock() {
        let q = "Wie viel ist 2 + 2? Antworte nur mit der Zahl."
        let sent = TurnContext.wrap(q, question: q, appLanguage: .automatic, now: monday, timeZone: berlin)
        #expect(sent == "(Antworte auf Deutsch.)\n\n" + q)
        #expect(!sent.contains("2026"))
    }

    @Test func aGermanQuestionAboutAPhotoIsAnsweredInGerman() {
        #expect(TurnContext.replyLanguage(for: "Sag mir, was du auf diesem Bild siehst.", appLanguage: .automatic) == .german)
        #expect(TurnContext.replyLanguage(for: "Tell me what you see in this picture.", appLanguage: .automatic) == .english)
        #expect(TurnContext.replyLanguage(for: "Que horas são?", appLanguage: .automatic) == .portuguese)
        #expect(TurnContext.replyLanguage(for: "而家幾點？", appLanguage: .automatic) == nil)  // too short to be sure
    }

    @Test func shortMessagesKeepTheSystemPromptsRule() {
        #expect(TurnContext.replyLanguage(for: "Hallo", appLanguage: .automatic) == nil)
        #expect(TurnContext.wrap("Hallo", question: "Hallo", appLanguage: .automatic) == "Hallo")
    }

    @Test func aLanguageChosenInSettingsWins() {
        #expect(TurnContext.replyLanguage(for: "What time is it?", appLanguage: .german) == .german)
        let note = TurnContext.note(for: "Hi", appLanguage: .french)
        #expect(note == "(Réponds en français.)")
    }

    @Test func whoIsQuestionsGetTheReminder() {
        let note = TurnContext.note(for: "Wer ist Scott von Gimborn?", appLanguage: .automatic)
        #expect(note == "(Wenn du diese Person nicht sicher kennst, sag ehrlich, dass du sie nicht kennst. Antworte auf Deutsch.)")
        #expect(TurnContext.asksWhoSomeoneIs("Who’s Dmitry Mikhaylov?"))
        #expect(TurnContext.asksWhoSomeoneIs("Erzähl mir etwas über Scott von Gimborn."))
        #expect(TurnContext.asksWhoSomeoneIs("Кто такой Альберт Эйнштейн?"))
        #expect(!TurnContext.asksWhoSomeoneIs("Wer bin ich?"))
        #expect(!TurnContext.asksWhoSomeoneIs("What is the capital of France?"))
    }

    @Test func peopleTheModelSaysItDoesNotKnowGetAnHonestAnswer() {
        let q = "Wer ist Scott von Gimborn?"
        let german = TurnContext.Phrases.for(.german)
        #expect(TurnContext.fixedAnswer(for: q, hasImage: false, personKnown: false, appLanguage: .automatic) == german.dontKnowAnswer)
        // Known people, and photos (which may show who it is), go to the model.
        #expect(TurnContext.fixedAnswer(for: q, hasImage: false, personKnown: true, appLanguage: .automatic) == nil)
        #expect(TurnContext.fixedAnswer(for: q, hasImage: false, personKnown: nil, appLanguage: .automatic) == nil)
        #expect(TurnContext.fixedAnswer(for: q, hasImage: true, personKnown: false, appLanguage: .automatic) == nil)
        #expect(TurnContext.note(for: q, appLanguage: .automatic, personKnown: false)
                == "(" + german.unknownPersonCertain + " " + german.answerIn + ")")
        #expect(TurnContext.note(for: "Wer war Albert Einstein?", appLanguage: .automatic, personKnown: true)
                == "(" + german.answerIn + ")")
        // personKnown is only false for questions about that person (see
        // PeopleGuardTests); a plain remark still gets nothing fixed.
        #expect(TurnContext.fixedAnswer(for: "Danke, das war hilfreich.", hasImage: false, personKnown: false, appLanguage: .automatic) == nil)
    }

    @Test func whoAmIIsAnsweredWithWhatTheAppKnows() {
        let q = "Wer bin ich? Nenne nur Informationen, die du tatsächlich über mich weißt. Erfinde nichts und sage ausdrücklich, wenn du etwas nicht weißt."
        let german = TurnContext.Phrases.for(.german)
        #expect(TurnContext.asksWhoTheUserIs(q))
        #expect(!TurnContext.asksWhoSomeoneIs(q))
        #expect(TurnContext.asksWhoTheUserIs("What do you know about me?"))
        #expect(!TurnContext.asksWhoSomeoneIs("What do you know about me?"))
        #expect(TurnContext.fixedAnswer(for: q, hasImage: false, personKnown: nil, appLanguage: .automatic) == german.aboutUserAnswer)
        let withFacts = TurnContext.fixedAnswer(for: "Who am I?", hasImage: false, personKnown: nil,
                                                appLanguage: .english, rememberedFacts: ["I'm vegetarian", "I live in Hamburg"])
        #expect(withFacts == TurnContext.Phrases.for(.english).aboutUserAnswer
                + "\n\nYou asked me to remember this about you:\n- I'm vegetarian\n- I live in Hamburg")
        #expect(!TurnContext.asksWhoTheUserIs("Wer bist du?"))
    }

    @Test func theAppSaysWhoMadeIt() {
        let answer = TurnContext.fixedAnswer(for: "Wer ist Dmitry Mikhaylov?", hasImage: false, personKnown: nil, appLanguage: .automatic)
        #expect(answer == TurnContext.Phrases.for(.german).developerAnswer)
        #expect(answer?.contains("AiGoodbye") == true)
        #expect(TurnContext.fixedAnswer(for: "Who is Dmitry Mikhaylov?", hasImage: false, personKnown: nil, appLanguage: .automatic)?
                .hasPrefix("Dmitry Mikhaylov, also known as Dealer Of Happiness") == true)
        let note = TurnContext.note(for: "Was ist Dealer of Happiness?", appLanguage: .automatic)
        #expect(note == "(" + TurnContext.Phrases.for(.german).developerNote + " Antworte auf Deutsch.)")
    }

    @Test func everyLanguageHasEveryPhrase() {
        for language in AppLanguage.allCases {
            let p = TurnContext.Phrases.for(language)
            for text in [p.answerIn, p.nowTemplate, p.unknownPerson, p.unknownPersonCertain, p.developerNote, p.developerAnswer, p.dontKnowAnswer] {
                #expect(!text.isEmpty, "\(language)")
            }
            #expect(p.nowTemplate.contains("{date}"), "\(language)")
            #expect(p.developerAnswer.contains("Dmitry Mikhaylov") && p.developerAnswer.contains("AiGoodbye"), "\(language)")
        }
    }

    @Test func dateQuestionsAcrossLanguages() {
        for q in ["What time is it?", "Welcher Wochentag ist heute?", "Quelle heure est-il ?", "¿Qué hora es?",
                  "Che ore sono?", "Que horas são?", "Который час?", "Котра година?", "Τι ώρα είναι;",
                  "今何時ですか？", "지금 몇 시예요?", "现在几点？", "而家幾點？", "What’s the date today?"] {
            #expect(TurnContext.asksAboutDateOrTime(q), "\(q)")
        }
        for q in ["Wie viel ist 2 + 2?", "Hier ist mein Text.", "How much time does it take to boil an egg?",
                  "Wer ist Scott von Gimborn?", "这需要多少时间？", "2時間で何キロ歩けますか？", "Update the data please."] {
            #expect(!TurnContext.asksAboutDateOrTime(q), "\(q)")
        }
    }

    @Test func theNoteIsNeverStoredOrShown() {
        // Only the model's copy: the request's prompt and display text stay as typed.
        let q = "Wie spät ist es?"
        let sent = TurnContext.wrap("passages\n\n" + q, question: q, appLanguage: .automatic, now: monday, timeZone: berlin)
        #expect(sent.hasSuffix("passages\n\n" + q))
        #expect(sent.hasPrefix("(Es ist jetzt"))
    }

    @Test func withAPictureTheNoteFollowsTheQuestion() {
        let q = "Was siehst du auf diesem Bild?"
        let german = TurnContext.Phrases.for(.german)
        #expect(TurnContext.wrap(q, question: q, appLanguage: .automatic, hasImage: true)
                == q + "\n\n(" + german.answerIn + ")")
        #expect(TurnContext.wrap(q, question: q, appLanguage: .automatic)
                == "(" + german.answerIn + ")\n\n" + q)
    }
}

/// Questions about people on the smallest models (PeopleGuard), with the
/// model's side answers scripted. From a tester's chat in which the app
/// first said it did not know him, then invented "Karl von Gimborn".
struct PeopleGuardTests {
    /// Answers the two side questions the way the 0.8B model did.
    final class FakeModel {
        var calls: [String] = []
        let names: [String: String]      // question -> name probe answer
        let known: Set<String>           // names it says it knows
        let persons: Set<String>         // phrases it calls a person's name
        init(names: [String: String], known: Set<String>, persons: Set<String> = []) {
            self.names = names; self.known = known; self.persons = persons
        }
        func answer(_ prompt: String, _ maxTokens: Int) -> String? {
            calls.append(prompt)
            if prompt.contains("Is this question about a specific, named person") {
                return names.first { prompt.contains($0.key) }?.value ?? "NONE"
            }
            if prompt.contains("the name of a person?") {
                return persons.contains { prompt.contains("«\($0)»") } ? "Yes" : "No"
            }
            if let name = known.first(where: { prompt.contains("Wer ist \($0)?") }) { _ = name; return "Yes" }
            return "No"
        }
    }

    let german = TurnContext.Phrases.for(.german)

    @Test func followUpsAboutSomeoneUnknownGetTheSameHonestAnswer() async {
        let model = FakeModel(names: ["Was macht Scott von Gimborn?": "Scott von Gimborn"], known: [])
        var state = PeopleState()
        let first = await PeopleGuard.resolve(question: "Was macht Scott von Gimborn?", hasImage: false,
                                              appLanguage: .automatic, state: &state,
                                              probe: { model.answer($0, $1) })
        #expect(first.personKnown == false)
        #expect(first.fixed == german.dontKnowAnswer)
        #expect(state.unknownNames == ["Scott von Gimborn"])

        let calls = model.calls.count
        let followUp = await PeopleGuard.resolve(question: "Ist er ein Schauspieler?", hasImage: false,
                                                 appLanguage: .automatic, state: &state,
                                                 probe: { model.answer($0, $1) })
        #expect(followUp.fixed == german.dontKnowAnswer)
        #expect(model.calls.count == calls, "no side questions needed for a follow-up")

        let byName = await PeopleGuard.resolve(question: "In welchen Filmen hat Scott von Gimborn mitgespielt?",
                                               hasImage: false, appLanguage: .automatic, state: &state,
                                               probe: { model.answer($0, $1) })
        #expect(byName.fixed == german.dontKnowAnswer)
    }

    @Test func famousPeopleAreLeftToTheModel() async {
        let model = FakeModel(names: ["Wer war Albert Einstein?": "Albert Einstein"], known: ["Albert Einstein"])
        var state = PeopleState()
        let einstein = await PeopleGuard.resolve(question: "Wer war Albert Einstein?", hasImage: false,
                                                 appLanguage: .automatic, state: &state,
                                                 probe: { model.answer($0, $1) })
        #expect(einstein.personKnown == true)
        #expect(einstein.fixed == nil)
        let followUp = await PeopleGuard.resolve(question: "Was hat er entdeckt?", hasImage: false,
                                                 appLanguage: .automatic, state: &state,
                                                 probe: { model.answer($0, $1) })
        #expect(followUp.fixed == nil)
        #expect(followUp.personKnown == nil)
    }

    @Test func theUserIntroducingThemselvesIsGreetedAndRemembered() async {
        let model = FakeModel(names: [:], known: [])
        var state = PeopleState()
        let intro = await PeopleGuard.resolve(question: "Ich heiße Scott von Gimborn.", hasImage: false,
                                              appLanguage: .automatic, state: &state,
                                              probe: { model.answer($0, $1) })
        #expect(intro.fixed == "Schön, dich kennenzulernen, Scott von Gimborn! Wie kann ich dir helfen?")
        #expect(state.userName == "Scott von Gimborn")

        let aboutMe = await PeopleGuard.resolve(question: "Was weißt du über Scott von Gimborn?", hasImage: false,
                                                appLanguage: .automatic, state: &state,
                                                probe: { model.answer($0, $1) })
        #expect(aboutMe.fixed == german.aboutUserAnswer + " Ich weiß nur, dass du Scott von Gimborn heißt.")

        let actor = await PeopleGuard.resolve(question: "Bin ich ein Schauspieler?", hasImage: false,
                                              appLanguage: .automatic, state: &state,
                                              probe: { model.answer($0, $1) })
        #expect(actor.fixed?.hasPrefix(german.aboutUserAnswer) == true)
        #expect(model.calls.isEmpty, "questions about the user need no side questions")
    }

    @Test func statementsAndTheDeveloperNeedNoSideQuestions() async {
        let model = FakeModel(names: [:], known: [])
        var state = PeopleState()
        let statement = await PeopleGuard.resolve(question: "Scott von Gimborn kommt aus Emmerich am Rhein.",
                                                  hasImage: false, appLanguage: .automatic, state: &state,
                                                  probe: { model.answer($0, $1) })
        #expect(statement.fixed == nil)
        let developer = await PeopleGuard.resolve(question: "Wer ist Dmitry Mikhaylov?", hasImage: false,
                                                  appLanguage: .automatic, state: &state,
                                                  probe: { model.answer($0, $1) })
        #expect(developer.fixed == german.developerAnswer)
        #expect(model.calls.isEmpty)
    }

    @Test func aPhotoIsLeftToTheModelWithANote() async {
        let model = FakeModel(names: ["Wer ist Scott von Gimborn?": "Scott von Gimborn"], known: [])
        var state = PeopleState()
        let photo = await PeopleGuard.resolve(question: "Wer ist Scott von Gimborn?", hasImage: true,
                                              appLanguage: .automatic, state: &state,
                                              probe: { model.answer($0, $1) })
        #expect(photo.fixed == nil)
        #expect(photo.personKnown == false)
        let note = TurnContext.note(for: "Wer ist Scott von Gimborn?", appLanguage: .automatic, personKnown: false)
        #expect(note?.contains(german.unknownPersonCertain) == true)
    }

    @Test func requestsWithoutAQuestionAreCheckedToo() async {
        // "Info über Scott von Gimborn": the model names nobody in a message
        // that is not a question, so the name in it is checked.
        let model = FakeModel(names: [:], known: ["Angela Merkel"],
                              persons: ["Scott von Gimborn", "Angela Merkel"])
        var state = PeopleState()
        let info = await PeopleGuard.resolve(question: "Info über Scott von Gimborn", hasImage: false,
                                             appLanguage: .automatic, state: &state,
                                             probe: { model.answer($0, $1) })
        #expect(info.personKnown == false)
        #expect(info.fixed == german.dontKnowAnswer)

        var fresh = PeopleState()
        let bare = await PeopleGuard.resolve(question: "Scott von Gimborn", hasImage: false,
                                             appLanguage: .automatic, state: &fresh,
                                             probe: { model.answer($0, $1) })
        #expect(bare.fixed == german.dontKnowAnswer)

        let merkel = await PeopleGuard.resolve(question: "Info über Angela Merkel", hasImage: false,
                                               appLanguage: .automatic, state: &fresh,
                                               probe: { model.answer($0, $1) })
        #expect(merkel.personKnown == true)
        #expect(merkel.fixed == nil)

        // A company is not a person: left to the model, without the
        // "if you don't know this person" note.
        let bahn = await PeopleGuard.resolve(question: "Info über die Deutsche Bahn", hasImage: false,
                                             appLanguage: .automatic, state: &fresh,
                                             probe: { model.answer($0, $1) })
        #expect(bahn.fixed == nil)
        #expect(bahn.noNamedPerson)
        let note = TurnContext.note(for: "Info über die Deutsche Bahn", appLanguage: .automatic,
                                    noNamedPerson: bahn.noNamedPerson)
        #expect(note?.contains(german.unknownPerson) != true)
    }

    @Test func findingTheNameInARequest() {
        #expect(TurnContext.asksWhoSomeoneIs("Info über Scott von Gimborn"))
        #expect(TurnContext.asksWhoSomeoneIs("Infos zu Scott von Gimborn bitte"))
        #expect(TurnContext.asksWhoSomeoneIs("Info about Taylor Swift"))
        #expect(TurnContext.asksWhoSomeoneIs("Scott von Gimborn"))
        #expect(!TurnContext.asksWhoSomeoneIs("Info über mich"))
        #expect(TurnContext.isJustAName("Albert Einstein?"))
        #expect(!TurnContext.isJustAName("Hallo Scott"))
        #expect(!TurnContext.isJustAName("Guten Morgen"))
        #expect(!TurnContext.isJustAName("Danke Dmitry"))
        #expect(!TurnContext.isJustAName("Wie spät ist es?"))
        #expect(TurnContext.nameCandidate(in: "Info über Scott von Gimborn") == "Scott von Gimborn")
        #expect(TurnContext.nameCandidate(in: "Was macht Scott von Gimborn beruflich?") == "Scott von Gimborn")
        #expect(TurnContext.nameCandidate(in: "Biografie von Johann Wolfgang von Goethe") == "Johann Wolfgang von Goethe")
        #expect(TurnContext.nameCandidate(in: "Info über Berlin") == nil)
        #expect(TurnContext.nameCandidate(in: "Erzähl mir von Emmerich am Rhein") == nil)
        #expect(TurnContext.nameCandidate(in: "谁是李白") == nil)
    }

    @Test func readingTheModelsSideAnswers() {
        let q = "Was macht Scott von Gimborn beruflich?"
        #expect(TurnContext.personName(fromProbe: "Scott von Gimborn", question: q) == "Scott von Gimborn")
        #expect(TurnContext.personName(fromProbe: "Scott von Gimborn is a fictional character from", question: q) == "Scott von Gimborn")
        #expect(TurnContext.personName(fromProbe: "NONE", question: q) == nil)
        #expect(TurnContext.personName(fromProbe: "Yes.", question: q) == nil)
        #expect(TurnContext.personName(fromProbe: "Karl Gimborn", question: q) == nil)
        #expect(TurnContext.yesOrNo("Yes.") == true)
        #expect(TurnContext.yesOrNo("no") == false)
        #expect(TurnContext.yesOrNo("Maybe") == nil)
    }

    @Test func detectingIntroductionsQuestionsAndPronouns() {
        #expect(TurnContext.selfIntroductionName(in: "Ich heiße Scott von Gimborn.") == "Scott von Gimborn")
        #expect(TurnContext.selfIntroductionName(in: "Mein Name ist Scott von Gimborn. Was weißt du?") == "Scott von Gimborn")
        #expect(TurnContext.selfIntroductionName(in: "My name is Anna Schmidt") == "Anna Schmidt")
        #expect(TurnContext.selfIntroductionName(in: "Ich bin müde.") == nil)
        #expect(TurnContext.isQuestionLike("Erzähl mir mehr über ihn."))
        #expect(TurnContext.isQuestionLike("Ist er ein Schauspieler?"))
        #expect(!TurnContext.isQuestionLike("Scott kommt aus Emmerich."))
        #expect(TurnContext.refersBackToSomeone("Ist er ein Schauspieler?"))
        #expect(TurnContext.refersBackToSomeone("Tell me more about her."))
        #expect(!TurnContext.refersBackToSomeone("Wie spät ist es?"))
        #expect(TurnContext.asksWhoTheUserIs("Bin ich ein Schauspieler?"))
        #expect(TurnContext.asksWhoTheUserIs("Welche Filme habe ich gemacht?"))
    }
}

/// A covered lens or a dark room is said, not described.
struct FrameCheckTests {
    func image(gray: CGFloat, noise: CGFloat = 0) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48))
        return renderer.image { context in
            for x in stride(from: 0, to: 64, by: 4) {
                for y in stride(from: 0, to: 48, by: 4) {
                    let value = max(0, min(1, gray + (noise > 0 ? CGFloat.random(in: -noise...noise) : 0)))
                    UIColor(white: value, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
    }

    @Test func darkOrFeaturelessFramesShowNothing() {
        #expect(FrameCheck.showsNothing(image(gray: 0)))
        #expect(FrameCheck.showsNothing(image(gray: 0.12, noise: 0.02)))   // taped over
        #expect(!FrameCheck.showsNothing(image(gray: 0.9)))                // a white wall is real
        #expect(!FrameCheck.showsNothing(image(gray: 0.4, noise: 0.35)))   // an ordinary scene
    }
}

/// Recording summaries stay with what was said.
struct RecordingSummaryHonestyTests {
    @Test func aSentenceOrTwoIsNotSummarized() {
        #expect(!RecordingSummarizer.isWorthSummarizing("Hallo, mein Name ist Scott von Gimborn."))
        #expect(!RecordingSummarizer.isWorthSummarizing("Heute ist Dienstag. Ich trinke einen Kaffee und esse ein Brot."))
        let meeting = String(repeating: "Wir besprechen heute das Budget für die nächste Woche. ", count: 6)
        #expect(RecordingSummarizer.isWorthSummarizing(meeting))
    }

    @Test func summariesAreNotWrittenAsTheBrandedAssistant() {
        let system = RecordingSummarizer.instructions(language: .german)
        #expect(!system.contains("Dealer Of Happiness"))
        #expect(!system.contains("AiGoodbye"))
        #expect(system.contains("Never add names, places, events, plans, wishes or tasks"))
        #expect(system.hasSuffix("Write in German."))
    }
}

/// Live speech: words while the user talks, not after.
struct LiveSpeechTests {
    @Test @MainActor func liveResultsAreAskedFor() {
        #expect(Transcriber.reportingOptions.contains(.fastResults))
        #expect(Transcriber.reportingOptions.contains(.volatileResults))
    }

    @Test func theFinishedWordsAreSentNotTheLiveOnes() {
        // The live text lagged the voice: "Wer ist Scott von" while the
        // finished result had the name.
        #expect(VoiceService.bestTranscript(finished: "Wer ist Scott von Gimbon?", live: "Wer ist Scott von") == "Wer ist Scott von Gimbon?")
        #expect(VoiceService.bestTranscript(finished: "", live: "Hallo") == "Hallo")
        #expect(VoiceService.bestTranscript(finished: "Hallo", live: "Hallo wie geht es") == "Hallo wie geht es")
    }

    @Test func aVoiceAnswerIsSpokenWhole() {
        // An answer the app gives itself never streamed: all of it is said.
        #expect(VoiceModeView.answerToSpeak(saved: "Ich weiß nicht, wer das ist.", streamed: "", spokenOffset: 0)
                == "Ich weiß nicht, wer das ist.")
        // The last words arrived only with the saved answer.
        #expect(VoiceModeView.answerToSpeak(saved: "Es ist warm. Und sonnig.", streamed: "Es ist warm. Und", spokenOffset: 13)
                == "Es ist warm. Und sonnig.")
        // Saved text that does not continue what was spoken is not used.
        #expect(VoiceModeView.answerToSpeak(saved: "Anders.", streamed: "Es ist warm.", spokenOffset: 12) == "Es ist warm.")
    }

    @Test func translatedNameParticlesArePutBack() {
        let source = "Hallo, mein Name ist Scott von Gimborn. Ich komme aus Emmerich am Rhein."
        #expect(TranslateModeView.keepNames(from: source, in: "Hello, my name is Scott from Gimborn. I come from Emmerich.")
                == "Hello, my name is Scott von Gimborn. I come from Emmerich.")
        #expect(TranslateModeView.keepNames(from: "Karl-Heinz van der Berg kommt morgen.", in: "Karl-Heinz von der Berg is coming tomorrow.")
                == "Karl-Heinz van der Berg is coming tomorrow.")
        #expect(TranslateModeView.keepNames(from: "Wo ist der Bahnhof?", in: "Where is the station?") == "Where is the station?")
    }

    @Test func punctuationIsNotSpeech() {
        #expect(VoiceService.words(of: "Hallo, wie spät ist es heute") == VoiceService.words(of: "Hallo, wie spät ist es heute?"))
        #expect(VoiceService.words(of: "Ich möchte") != VoiceService.words(of: "Ich möchte einen"))
    }
}
