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
// For `AVCaptureDevice.Position` (front/back) under member-import visibility.
import AVFoundation

struct SceneDescriptionView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var camera = CameraController()
    @StateObject private var voice = VoiceService()
    /// Neither the camera nor the voice may come back behind the Face ID
    /// lock screen. The lock engages on `.background`, which stops both,
    /// but `.active` used to restart them whether or not the user had
    /// unlocked - so a cancelled biometric prompt left the room being
    /// described aloud from behind a "locked" app.
    @ObservedObject private var lock = AppLock.shared

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

    /// Remembered: someone who reads labels with "Read text" every day had
    /// to pick it again on every visit.
    @AppStorage("describe.mode") private var mode: Mode = .brief
    /// The user's last choice of "Keep describing", read once per visit.
    /// Kept apart from the stored preference on purpose: the loop also
    /// switches itself off on errors (`stopLoop`), and that must not become
    /// the user's choice for next time.
    // Off until the user turns it on (and then remembered). On by default,
    // the screen started describing by itself the moment it opened and
    // went on and on; a tester could hardly reach the controls before the
    // next description started.
    @State private var isContinuous = UserDefaults.standard.object(forKey: "describe.continuous") as? Bool ?? false
    @AppStorage("describe.continuous") private var prefersContinuous = false
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
    /// Whether the voice that will speak is an English one. The quick
    /// "Looks like..." answer is built from Vision's classifier labels,
    /// which exist only in English; in any other voice they are noise.
    @State private var speaksEnglish = false
    /// Whether "Loading the vision model" has been said on this visit.
    @State private var announcedModelLoad = false

    /// Quiet gap between one description finishing and the next starting.
    private let pauseBetween: TimeInterval = 1.5

    /// True when this screen is doing the talking, so VoiceOver shouldn't
    /// also read the same text.
    ///
    /// Deliberately not `isContinuous`: that hid the description for the
    /// whole session, so a low-vision VoiceOver user - or anyone on a Braille
    /// display, which hears nothing at all - could never read it.
    private var isSpeakingAloud: Bool { voice.isSpeaking }

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        NavigationStack {
            stage
                // Dark throughout, like the navigation bar. The materials
                // and labels otherwise followed the device's light scheme:
                // white text on a light grey pill over a bright scene, well
                // under 3:1 - on the screen built for low-vision users.
                .environment(\.colorScheme, .dark)
                .background(Color.black.ignoresSafeArea())
            .navigationTitle("Describe Surroundings")
            .navigationSubtitle("Spoken aloud · 100% on-device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        dismiss()
                    }
                    .accessibilityLabel(Text("Close describe surroundings"))
                }
                ToolbarItem(placement: .primaryAction) {
                    // "Is my collar straight, what colour is my shirt": the
                    // camera facing the user is half of what people ask a
                    // describer. By direction, as in PhotoCaptureView - on
                    // iPhone Duo "front" depends on the display in use.
                    Button("Flip Camera", systemImage: "arrow.triangle.2.circlepath.camera") {
                        camera.setPosition(camera.position == .back ? .front : .back)
                    }
                    .disabled(!camera.isReady || camera.isSwitchingCamera)
                }
            }
        }
        // The system toolbar item is a smaller target than the old 56 pt
        // X; the two-finger scrub gesture still closes the screen for
        // anyone who finds it by feel.
        .accessibilityAction(.escape) { dismiss() }
        // Two-finger double tap: "Describe now" from anywhere, the way it
        // plays and pauses in Music, without finding the button first.
        .accessibilityAction(.magicTap) { describeNow() }
        .onAppear(perform: start)
        .onDisappear {
            isActive = false
            describeTask?.cancel()
            camera.stop()
            voice.shutdown()
            ScreenAwake.set(.sceneDescription, false)
        }
        .onChange(of: camera.failed) { _, failed in
            guard failed else { return }
            stopLoop(reason: L10n.text("The camera isn't available. Check camera permission in the Settings app."))
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                guard !lock.isLocked else { return }
                resumeAfterPause()
            case .inactive:
                // Control Center, a call banner, Siri, a system alert. The
                // screen is still up and the user may be reaching for the
                // volume to hear the description better; this used to
                // cancel the turn, stop the camera and restart the loop
                // from scratch. The camera keeps going; if another app
                // takes the audio, `onSpeechInterrupted` re-arms the loop.
                break
            case .background:
                describeTask?.cancel()
                camera.stop()
                voice.pause()
                isDescribing = false
                ScreenAwake.set(.sceneDescription, false)
            @unknown default:
                break
            }
        }
        .onChange(of: lock.isLocked) { _, locked in
            // Unlocked after the `.active` turn that was skipped above.
            guard !locked, scenePhase != .background else { return }
            resumeAfterPause()
        }
        .onChange(of: camera.interruption) { _, reason in
            // Another app holds the camera, or two apps share the screen
            // (Split View, the inner display of iPhone Duo). The frames stop,
            // so the warm-up counter ran out after ten seconds and announced
            // "the camera isn't sending any pictures, close this screen" -
            // the wrong diagnosis, to someone who cannot see the viewfinder
            // go dark, and the loop never came back when the other app let
            // go. Now: say what is happening, park, and resume by itself.
            if let reason {
                describeTask?.cancel()
                isDescribing = false
                warmUpAttempts = 0
                notice = reason
                voice.stopSpeaking()
                announce(reason)
            } else {
                notice = nil
                // The session resumes by itself once the other app lets go;
                // give it a moment to deliver a frame.
                if isContinuous { scheduleNext(after: 0.6) }
            }
        }
        .onChange(of: camera.position) { _, position in
            // Only once the switch has really happened. Whatever was being
            // described is now behind the user, so it is dropped, the user
            // is told which way the camera faces, and the repeat suppressor
            // is reset so the next description is always spoken.
            describeTask?.cancel()
            voice.stopSpeaking()
            spokeQuickImpression = false
            lastSpoken = ""
            suppressedInARow = 0
            announce(position == .front ? L10n.text("Front camera") : L10n.text("Back camera"))
            if isContinuous { scheduleNext(after: 1.0) }
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
            ScreenAwake.set(.sceneDescription, on)
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

    /// The viewfinder with the description and controls over it - or, on
    /// an iPhone Duo folded half open, the viewfinder in one half and the
    /// controls in the other, clear of the hinge.
    @ViewBuilder
    private var stage: some View {
        if #available(iOS 27.1, *) {
            ArrangementView {
                layout
            } secondary: {
                viewfinder
            }
            .arrangementViewStyle(.overlay)
        } else {
            ZStack {
                viewfinder
                layout
            }
        }
    }

    @ViewBuilder
    private var viewfinder: some View {
        if !camera.failed {
            ZStack {
                CameraPreview(camera: camera)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                // Dim the viewfinder: this screen is meant to be listened to,
                // and a dimmer preview saves battery on a long walk.
                Color.black.opacity(0.35).ignoresSafeArea()
            }
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    /// Upright: the description above the controls. Short and wide (a
    /// landscape phone, an iPhone Duo on its side): description beside the
    /// controls, which scroll if they must. Stacked, the controls alone
    /// took most of a landscape phone's height and the toggle fell off the
    /// bottom of the screen.
    @ViewBuilder
    private var layout: some View {
        if verticalSizeClass == .compact {
            HStack(alignment: .bottom, spacing: 0) {
                VStack {
                    Spacer(minLength: 0)
                    transcriptPanel
                }
                .frame(maxWidth: .infinity)

                ScrollView {
                    controls
                }
                .frame(width: 300)
            }
        } else {
            VStack(spacing: 14) {
                Spacer(minLength: 0)
                transcriptPanel
                controls
            }
        }
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
            .frame(maxHeight: verticalSizeClass == .compact ? .infinity : 260)
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
                .frame(maxWidth: .infinity, minHeight: verticalSizeClass == .compact ? 52 : 68)
                .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .accessibilityHint(Text("Describes what the camera is pointed at right now"))

            // There was no way to hear a description again once it had been
            // spoken - and missing one while a bus goes past is normal.
            if !latest.isEmpty {
                Button {
                    voice.stopSpeaking()
                    voice.speak(TextRecognizer.speakable(latest))
                } label: {
                    Label("Repeat that", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .accessibilityHint(Text("Says the last description again"))
            }

            Toggle(isOn: Binding(
                get: { isContinuous },
                set: { on in
                    isContinuous = on
                    prefersContinuous = on
                }
            )) {
                Text("Keep describing")
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
        voice.setSpeechLanguage(appState.settings.appLanguage)
        voice.speechRate = Float(appState.settings.speechRate)
        // Judged on the voice that will actually speak, not the UI language:
        // a Greek UI with no Greek voice installed speaks English anyway.
        speaksEnglish = VoiceService.speechCode(for: appState.settings.appLanguage)
            .lowercased().hasPrefix("en")
        voice.onFinishedSpeaking = {
            Task { @MainActor in
                guard isActive, isContinuous else { return }
                // `!isDescribing` matters: the fast "Looks like..." answer
                // finishes speaking about a second in, while the model is
                // still generating the real description. Without this guard
                // that utterance scheduled the next turn, which cancelled the
                // generation the user was actually waiting for.
                guard !isDescribing else { return }
                // Parked while another app has the camera; the interruption
                // observer resumes the loop when it lets go.
                guard camera.interruption == nil else { return }
                scheduleNext(after: pauseBetween)
            }
        }
        // The loop is driven by `onFinishedSpeaking`, and the synthesizer
        // never reports an utterance it was stopped from finishing. When
        // another app took the audio session - a Maps turn prompt, Siri, a
        // call, an alarm - the sentence was cut off, nothing scheduled the
        // next turn, and the screen fell silent with "Keep describing" still
        // on. Maps is the worst case: it interrupts exactly `.spokenAudio`
        // sessions and the scene phase never changes, so nothing else could
        // rescue it - for the blind user walking with directions on, the
        // headline use of this screen.
        voice.onSpeechInterrupted = {
            Task { @MainActor in
                guard isActive, isContinuous, !isDescribing, camera.interruption == nil else { return }
                // After the other app's audio has had a moment; if it is
                // still playing when the next turn speaks, the watchdog in
                // VoiceService keeps the loop alive regardless.
                scheduleNext(after: pauseBetween)
            }
        }
        // Opened under the Face ID lock screen (a deep link while locked):
        // nothing starts until the lock observer sees it clear.
        guard !lock.isLocked else { return }
        camera.start()
        if isContinuous {
            ScreenAwake.set(.sceneDescription, true)
            scheduleNext(after: 1.2)
        }
    }

    /// Back from the background, Control Center, or the lock screen: bring
    /// the camera back and, if the loop is idle, the loop. A turn still
    /// generating or speaking is left to finish; it schedules the next one
    /// itself, and cancelling it here was the "restarts from scratch" the
    /// user saw on every Control Center swipe.
    private func resumeAfterPause() {
        camera.resume()
        guard isContinuous else { return }
        ScreenAwake.set(.sceneDescription, true)
        guard !isDescribing, !voice.isSpeaking else { return }
        scheduleNext(after: 0.6)
    }

    private func describeNow() {
        // A deliberate tap must never be answered with silence. While another
        // app has the camera there is nothing to look at, so say that again
        // rather than counting a warm-up failure.
        if let reason = camera.interruption {
            voice.stopSpeaking()
            announce(reason)
            return
        }
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
        ScreenAwake.set(.sceneDescription, false)
        notice = reason
        // Speak after the toggle change has settled, so the state change
        // doesn't stop the very announcement explaining it.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard isActive else { return }
            announce(reason)
        }
    }

    /// Say something about the screen's own state out loud. With VoiceOver
    /// on, let VoiceOver say it - doing both means the user hears the same
    /// sentence twice, overlapping.
    private func announce(_ text: String) {
        if UIAccessibility.isVoiceOverRunning {
            // High priority, or iOS drops it: flipping the toggle in
            // `stopLoop` makes VoiceOver announce "Keep describing, off", and
            // a default-priority announcement arriving while VoiceOver is
            // still speaking is discarded - leaving the user with a screen
            // that stopped for no stated reason.
            var announcement = AttributedString(text)
            announcement.accessibilitySpeechAnnouncementPriority = .high
            UIAccessibility.post(notification: .announcement, argument: announcement)
        } else {
            voice.speak(text)
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
            // Paused, not broken: another app has the camera. The
            // interruption observer has said so and will resume the loop;
            // counting this as a warm-up failure blamed the camera instead.
            if camera.interruption != nil { return }
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

        // A covered lens or a pitch-dark room: say so, rather than let the
        // model describe a person who is not there (it did, with the lens
        // taped over). Repeats are quietened like any unchanged view.
        if mode != .text, FrameCheck.showsNothing(frame) {
            latest = L10n.text("It's too dark to see anything. The camera may be covered.")
            speakOrContinue(latest)
            return
        }

        isDescribing = true
        // Unconditional: turns are serialized, and any `currentTurn` check
        // here would leave the flag stuck true on every path that schedules
        // the next turn itself - which silently kills the loop.
        defer { isDescribing = false }
        notice = nil

        if mode == .text {
            // Read from a still, not the live frame. The frames are scaled
            // to 768 px for the vision encoder, which puts a line of body
            // text on a letter or menu at eight to eleven pixels tall -
            // fragments or "No text in view" from pages the Scan Document
            // path reads perfectly. The still is asked for at OCR size; the
            // live frame remains the fallback if the shutter cannot fire.
            let page = await camera.capturePhoto(maxEdge: TextRecognizer.maximumPixels) ?? frame
            guard !Task.isCancelled, currentTurn == turn else { return }
            let languages = TextRecognizer.languages(for: appState.settings.appLanguage)
            let read = await TextRecognizer.text(in: page, languages: languages)
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
        //
        // Gated on the voice being English: the labels are Vision's English
        // taxonomy ("kitchen, indoor") and cannot be localized, so in any
        // other voice the fast answer was "Похоже на kitchen, indoor" - noise
        // for most of the app's audience. Those users go straight to the
        // model's description in their language.
        if !spokeQuickImpression, speaksEnglish,
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
            // The first description after opening can wait up to half a
            // minute on loading the vision model, and silence that long is
            // indistinguishable from a dead app to someone who cannot see
            // the screen. Said once per visit, before the wait starts.
            if !announcedModelLoad, model.backend != .appleIntelligence,
               !engine.hasSession(for: model), engine.mlx.loadedModelId != model.id {
                announcedModelLoad = true
                voice.speak(L10n.text("Loading the vision model, one moment."))
            }
            try await engine.startCleanSession(model: model, instructions: Self.instructions)
            try Task.checkCancellation()

            // In the language the screen speaks. The prompt is the app's
            // own English, so "the language the user writes in" was English
            // on a German phone.
            let language = TurnContext.uiLanguage(appState.settings.appLanguage)
            let asked = prompt(for: mode) + " Answer in \(language.englishName)."
            var final = ""
            for try await snapshot in engine.respondStream(model: model, prompt: asked, image: frame) {
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
        // `speakable`: a menu or invoice recognized as a table arrives as
        // Markdown, and the separator row under its header was read as
        // "dash dash dash dash..." once per column before the first item.
        // The transcript on screen keeps the table.
        if !voice.speak(TextRecognizer.speakable(text)), isContinuous {
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

    /// The system prompt for describing: only what is clearly visible.
    static let instructions = """
    You describe what a phone camera sees for someone who cannot see it. Describe only what is \
    clearly visible. If the picture is dark, blurred or shows nothing you can recognize, say so \
    instead of guessing. Never invent people, objects or text.
    """

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
