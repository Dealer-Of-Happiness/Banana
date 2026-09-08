//
//  TranslateModeView.swift
//  AIGoodbye
//
//  Two-way conversation translator that works with no connection at all:
//  Apple's offline speech recognition listens, the on-device model
//  translates, and the on-device voice speaks the result back. Made for
//  planes, borders and anywhere roaming data isn't an option.
//

import SwiftUI
import NaturalLanguage

struct TranslateModeView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var voice = VoiceService()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let original: String
        var translation: String
        let fromMine: Bool     // true = spoken by the phone's owner
    }

    @State private var myLanguage: AppLanguage = .english
    @State private var theirLanguage: AppLanguage = .spanish
    @State private var turns: [Turn] = []
    @State private var listeningForMine: Bool?     // nil = idle
    @State private var isTranslating = false
    @State private var notice: String?
    @State private var permissionDenied = false
    @State private var isActive = true

    /// Hands-free: keep listening, translating and speaking, alternating
    /// sides automatically so nobody has to touch the phone.
    @State private var isHandsFree = false
    /// Whose turn hands-free mode expects next.
    @State private var handsFreeExpectsMine = true

    private var languageChoices: [AppLanguage] {
        AppLanguage.pickerOrder.filter { $0 != .automatic }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            languageBar
            transcript
            controls
        }
        .background(Color(.systemGroupedBackground))
        .onAppear(perform: start)
        .onDisappear {
            isActive = false
            voice.shutdown()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                voice.pause()
                listeningForMine = nil
                // Don't keep the microphone running in the background.
                isHandsFree = false
            }
        }
        .onChange(of: voice.listeningState) { _, state in
            listeningStateChanged(state)
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Translate")
                    .font(.headline)
                Text("Works with no internet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("Close translate"))
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var languageBar: some View {
        HStack(spacing: 12) {
            picker(for: $myLanguage, label: L10n.text("You"))

            Button {
                let mine = myLanguage
                myLanguage = theirLanguage
                theirLanguage = mine
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("Swap languages"))

            picker(for: $theirLanguage, label: L10n.text("Them"))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func picker(for binding: Binding<AppLanguage>, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker(label, selection: binding) {
                ForEach(languageChoices) { language in
                    Text(verbatim: language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if turns.isEmpty && notice == nil {
                        VStack(spacing: 8) {
                            Image(systemName: "character.bubble")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("Start hands-free and just talk: it listens, translates out loud, then listens again. Or tap a language to take one turn at a time.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 60)
                        .padding(.horizontal, 32)
                    }

                    if let notice {
                        Text(notice)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }

                    ForEach(turns) { turn in
                        bubble(for: turn)
                            .id(turn.id)
                    }

                    if !voice.liveTranscript.isEmpty {
                        Text(voice.liveTranscript)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity,
                                   alignment: listeningForMine == true ? .trailing : .leading)
                            .padding(.horizontal)
                    } else if voice.listeningState == .preparing {
                        VStack(spacing: 6) {
                            if voice.preparingProgress > 0 {
                                Text("Downloading the speech model for this language...")
                                ProgressView(value: voice.preparingProgress)
                                    .frame(maxWidth: 220)
                            } else {
                                Text("Getting ready to listen...")
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .onChange(of: turns.count) { _, _ in
                withAnimation { proxy.scrollTo(turns.last?.id, anchor: .bottom) }
            }
        }
    }

    private func bubble(for turn: Turn) -> some View {
        HStack {
            if turn.fromMine { Spacer(minLength: 40) }

            VStack(alignment: turn.fromMine ? .trailing : .leading, spacing: 6) {
                Text(turn.original)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(turn.translation.isEmpty ? "..." : turn.translation)
                    .font(.title3.weight(.medium))
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(turn.fromMine ? Color.blue.opacity(0.12) : Color(.secondarySystemGroupedBackground))
            )
            .frame(maxWidth: .infinity, alignment: turn.fromMine ? .trailing : .leading)

            if !turn.fromMine { Spacer(minLength: 40) }
        }
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            // Hands-free: the phone can sit on the table between two people.
            Button {
                toggleHandsFree()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isHandsFree ? "stop.circle.fill" : "infinity.circle.fill")
                        .font(.title3)
                    Text(isHandsFree ? "Stop hands-free" : "Hands-free conversation")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isHandsFree ? Color.red.opacity(0.15) : Color.blue.opacity(0.15))
                )
                .foregroundStyle(isHandsFree ? .red : .blue)
            }
            .buttonStyle(.plain)
            .disabled(permissionDenied)
            .accessibilityHint(Text("Listens, translates and speaks continuously, switching languages automatically"))

            if !isHandsFree {
                HStack(spacing: 12) {
                    talkButton(mine: true, language: myLanguage)
                    talkButton(mine: false, language: theirLanguage)
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private func talkButton(mine: Bool, language: AppLanguage) -> some View {
        let isListening = listeningForMine == mine
        return Button {
            if isListening {
                voice.stopListening()
                listeningForMine = nil
            } else {
                beginListening(mine: mine)
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: isListening ? "mic.fill" : "mic")
                    .font(.title2)
                Text(verbatim: language.displayName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isListening ? Color.blue.opacity(0.25) : Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(isTranslating || permissionDenied)
        .accessibilityLabel(Text(mine ? L10n.text("Speak in your language") : L10n.text("Speak in their language")))
    }

    // MARK: - Flow

    private func start() {
        // Default the user's side to the app language when it's a real one.
        if appState.settings.appLanguage != .automatic {
            myLanguage = appState.settings.appLanguage
            if theirLanguage == myLanguage {
                theirLanguage = myLanguage == .english ? .spanish : .english
            }
        }

        voice.onFinalTranscript = { text in
            Task { @MainActor in
                guard isActive else { return }
                var wasMine = listeningForMine ?? true
                listeningForMine = nil

                // Hands-free alternates automatically, but people don't take
                // perfect turns - if what was actually said looks like the
                // other language, believe the words, not the schedule.
                if isHandsFree, let detected = Self.detectedSide(
                    of: text, mine: myLanguage, theirs: theirLanguage
                ) {
                    wasMine = detected
                }
                await translate(text, fromMine: wasMine)
            }
        }
        voice.onListeningEnded = {
            Task { @MainActor in
                if listeningForMine != nil { listeningForMine = nil }
                // Nothing was said (silence timeout): keep the conversation
                // alive by listening again.
                if isHandsFree, isActive, !isTranslating, !voice.isSpeaking {
                    beginListening(mine: handsFreeExpectsMine)
                }
            }
        }
        voice.onFinishedSpeaking = {
            Task { @MainActor in
                guard isHandsFree, isActive, !isTranslating else { return }
                beginListening(mine: handsFreeExpectsMine)
            }
        }

        Task {
            let granted = await VoiceService.requestPermissions()
            if !granted {
                permissionDenied = true
                notice = L10n.text("AiGoodbye needs microphone access for voice conversations. You can enable it in the Settings app.")
            }
        }
    }

    private func beginListening(mine: Bool) {
        voice.stopSpeaking()
        notice = nil
        listeningForMine = mine
        // Asynchronous: the outcome arrives through `voice.listeningState`,
        // handled in `listeningStateChanged`.
        voice.startListening(language: mine ? myLanguage : theirLanguage)
    }

    private func listeningStateChanged(_ state: VoiceService.ListeningState) {
        guard isActive else { return }
        if case .unavailable(let reason) = state {
            // Shown, rather than the old silent return to idle that made
            // the translator look broken. Hands-free can't continue without
            // a working recognizer, so it stops too.
            notice = reason
            listeningForMine = nil
            isHandsFree = false
        }
    }

    private func translate(_ text: String, fromMine: Bool) async {
        let target = fromMine ? theirLanguage : myLanguage
        let source = fromMine ? myLanguage : theirLanguage

        var turn = Turn(original: text, translation: "", fromMine: fromMine)
        turns.append(turn)
        isTranslating = true
        defer { isTranslating = false }

        let engine = appState.engine
        do {
            let model = try engine.route(hasImage: false)
            // A dedicated, throwaway session: translation must not inherit
            // the chat's persona, memory or history - a "Brainstorm Partner"
            // persona would turn a translation into a discussion. Claiming
            // the engine also keeps a summary running elsewhere from tearing
            // this session down mid-sentence.
            guard engine.claimUtility() else {
                turns.removeAll { $0.id == turn.id }
                notice = L10n.text("The AI is busy with another task. Try again in a moment.")
                return
            }
            defer { engine.releaseUtility() }
            try await engine.startCleanSession(model: model)

            let prompt = """
            Translate the following text from \(source.englishName) into \(target.englishName).
            Reply with the translation only - no quotes, no explanation, no transliteration.

            \(text)
            """

            var final = ""
            for try await snapshot in engine.respondStream(model: model, prompt: prompt, image: nil) {
                final = snapshot
                if let index = turns.firstIndex(where: { $0.id == turn.id }) {
                    turns[index].translation = snapshot
                }
            }

            let cleaned = Self.cleanTranslation(final)
            if let index = turns.firstIndex(where: { $0.id == turn.id }) {
                turns[index].translation = cleaned
            }
            turn.translation = cleaned

            // Speak the result in the target language.
            voice.setSpeechLanguage(target)
            // In hands-free mode the next speaker is whoever DIDN'T just
            // talk, so listening resumes in the right language.
            handsFreeExpectsMine = !fromMine
            voice.speak(cleaned)
        } catch let error as ChatEngine.RouteError {
            turns.removeAll { $0.id == turn.id }
            notice = error.errorDescription
            isHandsFree = false
        } catch {
            turns.removeAll { $0.id == turn.id }
            notice = error.localizedDescription
            isHandsFree = false
        }
    }

    // MARK: - Hands-free

    private func toggleHandsFree() {
        isHandsFree.toggle()
        if isHandsFree {
            notice = nil
            handsFreeExpectsMine = true
            beginListening(mine: true)
        } else {
            voice.stopListening(notify: false)
            voice.stopSpeaking()
            listeningForMine = nil
        }
    }

    /// Which side a transcript sounds like, or nil when it's inconclusive.
    /// Lets hands-free mode recover when people speak out of turn.
    static func detectedSide(of text: String, mine: AppLanguage, theirs: AppLanguage) -> Bool? {
        guard text.count >= 12, mine != theirs else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }

        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard (hypotheses[dominant] ?? 0) > 0.75 else { return nil }

        let code = dominant.rawValue          // e.g. "en", "es", "zh-Hans"
        func matches(_ language: AppLanguage) -> Bool {
            let raw = language.rawValue
            return raw == code
                || raw.split(separator: "-").first.map(String.init) == code.split(separator: "-").first.map(String.init)
        }
        if matches(mine) { return true }
        if matches(theirs) { return false }
        return nil
    }

    /// Models sometimes wrap translations in quotes or add a preamble.
    static func cleanTranslation(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a leading "Translation:" style label - but never a colon that
        // belongs to the content itself ("It's 10:30", "Ratio 3:1").
        if let colon = text.firstIndex(of: ":") {
            let prefix = text[text.startIndex..<colon]
            let looksLikeLabel =
                prefix.count < 20 &&
                prefix.rangeOfCharacter(from: .newlines) == nil &&
                prefix.rangeOfCharacter(from: .decimalDigits) == nil &&
                prefix.split(separator: " ").count <= 2 &&
                !text.hasPrefix("http")
            if looksLikeLabel {
                let after = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty { text = after }
            }
        }
        // Strip surrounding quotes.
        let quotes: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("«", "»"), ("“", "”")]
        for (open, close) in quotes where text.first == open && text.last == close && text.count > 1 {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
