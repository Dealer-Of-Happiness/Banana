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
            return L10n.text("Recording \(date.formatted(date: .abbreviated, time: .shortened))")
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

        var errorDescription: String? {
            switch self {
            case .engineBusy:
                return L10n.text("The AI is busy with another task. Try again in a moment.")
            }
        }
    }

    /// Condense a transcript into Markdown notes. `progress` reports 0...1.
    @MainActor
    static func summarize(
        transcript: String,
        engine: ChatEngine,
        progress: @MainActor (Double, String) -> Void = { _, _ in }
    ) async throws -> Result {
        let model = try engine.route(hasImage: false)
        // Only one utility may own the engine: two summaries (or a summary
        // and a translation) would each destroy the other's session.
        guard engine.claimUtility() else { throw SummarizerError.engineBusy }
        defer { engine.releaseUtility() }

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
                let note = try await answer(prompt, model: model, engine: engine)
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
                let combined = try await answer(prompt, model: model, engine: engine)
                folded.append(combined.isEmpty ? joined : combined)
            }
            notes = folded
            if round > 4 { break }   // safety valve on pathological input
        }

        try Task.checkCancellation()
        progress(0.85, L10n.text("Writing the summary"))

        let combined = notes.joined(separator: "\n\n")
        let finalPrompt = """
        Below are notes from a recording. Write the result in Markdown with exactly these three \
        sections and nothing else:

        ## Summary
        Two or three sentences describing what the recording was about.

        ## Key points
        Bullet points of the most important content.

        ## Action items
        Bullet points in the form "Who - what - when" for anything someone said they would do. \
        Write "None" if there are none.

        Use only what is in the notes. Do not invent names, dates or tasks.

        \(combined)
        """
        let summary = try await answer(finalPrompt, model: model, engine: engine)

        try Task.checkCancellation()
        progress(0.95, L10n.text("Naming the recording"))

        var title = fallbackTitle(from: transcript)
        let titlePrompt = """
        Give this recording a short title of 3 to 6 words. Reply with the title only, \
        with no quotes and no explanation.

        \(summary.prefix(1200))
        """
        if let generated = try? await answer(titlePrompt, model: model, engine: engine) {
            let cleaned = cleanTitle(generated)
            if !cleaned.isEmpty { title = cleaned }
        }

        progress(1.0, L10n.text("Done"))
        return Result(title: title, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One question, one clean session, the whole answer as a string.
    @MainActor
    private static func answer(_ prompt: String, model: AIModel, engine: ChatEngine) async throws -> String {
        try await engine.startCleanSession(model: model)
        var final = ""
        for try await snapshot in engine.respondStream(model: model, prompt: prompt, image: nil) {
            final = snapshot
        }
        return final.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
