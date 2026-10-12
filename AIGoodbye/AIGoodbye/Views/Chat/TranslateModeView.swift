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
import UIKit
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
        /// The language the translation is in, so a replay uses the right
        /// voice even after the pair has been changed or swapped.
        var target: AppLanguage? = nil
    }

    /// Remembered between visits: a traveller in Japan used to pick Japanese
    /// out of a thirteen-item menu every time the sheet opened.
    @AppStorage("translate.mine") private var myLanguage: AppLanguage = .english
    @AppStorage("translate.theirs") private var theirLanguage: AppLanguage = .spanish
    @State private var turns: [Turn] = []
    @State private var listeningForMine: Bool?     // nil = idle
    @State private var isTranslating = false
    @State private var notice: String?
    @State private var permissionDenied = false
    @State private var isActive = true
    /// False while the scene is not `.active`; nothing is spoken then.
    @State private var inForeground = true
    /// The translation in flight, so closing the sheet can cancel it. Left
    /// untracked, it finished after the sheet was gone, spoke the result into
    /// an empty room and held the engine claim until then.
    @State private var translateTask: Task<Void, Never>?

    /// Hands-free: keep listening, translating and speaking, alternating
    /// sides automatically so nobody has to touch the phone.
    @State private var isHandsFree = false
    /// Whose turn hands-free mode expects next.
    @State private var handsFreeExpectsMine = true
    /// Hands-free listens that ended with nothing said, in a row. Each one
    /// is about 30 seconds of silence (`VoiceService.emptyListenLimit`).
    @State private var emptyListens = 0
    /// About two minutes of silence. A session forgotten on a table must not
    /// keep the microphone - and, with the screen held awake, the display -
    /// on indefinitely.
    private let emptyListenCap = 4

    private var languageChoices: [AppLanguage] {
        AppLanguage.pickerOrder.filter { $0 != .automatic }
    }

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                languageBar
                transcript
                controls
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Translate")
            .navigationSubtitle("Works with no internet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        dismiss()
                    }
                    .accessibilityLabel(Text("Close translate"))
                }
            }
        }
        // VoiceOver's two-finger double tap starts or stops hands-free from
        // anywhere on the screen.
        .accessibilityAction(.magicTap) {
            guard !permissionDenied else { return }
            toggleHandsFree()
        }
        .onAppear(perform: start)
        .onDisappear {
            isActive = false
            // Cancelled, not merely orphaned: the stream ends within a token,
            // which also releases the engine claim promptly.
            translateTask?.cancel()
            translateTask = nil
            voice.shutdown()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            inForeground = (phase == .active)
            switch phase {
            case .active:
                updateIdleTimer()
            case .background:
                voice.pause()
                listeningForMine = nil
                // Don't keep the microphone running in the background.
                isHandsFree = false
                UIApplication.shared.isIdleTimerDisabled = false
            case .inactive:
                // Control Center, the app switcher, a system alert - including
                // the one-time Speech Recognition prompt a first listen in
                // some languages shows. The screen is still there: the listen
                // and hands-free survive (switching hands-free off here turned
                // it off the moment the user enabled it). Only the speaker is
                // silenced, and hands-free listens again in its place.
                if voice.isSpeaking {
                    voice.stopSpeaking()
                    resumeHandsFreeIfIdle()
                }
            default:
                break
            }
        }
        .onChange(of: voice.listeningState) { _, state in
            listeningStateChanged(state)
        }
        .onChange(of: isHandsFree) { _, _ in updateIdleTimer() }
        .onChange(of: listeningForMine) { old, new in
            updateIdleTimer()
            // Announced as the listen is requested, before the microphone is
            // live, so VoiceOver's own voice isn't the first thing the
            // recognizer hears; the begin tone marks the live moment.
            if old == nil, new != nil { announceForVoiceOver(L10n.text("Listening")) }
        }
        .onChange(of: isTranslating) { _, translating in
            updateIdleTimer()
            if translating { announceForVoiceOver(L10n.text("Translating")) }
        }
        .onChange(of: voice.isSpeaking) { _, _ in updateIdleTimer() }
        // Felt rather than seen: the phone is often on a table between two
        // people. Behind the Haptic Feedback setting.
        .sensoryFeedback(trigger: listeningForMine) { old, new in
            guard old == nil, new != nil, appState.settings.hapticFeedbackEnabled else { return nil }
            return .start
        }
        .sensoryFeedback(trigger: isTranslating) { wasTranslating, translating in
            guard wasTranslating, !translating, appState.settings.hapticFeedbackEnabled else { return nil }
            return .success
        }
        // A swipe would otherwise close the sheet under a live microphone or
        // a translation in progress; Close still works.
        .interactiveDismissDisabled(isHandsFree || listeningForMine != nil || isTranslating)
    }

    // MARK: - Pieces

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
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
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
                        .padding(.top, verticalSizeClass == .compact ? 12 : 60)
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
        // Not the line still streaming in: it is spoken by itself the moment
        // it is done.
        let canReplay = !turn.translation.isEmpty && !(isTranslating && turn.id == turns.last?.id)
        return HStack {
            if turn.fromMine { Spacer(minLength: 40) }

            VStack(alignment: turn.fromMine ? .trailing : .leading, spacing: 6) {
                Text(turn.original)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(turn.translation.isEmpty ? "..." : turn.translation)
                        .font(.title3.weight(.medium))
                        .textSelection(.enabled)
                    if canReplay {
                        Image(systemName: "speaker.wave.2")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(turn.fromMine ? Color.blue.opacity(0.12) : Color(.secondarySystemGroupedBackground))
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
            // A noisy counter means the other person often missed it; this
            // replays the line instead of making someone say it again.
            .onTapGesture {
                if canReplay { replay(turn) }
            }
            .frame(maxWidth: .infinity, alignment: turn.fromMine ? .trailing : .leading)

            if !turn.fromMine { Spacer(minLength: 40) }
        }
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(canReplay ? .isButton : [])
        .accessibilityHint(Text(verbatim: canReplay ? L10n.text("Double tap to hear the translation again") : ""))
        .accessibilityAction {
            if canReplay { replay(turn) }
        }
    }

    /// Say a translation again, in the voice of the language it is in.
    private func replay(_ turn: Turn) {
        guard isActive, inForeground, !turn.translation.isEmpty else { return }
        // Speaking cuts a live listen off without telling anyone, which left
        // a talk button lit over a dead microphone. End it properly instead;
        // hands-free listens again when the replay finishes.
        if voice.isListeningOrPreparing || listeningForMine != nil {
            voice.stopListening(notify: false)
            listeningForMine = nil
        }
        voice.stopSpeaking()
        voice.setSpeechLanguage(turn.target ?? (turn.fromMine ? theirLanguage : myLanguage))
        voice.speak(turn.translation)
    }

    /// Stacked on a phone held upright; one row when the window is short
    /// (a landscape phone, an iPhone Duo on its side), where two rows of
    /// buttons left almost no room for the conversation itself.
    @ViewBuilder
    private var controls: some View {
        let compact = verticalSizeClass == .compact
        Group {
            if compact {
                HStack(spacing: 10) {
                    handsFreeButton
                    if !isHandsFree {
                        talkButton(mine: true, language: myLanguage)
                        talkButton(mine: false, language: theirLanguage)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    handsFreeButton
                    if !isHandsFree {
                        HStack(spacing: 12) {
                            talkButton(mine: true, language: myLanguage)
                            talkButton(mine: false, language: theirLanguage)
                        }
                    }
                }
            }
        }
        .padding(compact ? 10 : 16)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var handsFreeButton: some View {
        // Hands-free: the phone can sit on the table between two people.
        Button {
            toggleHandsFree()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isHandsFree ? "stop.circle.fill" : "infinity.circle.fill")
                    .font(.title3)
                Text(isHandsFree ? "Stop hands-free" : "Hands-free conversation")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
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
    }

    private func talkButton(mine: Bool, language: AppLanguage) -> some View {
        let isListening = listeningForMine == mine
        return Button {
            if isListening {
                // Tap to send, as in Apple Translate: what was said so far is
                // translated now. `listeningForMine` is left for the
                // callbacks - `onFinalTranscript` reads it to know whose
                // words these were, then clears it.
                if voice.isListeningOrPreparing {
                    voice.finishListeningNow()
                } else {
                    listeningForMine = nil
                }
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
            .frame(maxWidth: .infinity, minHeight: verticalSizeClass == .compact ? 48 : 62)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isListening ? Color.blue.opacity(0.25) : Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(isTranslating || permissionDenied)
        // Which language this button listens in (the visible text, which the
        // old label replaced), and whether the microphone is open now.
        .accessibilityLabel(Text(verbatim: mine
            ? L10n.text("Speak in your language, \(language.displayName)")
            : L10n.text("Speak in their language, \(language.displayName)")))
        .accessibilityValue(Text(verbatim: isListening ? L10n.text("Listening") : ""))
        .accessibilityAddTraits(isListening ? .isSelected : [])
    }

    // MARK: - Flow

    private func start() {
        voice.playsListeningSounds = appState.settings.listeningSounds
        voice.speechRate = Float(appState.settings.speechRate)
        // First visit only: the user's side defaults to the app language
        // when it's a real one. After that the remembered pair stands.
        if UserDefaults.standard.string(forKey: "translate.mine") == nil,
           appState.settings.appLanguage != .automatic {
            myLanguage = appState.settings.appLanguage
        }
        // "Automatic" is not a language anyone speaks, and one language on
        // both sides translates nothing.
        if myLanguage == .automatic { myLanguage = .english }
        if theirLanguage == .automatic || theirLanguage == myLanguage {
            theirLanguage = myLanguage == .english ? .spanish : .english
        }

        voice.onFinalTranscript = { text in
            translateTask = Task { @MainActor in
                guard isActive else { return }
                // Somebody spoke: the silence count starts over.
                emptyListens = 0
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
                // Normally the spoken translation's `onFinishedSpeaking`
                // listens again. When nothing was spoken - the model returned
                // nothing sayable, the engine was busy, the screen was away -
                // hands-free has to be re-armed here or it sits "on" and dead.
                guard !Task.isCancelled else { return }
                resumeHandsFreeIfIdle()
            }
        }
        voice.onListeningEnded = {
            Task { @MainActor in
                if listeningForMine != nil { listeningForMine = nil }
                guard isActive else { return }
                if isHandsFree {
                    emptyListens += 1
                    if emptyListens >= emptyListenCap {
                        stopHandsFreeAfterSilence()
                        return
                    }
                }
                // Nothing was said (silence timeout): keep the conversation
                // alive by listening again.
                resumeHandsFreeIfIdle()
            }
        }
        voice.onFinishedSpeaking = {
            Task { @MainActor in
                resumeHandsFreeIfIdle()
            }
        }
        voice.onSpeechInterrupted = {
            Task { @MainActor in
                // A phone call or Siri took the audio. The synthesizer will
                // not finish, so hands-free would never listen again; say why
                // it stopped rather than leaving "Stop hands-free" on a screen
                // where nothing happens.
                guard isActive, isHandsFree else { return }
                isHandsFree = false
                listeningForMine = nil
                notice = L10n.text("Hands-free stopped because another app took over the audio.")
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

    /// - Parameter clearingNotice: false when hands-free re-arms itself after
    ///   a step that produced a notice ("the AI is busy"), so the user gets
    ///   to read why that turn went untranslated while the next one is heard.
    private func beginListening(mine: Bool, clearingNotice: Bool = true) {
        voice.stopSpeaking()
        if clearingNotice { notice = nil }
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

        var turn = Turn(original: text, translation: "", fromMine: fromMine, target: target)
        turns.append(turn)
        isTranslating = true
        defer { isTranslating = false }

        let engine = appState.engine
        do {
            // `requiresDownloaded`: a model that is approved but not yet on
            // disk would otherwise begin a multi-gigabyte download behind a
            // bubble showing "...", with no consent, progress or Wi-Fi check.
            // The chat screen owns downloads; the notice sends the user there.
            let model = try engine.route(hasImage: false, requiresDownloaded: true)
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
            // Without the app-language line: the system prompt saying
            // "always respond in <app language>" contradicted the prompt's
            // own target language, and a 2B model sometimes obeyed the wrong
            // one.
            try await engine.startCleanSession(model: model, languageInstruction: false)

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

            // The sheet may have been closed while the model was working;
            // nothing is spoken into an empty room.
            guard isActive, !Task.isCancelled else { return }

            let cleaned = Self.cleanTranslation(final)
            if let index = turns.firstIndex(where: { $0.id == turn.id }) {
                turns[index].translation = cleaned
            }
            turn.translation = cleaned
            // A translation came through, so a notice from an earlier turn
            // ("the AI is busy") that hands-free kept on screen is done with.
            notice = nil

            // Speak the result in the target language.
            voice.setSpeechLanguage(target)
            // In hands-free mode the next speaker is whoever DIDN'T just
            // talk, so listening resumes in the right language.
            handsFreeExpectsMine = !fromMine
            // Not while the screen is away (Control Center, the switcher):
            // the bubble has the text. `speak` is also false when the model
            // produced nothing sayable; either way the caller re-arms
            // hands-free, since no `onFinishedSpeaking` will come.
            if inForeground { voice.speak(cleaned) }
        } catch is CancellationError {
            // The sheet was closed mid-translation.
            turns.removeAll { $0.id == turn.id }
        } catch let error as ChatEngine.RouteError {
            turns.removeAll { $0.id == turn.id }
            notice = Self.routeNotice(for: error)
            isHandsFree = false
        } catch {
            guard isActive, !Task.isCancelled else { return }
            turns.removeAll { $0.id == turn.id }
            notice = error.localizedDescription
            isHandsFree = false
        }
    }

    private static func routeNotice(for error: ChatEngine.RouteError) -> String {
        switch error {
        case .needsDownloadConsent(let model), .visionNeedsDownloadedModel(let model):
            return L10n.text("Translating needs the \(model.name) model. Download it from the chat screen first.")
        case .nothingAvailable(let reason):
            return reason
        }
    }

    // MARK: - Hands-free

    /// Keep the screen on while the translator is working. Hands-free is made
    /// for a phone lying on a table between two people that nobody touches,
    /// and the default auto-lock backgrounded the app half a minute in, which
    /// stops the microphone and switched hands-free off mid-conversation.
    /// Released as soon as nothing is listening, translating or speaking.
    private func updateIdleTimer() {
        let working = isHandsFree || listeningForMine != nil || isTranslating || voice.isSpeaking
        UIApplication.shared.isIdleTimerDisabled = isActive && scenePhase != .background && working
    }

    /// VoiceOver only; without it the status on screen, the tones and the
    /// haptics say the same thing.
    private func announceForVoiceOver(_ text: String) {
        guard isActive, UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// Listen again if hands-free is on and nothing else is happening: no
    /// translation running, nothing being spoken, no listen already under
    /// way. Every path that ends a hands-free step funnels through here, so a
    /// step that produces no speech (and therefore no `onFinishedSpeaking`)
    /// cannot leave the mode switched on and dead.
    private func resumeHandsFreeIfIdle() {
        guard isHandsFree, isActive, !isTranslating,
              !voice.isSpeaking, !voice.isListeningOrPreparing else { return }
        beginListening(mine: handsFreeExpectsMine, clearingNotice: false)
    }

    /// Two minutes with nobody speaking: switch hands-free off and say so,
    /// out loud as well, because the phone is probably lying on a table and
    /// nobody is looking at it.
    private func stopHandsFreeAfterSilence() {
        isHandsFree = false
        emptyListens = 0
        listeningForMine = nil
        voice.stopListening(notify: false)
        let message = L10n.text("Hands-free stopped after two minutes of silence. Tap to start again.")
        notice = message
        guard inForeground else { return }
        // In the app's language: the notice is UI text, whichever pair of
        // languages the conversation was in.
        voice.setSpeechLanguage(appState.settings.appLanguage)
        voice.speak(message)
    }

    private func toggleHandsFree() {
        isHandsFree.toggle()
        if isHandsFree {
            notice = nil
            emptyListens = 0
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
        // Two varieties of one language (Mandarin and Cantonese: "zh-Hans"
        // and "zh-HK") both match on the base code "zh", and the recognizer
        // reports neither of those tags, so "mine" won for every Chinese
        // utterance and the Cantonese speaker was never translated. The
        // schedule knows whose turn it is; the words cannot tell.
        guard baseLanguage(of: mine) != baseLanguage(of: theirs) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }

        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard (hypotheses[dominant] ?? 0) > 0.75 else { return nil }

        let code = dominant.rawValue          // e.g. "en", "es", "zh-Hans"
        func matches(_ language: AppLanguage) -> Bool {
            let raw = language.rawValue
            return raw == code
                || baseLanguage(of: language) == code.split(separator: "-").first.map(String.init)
        }
        if matches(mine) { return true }
        if matches(theirs) { return false }
        return nil
    }

    /// "zh" for both Mandarin ("zh-Hans") and Cantonese ("zh-HK").
    private static func baseLanguage(of language: AppLanguage) -> String? {
        language.rawValue.split(separator: "-").first.map(String.init)
    }

    /// Labels a model puts in front of a translation, in the languages the
    /// translator offers, lowercased.
    nonisolated private static let translationLabels: Set<String> = [
        "translation", "traducción", "übersetzung", "traduction", "traduzione", "tradução",
        "перевод", "переклад", "μετάφραση", "翻訳", "译文", "翻譯", "번역"
    ]

    /// Models sometimes wrap translations in quotes or add a preamble.
    nonisolated static func cleanTranslation(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a leading "Translation:" label - only a known one. Any short
        // phrase before a colon used to go, which ate real content: "Warning:
        // wet floor" was spoken as "wet floor", "Note: bring ID" as "bring
        // ID". A colon inside the content ("It's 10:30") is never a label.
        if let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            // "**Translation:**" is the same label in Markdown bold.
            let label = text[text.startIndex..<colon]
                .trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))
                .lowercased()
            if translationLabels.contains(label) {
                // Only the bold markers right after the label go; the end of
                // the translation is left as the model wrote it.
                let after = String(text[text.index(after: colon)...].drop { $0 == "*" })
                    .trimmingCharacters(in: .whitespacesAndNewlines)
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
