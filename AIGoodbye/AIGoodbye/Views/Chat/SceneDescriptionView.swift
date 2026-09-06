//
//  SceneDescriptionView.swift
//  AIGoodbye
//
//  Describe Surroundings: the camera looks, the on-device model describes,
//  and the phone speaks it aloud - over and over, hands free. Built for blind
//  and low-vision users, and unlike every cloud alternative it keeps working
//  on a plane, in a basement, abroad, and without sending a single frame of
//  someone's home to a server.
//
//  Reading mode swaps the model for Vision's OCR, so a sign, a menu or a
//  letter is read back word for word instead of being summarized.
//
//  The loop must never stop silently: a user who cannot see the screen has
//  no way to tell "nothing to describe" from "the app broke". Every exit
//  path either schedules the next turn or says out loud why it stopped.
//

import SwiftUI
import UIKit

struct SceneDescriptionView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var camera = CameraController()
    @StateObject private var voice = VoiceService()

    enum Mode: String, CaseIterable, Identifiable {
        case brief, detailed, text
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .brief: return "Quick"
            case .detailed: return "Detailed"
            case .text: return "Read text"
            }
        }

        var symbol: String {
            switch self {
            case .brief: return "eye"
            case .detailed: return "eye.circle"
            case .text: return "text.viewfinder"
            }
        }
    }

    @State private var mode: Mode = .brief
    @State private var isContinuous = true
    @State private var isDescribing = false
    @State private var latest = ""
    @State private var notice: String?
    @State private var describeTask: Task<Void, Never>?
    @State private var currentTurn = UUID()
    @State private var isActive = true
    /// How many times in a row the camera had no frame to give us.
    @State private var warmUpAttempts = 0
    /// How many times in a row the model was busy with something else.
    @State private var busyAttempts = 0
    /// The fast Vision answer is spoken once per burst, not per turn.
    @State private var spokeQuickImpression = false
    /// The last thing spoken, so continuous mode can stay quiet when nothing
    /// has changed instead of repeating itself every two seconds.
    @State private var lastSpoken = ""
    /// Consecutive turns suppressed as unchanged. Used to back the interval
    /// off, so standing still doesn't mean silent full-rate inference with
    /// the GPU pegged and the phone getting hot.
    @State private var suppressedInARow = 0

    /// Quiet gap between one description finishing and the next starting.
    private let pauseBetween: TimeInterval = 1.5

    /// True when this screen is doing the talking, so VoiceOver shouldn't
    /// also read the same text.
    ///
    /// Deliberately not `isContinuous`: that hid the description for the
    /// whole session, so a low-vision VoiceOver user - or anyone on a Braille
    /// display, which hears nothing at all - could never read it.
    private var isSpeakingAloud: Bool { voice.isSpeaking }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !camera.failed {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                // Dim the viewfinder: this screen is meant to be listened to,
                // and a dimmer preview saves battery on a long walk.
                Color.black.opacity(0.35).ignoresSafeArea()
            }

            VStack(spacing: 14) {
                topBar
                Spacer(minLength: 0)
                transcriptPanel
                controls
            }
        }
        .onAppear(perform: start)
        .onDisappear {
            isActive = false
            describeTask?.cancel()
            camera.stop()
            voice.shutdown()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: camera.failed) { _, failed in
            guard failed else { return }
            stopLoop(reason: L10n.text("The camera isn't available. Check camera permission in the Settings app."))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // `retry` rather than `start`: a camera that was busy because
                // another app had it latched `failed`, and the screen then
                // stayed dead however many times the user came back to it.
                camera.retry()
                if isContinuous {
                    UIApplication.shared.isIdleTimerDisabled = true
                    scheduleNext(after: 0.6)
                }
            } else {
                describeTask?.cancel()
                camera.stop()
                voice.pause()
                isDescribing = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        .onChange(of: mode) { _, _ in
            voice.stopSpeaking()
            notice = nil
            // A new mode is a new burst: reset both the fast-answer flag and
            // the repeat suppressor, so switching modes always says
            // something.
            spokeQuickImpression = false
            lastSpoken = ""
            if isContinuous { scheduleNext(after: 0.2) }
        }
        .onChange(of: isContinuous) { _, on in
            UIApplication.shared.isIdleTimerDisabled = on
            if on {
                spokeQuickImpression = false
                lastSpoken = ""
                scheduleNext(after: 0.2)
            } else {
                describeTask?.cancel()
                voice.stopSpeaking()
                isDescribing = false
            }
        }
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Describe Surroundings")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Spoken aloud · 100% on-device")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(minWidth: 56, minHeight: 56)
            }
            .accessibilityLabel(Text("Close describe surroundings"))
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var transcriptPanel: some View {
        if let notice {
            Text(notice)
                .font(.subheadline)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
                .accessibilityAddTraits(.isStaticText)
        }
        if !latest.isEmpty {
            ScrollView {
                Text(latest)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
            .defaultScrollAnchor(.bottom)
            // `.contain`, or the label lands on a ScrollView that is not an
            // accessibility element and is simply discarded.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Latest description"))
            // Hidden from VoiceOver while the app is speaking it: otherwise
            // the value changes on every streamed token and VoiceOver
            // re-announces the whole growing text on top of our own voice,
            // and the block sits between the header and the controls so the
            // user has to swipe through all of it to reach the buttons.
            .accessibilityHidden(isSpeakingAloud)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Detail", selection: $mode) {
                ForEach(Mode.allCases) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Button {
                describeNow()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isDescribing ? "waveform" : "eye.fill")
                        .font(.title2)
                    Text(isDescribing ? "Looking..." : "Describe now")
                        .font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 68)
                .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .accessibilityHint(Text("Describes what the camera is pointed at right now"))

            // There was no way to hear a description again once it had been
            // spoken - and missing one while a bus goes past is normal.
            if !latest.isEmpty {
                Button {
                    voice.stopSpeaking()
                    voice.speak(latest)
                } label: {
                    Label("Repeat that", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .accessibilityHint(Text("Says the last description again"))
            }

            Toggle(isOn: $isContinuous) {
                Text("Keep describing")
                    .foregroundStyle(.white)
            }
            .tint(.blue)
            .padding(.horizontal)
        }
        .padding(.bottom, 14)
    }

    // MARK: - Flow

    private func start() {
        // Restored here, not only initialised: nothing else sets it back, so
        // reusing this view would give a permanently silent screen.
        isActive = true
        camera.start()
        voice.setSpeechLanguage(appState.settings.appLanguage)
        voice.onFinishedSpeaking = {
            Task { @MainActor in
                guard isActive, isContinuous else { return }
                // `!isDescribing` matters: the fast "Looks like..." answer
                // finishes speaking about a second in, while the model is
                // still generating the real description. Without this guard
                // that utterance scheduled the next turn, which cancelled the
                // generation the user was actually waiting for.
                guard !isDescribing else { return }
                scheduleNext(after: pauseBetween)
            }
        }
        if isContinuous {
            UIApplication.shared.isIdleTimerDisabled = true
            scheduleNext(after: 1.2)
        }
    }

    private func describeNow() {
        // A deliberate tap starts a new burst, so the fast first answer
        // applies again - and must always speak, even if the scene has not
        // changed since the last one. Asking and hearing nothing back is
        // indistinguishable from a broken app.
        spokeQuickImpression = false
        lastSpoken = ""
        suppressedInARow = 0
        scheduleNext(after: 0)
    }

    /// Always cancels whatever is running and queues a fresh turn. It must
    /// never bail out on `isDescribing`, or the loop dies the first time a
    /// turn ends without speech.
    private func scheduleNext(after delay: TimeInterval) {
        guard isActive, !camera.failed else { return }
        let previous = describeTask
        previous?.cancel()
        let turn = UUID()
        currentTurn = turn
        describeTask = Task {
            // Wait for the previous turn to actually finish: two generations
            // against one MLX container would each drop the other's session.
            //
            // Bounded, because "forever" is a real possibility here - a
            // framework call that ignores cancellation would otherwise wedge
            // not just that turn but every turn after it, and the screen goes
            // silent with no way back.
            await Timeout.join(previous, seconds: 8)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, isActive, currentTurn == turn else { return }
            await describe(turn: turn)
        }
    }

    /// Stop the loop and say why, because a silent stop is indistinguishable
    /// from a broken app when you can't see the screen.
    private func stopLoop(reason: String) {
        describeTask?.cancel()
        isDescribing = false
        isContinuous = false
        UIApplication.shared.isIdleTimerDisabled = false
        notice = reason
        // Speak after the toggle change has settled, so the state change
        // doesn't stop the very announcement explaining it. With VoiceOver
        // on, let VoiceOver say it - doing both means the user hears the
        // same sentence twice, overlapping.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard isActive else { return }
            if UIAccessibility.isVoiceOverRunning {
                // High priority, or iOS drops it: flipping the toggle above
                // makes VoiceOver announce "Keep describing, off", and a
                // default-priority announcement arriving while VoiceOver is
                // still speaking is discarded - leaving the user with a
                // screen that stopped for no stated reason.
                var announcement = AttributedString(reason)
                announcement.accessibilitySpeechAnnouncementPriority = .high
                UIAccessibility.post(notification: .announcement, argument: announcement)
            } else {
                voice.speak(reason)
            }
        }
    }

    private func describe(turn: UUID) async {
        // `scheduleNext` awaits the previous task before starting this one,
        // so turns are strictly serial and this should never be true.
        guard !isDescribing else {
            if isContinuous {
                scheduleNext(after: 1.0)
            } else {
                voice.speak(L10n.text("Still working on the last one."))
            }
            return
        }

        guard let frame = camera.snapshot() else {
            warmUpAttempts += 1
            if warmUpAttempts >= 10 {
                stopLoop(reason: L10n.text("The camera isn't sending any pictures. Close this screen and open it again."))
            } else if isContinuous {
                scheduleNext(after: 1.0)
            } else {
                voice.speak(L10n.text("Nothing to describe yet."))
            }
            return
        }
        warmUpAttempts = 0

        isDescribing = true
        // Unconditional: turns are serialized, and any `currentTurn` check
        // here would leave the flag stuck true on every path that schedules
        // the next turn itself - which silently kills the loop.
        defer { isDescribing = false }
        notice = nil

        if mode == .text {
            let languages = TextRecognizer.languages(for: appState.settings.appLanguage)
            let read = await TextRecognizer.text(in: frame, languages: languages)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Task.isCancelled, currentTurn == turn else { return }
            latest = read.isEmpty ? L10n.text("No text in view.") : read
            speakOrContinue(latest)
            return
        }

        // Speak a true, coarse answer immediately rather than leaving the
        // user in silence while the model thinks. Only on the first turn of
        // a burst, so continuous mode doesn't become chatty.
        //
        // Deliberately NOT gated on VoiceOver: this is the app's own voice,
        // and blind users are exactly who the latency fix is for.
        if !spokeQuickImpression,
           let impression = await TextRecognizer.quickImpression(of: frame) {
            guard !Task.isCancelled, currentTurn == turn else { return }
            spokeQuickImpression = true
            voice.speak(L10n.text("Looks like \(impression)."))
        }

        let engine = appState.engine
        guard engine.claimUtility() else {
            // Something else owns the model; try again shortly, but don't
            // poll forever in silence.
            busyAttempts += 1
            if busyAttempts >= 10 {
                stopLoop(reason: L10n.text("The AI is busy with another task. Try again in a moment."))
            } else if isContinuous {
                scheduleNext(after: 1.5)
            } else {
                // A deliberate tap must never be answered with silence: the
                // user has no way to tell it from a dead app.
                voice.speak(L10n.text("The AI is busy with another task. Try again in a moment."))
            }
            return
        }
        busyAttempts = 0
        defer { engine.releaseUtility() }

        do {
            let model = try engine.route(hasImage: true, requiresDownloaded: true)
            try await engine.startCleanSession(model: model)
            try Task.checkCancellation()

            var final = ""
            for try await snapshot in engine.respondStream(model: model, prompt: prompt(for: mode), image: frame) {
                if Task.isCancelled { break }
                final = snapshot
                if currentTurn == turn { latest = snapshot }
            }
            guard !Task.isCancelled, currentTurn == turn else { return }

            let cleaned = final.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                // Nothing to say this time - keep the loop alive.
                if isContinuous {
                    scheduleNext(after: 1.0)
                } else {
                    voice.speak(L10n.text("I couldn't make out this scene. Try again."))
                }
                return
            }
            latest = cleaned
            speakOrContinue(cleaned)
        } catch let error as ChatEngine.RouteError {
            stopLoop(reason: routeNotice(for: error))
        } catch is CancellationError {
            // Superseded deliberately.
        } catch {
            guard !Task.isCancelled else { return }
            stopLoop(reason: error.localizedDescription)
        }
    }

    /// The loop is driven by `onFinishedSpeaking`, so a turn that produced no
    /// speakable text has to schedule the next one itself.
    ///
    /// In continuous mode, near-identical descriptions are skipped: hearing
    /// "a kitchen counter with a mug" every two seconds while you stand still
    /// is the fastest way to make someone turn the feature off.
    private func speakOrContinue(_ text: String) {
        if isContinuous, Self.isSubstantiallySame(text, as: lastSpoken) {
            suppressedInARow += 1
            // Backed off, and after a while acknowledged out loud. Standing
            // still used to mean full-rate vision inference producing total
            // silence - which from the user's side is indistinguishable from
            // a crash, while the phone quietly gets hot.
            if suppressedInARow == 6 {
                voice.speak(L10n.text("Still the same view."))
                return
            }
            let backoff = min(pauseBetween * Double(suppressedInARow), 10)
            scheduleNext(after: backoff)
            return
        }
        suppressedInARow = 0
        lastSpoken = text
        if !voice.speak(text), isContinuous {
            scheduleNext(after: 0.8)
        }
    }

    /// Two descriptions of the same unchanged scene, allowing for the model
    /// rewording itself. Compared on words, not characters.
    static func isSubstantiallySame(_ text: String, as previous: String) -> Bool {
        guard !previous.isEmpty else { return false }
        let new = contentTokens(of: text)
        let old = contentTokens(of: previous)
        guard !new.isEmpty, !old.isEmpty else { return false }
        let shared = new.intersection(old).count
        // Divided by the larger set, never the smaller one: a short first
        // impression is a subset of the fuller description that follows it,
        // and dividing by the smaller set would silence exactly the answer
        // the user was waiting for.
        return Double(shared) / Double(max(new.count, old.count)) > 0.75
    }

    /// The words worth comparing in two descriptions.
    ///
    /// Tokenized rather than split on spaces, because Chinese and Japanese
    /// sentences have no spaces at all: a naive split makes a whole
    /// description a single token, and suppression never fires in those
    /// languages.
    ///
    /// Very short alphabetic words are then dropped. A model rewording the
    /// same unchanged scene shuffles precisely those - "with a" becomes
    /// "on a", "sitting" appears - and counting them as differences pushed
    /// identical scenes below the threshold, so the phone repeated itself.
    /// Characters from CJK and Hangul are kept at any length, because there
    /// one character is already a whole word.
    private static func contentTokens(of text: String) -> Set<String> {
        DocumentIndex.tokens(of: text).filter { token in
            if token.count >= 3 { return true }
            guard let scalar = token.unicodeScalars.first else { return false }
            return scalar.value >= 0x2E80
        }
    }

    private func prompt(for mode: Mode) -> String {
        switch mode {
        case .brief:
            // ONE sentence. Research on blind and low-vision users is
            // consistent that verbosity is the top complaint: descriptions
            // that anticipate the likely question beat comprehensive ones.
            // Detail is a deliberate second step, not the default.
            return """
            In ONE short sentence, tell someone who cannot see what is directly in front \
            of them right now. Lead with the single most useful fact - the main object or \
            person, or anything in the way. No preamble, no list, no mention of the photo, \
            the image quality or the camera. One sentence only.
            """
        case .detailed:
            return """
            Describe what is in front of the camera in three to five short sentences, \
            for someone who cannot see it. Cover the setting, the people and what they \
            appear to be doing, the main objects and their positions, and any obstacles \
            or hazards. Read out any short signs or labels exactly. Do not mention the \
            photo, the image quality or the camera.
            """
        case .text:
            return ""
        }
    }

    private func routeNotice(for error: ChatEngine.RouteError) -> String {
        switch error {
        case .needsDownloadConsent(let model), .visionNeedsDownloadedModel(let model):
            return L10n.text("Describing surroundings needs the \(model.name) vision model. Download it from the chat screen first.")
        case .nothingAvailable(let reason):
            return reason
        }
    }
}
