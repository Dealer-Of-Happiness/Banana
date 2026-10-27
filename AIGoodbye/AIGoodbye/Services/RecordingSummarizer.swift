//
//  RecordingSummarizer.swift
//  AIGoodbye
//
//  Turns a long transcript into a summary, key points and action items using
//  the on-device model.
//
//  An hour of talking is far longer than any small model's context window, so
//  this is a map-reduce: each slice of the transcript is condensed to notes,
//  the notes are condensed again (repeatedly, if there are many), and the
//  final pass writes the summary. Every pass uses a fresh, persona-free
//  session so a "Brainstorm Partner" persona can't turn meeting minutes into
//  a discussion, and so context never accumulates across slices.
//

import Foundation

enum RecordingSummarizer {

    /// Roughly how much transcript goes into one pass. Kept well inside the
    /// smallest supported model's context so the instructions survive.
    nonisolated static let sliceCharacters = 2600
    /// How many sets of notes are folded together at once.
    nonisolated static let notesPerReduction = 6

    /// Below this many words there is nothing to summarize: the transcript
    /// says it all, and a small model asked for "two or three sentences, key
    /// points and action items" about one sentence pads them out with
    /// invention. "Hallo, mein Name ist Scott von Gimborn." came back as a
    /// talk about personal history and memory; "Heute ist Dienstag. Ich
    /// trinke einen Kaffee und esse ein Brot." gained tasks to drink coffee
    /// and eat bread. Such recordings keep a title from their own words and
    /// no summary.
    nonisolated static let minimumWordsToSummarize = 40

    /// Whether a transcript is long enough to be worth summarizing. CJK
    /// text has no spaces, so it is measured in characters there.
    nonisolated static func isWorthSummarizing(_ transcript: String) -> Bool {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).count
        let cjk = text.unicodeScalars.filter { (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }.count
        return words >= minimumWordsToSummarize || cjk >= minimumWordsToSummarize * 2
    }

    /// The system prompt for every pass. Not the assistant's own: that one
    /// introduces the app and its developer, and those names ended up in
    /// recordings' titles.
    nonisolated static func instructions(language: AppLanguage?) -> String {
        var text = """
        You write short, faithful notes about recorded speech. Use only what the transcript says. \
        Never add names, places, events, plans, wishes or tasks that are not in it. \
        If something is unclear, leave it out.
        """
        if let language { text += " Write in \(language.englishName)." }
        return text
    }

    // MARK: - Slicing (pure, testable)

    /// Split a transcript into slices that end on sentence boundaries where
    /// possible, so a slice never cuts a sentence in half.
    nonisolated static func slices(of transcript: String, maxCharacters: Int = sliceCharacters) -> [String] {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        guard text.count > maxCharacters else { return [text] }

        var slices: [String] = []
        var current = ""

        // Sentence-ish units: split on terminators but keep them.
        var unit = ""
        let boundaries: Set<Character> = [".", "!", "?", "\n", "。", "！", "？", "…"]
        for character in text {
            unit.append(character)
            guard boundaries.contains(character) else { continue }
            append(unit: unit, to: &current, slices: &slices, maxCharacters: maxCharacters)
            unit = ""
        }
        if !unit.isEmpty {
            append(unit: unit, to: &current, slices: &slices, maxCharacters: maxCharacters)
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { slices.append(tail) }
        // A whitespace-only slice would become a prompt with nothing in it,
        // which invites the model to invent content.
        return slices.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    nonisolated private static func append(unit: String, to current: inout String,
                                           slices: inout [String], maxCharacters: Int) {
        // A single sentence longer than a whole slice (no punctuation at all,
        // which happens with some recognizers) is hard-split rather than
        // dropped.
        if unit.count > maxCharacters {
            if !current.isEmpty {
                slices.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
            var remaining = Substring(unit)
            while remaining.count > maxCharacters {
                let cut = remaining.index(remaining.startIndex, offsetBy: maxCharacters)
                slices.append(String(remaining[remaining.startIndex..<cut]))
                remaining = remaining[cut...]
            }
            current = String(remaining)
            return
        }

        if current.count + unit.count > maxCharacters {
            slices.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = unit
        } else {
            current += unit
        }
    }

    /// A readable fallback title taken from the transcript itself, used when
    /// the model isn't available or its title is unusable.
    static func fallbackTitle(from transcript: String, date: Date = Date()) -> String {
        let words = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(7)
        if words.isEmpty {
            return L10n.text("Recording \(date.aigFormatted(date: .abbreviated, time: .shortened))")
        }
        var title = words.joined(separator: " ")
        if title.count > 60 { title = String(title.prefix(60)) }
        return title.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-"))
    }

    /// Strips a leading label and surrounding quotes from a generated title.
    static func cleanTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the first line is a title, whatever else the model added.
        if let newline = text.firstIndex(where: \.isNewline) {
            text = String(text[text.startIndex..<newline])
        }
        while text.hasPrefix("#") || text.hasPrefix("*") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        if let colon = text.firstIndex(of: ":") {
            let prefix = text[text.startIndex..<colon]
            if prefix.count < 12, prefix.lowercased().contains("title") {
                text = String(text[text.index(after: colon)...])
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("«", "»"), ("“", "”")]
        for (open, close) in quotes where text.first == open && text.last == close && text.count > 1 {
            text = String(text.dropFirst().dropLast())
        }
        if text.count > 70 { text = String(text.prefix(70)) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Generation

    struct Result {
        var title: String
        var summary: String
    }

    enum SummarizerError: LocalizedError {
        case engineBusy
        /// The routed model is not on disk. Summaries never start a download
        /// themselves; the chat screen owns that (consent, progress, Wi-Fi).
        case modelNotDownloaded(AIModel)

        var errorDescription: String? {
            switch self {
            case .engineBusy:
                return L10n.text("The AI is busy with another task. Try again in a moment.")
            case .modelNotDownloaded(let model):
                return L10n.text("Summarizing needs the \(model.name) model. Download it from the chat screen first.")
            }
        }
    }

    /// Condense a transcript into Markdown notes. `progress` reports 0...1.
    /// `languageCode` is the recording's `languageCode` (the language it was
    /// recognized in); the whole summary is asked for in that language.
    @MainActor
    static func summarize(
        transcript: String,
        languageCode: String? = nil,
        engine: ChatEngine,
        progress: @MainActor (Double, String) -> Void = { _, _ in }
    ) async throws -> Result {
        // Too short to summarize: the words themselves are the record.
        guard isWorthSummarizing(transcript) else {
            return Result(title: fallbackTitle(from: transcript), summary: "")
        }
        let model = try routedModel(engine: engine)
        // Only one utility may own the engine: two summaries (or a summary
        // and a translation) would each destroy the other's session.
        guard engine.claimUtility() else { throw SummarizerError.engineBusy }
        defer { engine.releaseUtility() }
        let language = languageCode.flatMap(Self.language(forCode:))
        let system = instructions(language: language)

        // Slicing a four-hour transcript is hundreds of milliseconds of pure
        // string work; it must not block the main actor before the progress
        // UI has even appeared.
        let pieces = await Task.detached(priority: .userInitiated) {
            slices(of: transcript)
        }.value
        guard !pieces.isEmpty else {
            return Result(title: fallbackTitle(from: transcript), summary: "")
        }

        // The map phase owns 0...0.65, the reduce phase 0.65...0.85.
        let mapShare = 0.65

        // Map: notes per slice.
        var notes: [String] = []
        if pieces.count == 1 {
            notes = pieces
        } else {
            for (index, piece) in pieces.enumerated() {
                try Task.checkCancellation()
                progress(
                    mapShare * Double(index) / Double(pieces.count),
                    L10n.text("Reading part \(index + 1) of \(pieces.count)")
                )
                let prompt = """
                Below is part \(index + 1) of \(pieces.count) of a transcript of a recorded conversation. \
                Write 3 to 6 short bullet points capturing only what was actually said: decisions, \
                facts, numbers, names, questions raised, and anything someone said they would do. \
                Do not add anything that is not in the text. Do not write an introduction.

                \(piece)
                """
                let note = try await answer(prompt, model: model, engine: engine, instructions: system)
                // An empty answer would silently delete this part of the
                // meeting from the summary; keep the raw text instead.
                notes.append(note.isEmpty ? piece : note)
            }
        }

        // Reduce: fold notes together until they fit one final pass.
        var round = 0
        while notes.count > notesPerReduction {
            try Task.checkCancellation()
            round += 1
            progress(mapShare + 0.05 * Double(round), L10n.text("Organizing the notes"))
            var folded: [String] = []
            for start in stride(from: 0, to: notes.count, by: notesPerReduction) {
                try Task.checkCancellation()
                let group = notes[start..<min(start + notesPerReduction, notes.count)]
                let joined = group.joined(separator: "\n\n")
                let prompt = """
                Combine these notes from one recording into a single tidy list of bullet points. \
                Merge duplicates, keep every decision, number, name and commitment. \
                Do not add anything new.

                \(joined)
                """
                let combined = try await answer(prompt, model: model, engine: engine, instructions: system)
                folded.append(combined.isEmpty ? joined : combined)
            }
            notes = folded
            if round > 4 { break }   // safety valve on pathological input
        }

        try Task.checkCancellation()
        progress(0.85, L10n.text("Writing the summary"))

        let combined = notes.joined(separator: "\n\n")
        // Headings and "None" in the user's language. Hard-coded English
        // headings gave Russian or Japanese users mixed-language minutes,
        // and contradicted the session's own "always respond in <language>"
        // instruction, so a small model followed one or the other at random.
        let summaryHeading = L10n.text("Summary")
        let keyPointsHeading = L10n.text("Key points")
        let actionItemsHeading = L10n.text("Action items")
        let noneWord = L10n.text("None")
        let languageLine = language.map { " Write the whole result in \($0.englishName)." } ?? ""
        // One slice means `combined` is the transcript itself, not notes
        // about it; the prompt says which, and asks for less where there is
        // less to say.
        let single = pieces.count == 1
        let source = single ? "the transcript of a recording" : "notes from a recording"
        let summaryLength = single ? "One or two sentences saying what was said." : "Two or three sentences describing what the recording was about."
        let finalPrompt = """
        Below is \(source). Write the result in Markdown with exactly these three \
        sections and nothing else:

        ## \(summaryHeading)
        \(summaryLength)

        ## \(keyPointsHeading)
        Up to five bullet points, each one something that was actually said.

        ## \(actionItemsHeading)
        Only what someone explicitly says someone must, should or will do, as bullet points, \
        with who and when if they were said. Saying what someone is doing right now is not a task. \
        Write "\(noneWord)" if there are none.

        Use only what is in the text. Do not invent names, places, dates, journeys, wishes or tasks.\(languageLine)

        \(single ? "Transcript:" : "Notes:")
        \(combined)
        """
        let summary = try await answer(finalPrompt, model: model, engine: engine, instructions: system)

        try Task.checkCancellation()
        progress(0.95, L10n.text("Naming the recording"))

        // Named from the transcript itself when it fits, not from the
        // summary: a title taken from a summary repeats whatever the summary
        // got wrong.
        var title = fallbackTitle(from: transcript)
        let titleSource = single ? String(transcript.prefix(1200)) : String(summary.prefix(1200))
        let titlePrompt = """
        Write a title of 2 to 6 words for this recording, using only words and facts from the \
        text below. Reply with the title only, with no quotes and no explanation.\(languageLine)

        \(titleSource)
        """
        if let generated = try? await answer(titlePrompt, model: model, engine: engine, instructions: system) {
            let cleaned = cleanTitle(generated)
            if !cleaned.isEmpty { title = cleaned }
        }

        progress(1.0, L10n.text("Done"))
        return Result(title: title, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The model that will write the summary, which must already be on disk.
    /// A model that is approved but not yet downloaded would otherwise begin
    /// a multi-gigabyte download inside the summary, behind a progress bar
    /// that says "Reading part 1 of 12". The chat screen owns downloads
    /// (consent, progress, Wi-Fi); the user is sent there instead.
    @MainActor
    private static func routedModel(engine: ChatEngine) throws -> AIModel {
        do {
            return try engine.route(hasImage: false, requiresDownloaded: true)
        } catch let error as ChatEngine.RouteError {
            switch error {
            case .needsDownloadConsent(let missing), .visionNeedsDownloadedModel(let missing):
                throw SummarizerError.modelNotDownloaded(missing)
            case .nothingAvailable:
                throw error
            }
        }
    }

    /// The app language a recording's `languageCode` names. Codes come from
    /// `VoiceService.voiceLocale` ("ru", "zh-Hans", "pt-BR", or a device
    /// preference such as "en-GB" / "zh-Hant-HK" when the app follows the
    /// device). Nil when none of the app's languages matches.
    nonisolated static func language(forCode code: String) -> AppLanguage? {
        let normalized = code.replacingOccurrences(of: "_", with: "-")
        if let exact = AppLanguage(rawValue: normalized), exact != .automatic { return exact }
        let lower = normalized.lowercased()
        let parts = lower.split(separator: "-").map(String.init)
        guard let base = parts.first else { return nil }
        if base == "yue" { return .cantonese }
        if base == "zh" {
            return parts.contains("hk") || parts.contains("mo") ? .cantonese : .mandarin
        }
        return AppLanguage.allCases.first { language in
            language != .automatic
                && language.rawValue.lowercased().split(separator: "-").first.map(String.init) == base
        }
    }

    /// One question, one clean session, the whole answer as a string.
    @MainActor
    private static func answer(_ prompt: String, model: AIModel, engine: ChatEngine, instructions: String) async throws -> String {
        try await engine.startCleanSession(model: model, instructions: instructions)
        var final = ""
        for try await snapshot in engine.respondStream(model: model, prompt: prompt, image: nil) {
            final = snapshot
        }
        return final.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
