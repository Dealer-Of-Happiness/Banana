//
//  VoiceModeView.swift
//  AIGoodbye
//
//  Hands-free voice conversation, fully offline: speak, the AI answers out
//  loud, and listening resumes automatically. Turns are saved into the
//  current chat like typed messages.
//
//  The conversation runs as an explicit turn state machine so the
//  microphone is never live while the app is speaking (which would make it
//  transcribe its own voice and loop forever).
//

import SwiftUI
import UIKit

struct VoiceModeView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var voice = VoiceService()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private enum Turn: Equatable {
        case starting
        case listening
        case thinking
        case speaking
        case idle          // waiting for the user to tap "Tap to talk"
        case blocked(String)
    }

    @State private var turn: Turn = .starting
    @State private var permissionDenied = false
    @State private var spokenOffset = 0
    @State private var lastStreamed = ""
    @State private var isActive = true
    /// False while the scene is not `.active`. Nothing is spoken and no
    /// listen is started while it is false: a streamed token used to undo
    /// `pause()` within milliseconds, and the phone then read the answer out
    /// from the lock screen and opened the microphone with no screen.
    @State private var inForeground = true
    /// Speaks the model-loading notice if a turn sits in `.thinking` while a
    /// model loads. Cancelled whenever the turn moves on.
    @State private var loadingCueTask: Task<Void, Never>?
    #if DEBUG
    /// Store-screenshot stand-in for a spoken question (AIG_DEMO_VOICE=1):
    /// the Simulator has no microphone, so a real turn can't be staged.
    @State private var demoTranscript = ""
    #endif
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(.systemBackground), Color.blue.opacity(0.12)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                layout
            }
            .navigationTitle("Voice Conversation")
            .navigationSubtitle("100% on your device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                // A real toolbar item, not a drawn X: on iPhone Duo the
                // system moves it into the vertical bar beside the display
                // and keeps it where every other app's Close lives.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        dismiss()
                    }
                    .accessibilityLabel(Text("Close voice mode"))
                }
            }
        }
        // VoiceOver's two-finger double tap: the screen's primary action
        // from anywhere, without hunting for the circle - interrupt, talk,
        // or send what was said, depending on the turn.
        .accessibilityAction(.magicTap) {
            if case .blocked = turn {
                beginListening()
            } else {
                indicatorTapped()
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: teardown)
        .onChange(of: scenePhase) { _, phase in
            inForeground = (phase == .active)
            switch phase {
            case .background:
                // Backgrounding doesn't fire onDisappear: never leave the mic
                // hot. `pause` keeps the callbacks so the screen still works
                // on return; the user taps to resume.
                voice.pause()
                if isActive { turn = .idle }
                ScreenAwake.set(.voiceMode, false)
            case .inactive:
                // Control Center, the app switcher, a system alert - including
                // the one-time Speech Recognition prompt a first listen in
                // some languages shows. The screen is still there, so a
                // listen in flight survives (tearing it down here made the
                // user grant permission and land on "Tap to talk"). Only the
                // speaker is silenced; the answer is in the chat.
                if voice.isSpeaking {
                    voice.stopSpeaking()
                    if isActive, turn == .speaking { turn = .idle }
                }
            default:
                break
            }
        }
        .onChange(of: voice.listeningState) { _, state in
            listeningStateChanged(state)
        }
        .onChange(of: turn) { _, newTurn in
            turnChanged(to: newTurn)
        }
        // Something to feel when your turn starts and when you were heard,
        // behind the existing Haptic Feedback setting, which until now did
        // nothing on this screen.
        .sensoryFeedback(trigger: turn) { _, newTurn in
            guard isActive, appState.settings.hapticFeedbackEnabled else { return nil }
            switch newTurn {
            case .listening: return .start
            case .thinking: return .success
            case .blocked: return .error
            default: return nil
            }
        }
        .onChange(of: viewModel.streamingText) { _, text in
            // Only an answer to THIS screen's current turn is spoken. After a
            // barge-in the turn is `.listening` and a late snapshot must not
            // speak over the user; after a pause it is `.idle`.
            guard isActive, let text, !text.isEmpty,
                  turn == .thinking || turn == .speaking else { return }
            lastStreamed = text
            guard inForeground else { return }
            turn = .speaking
            speakNewSentences(in: text)
        }
        .onChange(of: viewModel.isGenerating) { _, generating in
            if generating {
                turn = .thinking
            } else {
                finishAssistantTurn()
            }
        }
        .onChange(of: viewModel.errorBanner) { _, banner in
            // Say it here rather than dismissing to a banner the user has to
            // go and find - unless the user has already barged in and is
            // talking: the cancelled turn's "no answer" must not cover a
            // live microphone.
            if let banner, turn != .listening { turn = .blocked(banner.message) }
        }
        // Presented HERE, not by dismissing to the chat screen. Dismissing a
        // cover and presenting a sheet in the same transaction means UIKit
        // drops the sheet, so a new user without a model spoke and voice mode
        // simply closed with no explanation.
        .sheet(item: $viewModel.consentRequest, onDismiss: {
            viewModel.consentSheetDismissed()
            if isActive, case .thinking = turn { turn = .idle }
        }) { request in
            ModelDownloadConsentSheet(
                model: request.model,
                reason: request.reason,
                onApprove: { viewModel.approveConsentAndResend() },
                onCancel: { viewModel.declineConsent() }
            )
            // As in the chat: with larger text or on a landscape phone the
            // medium detent hid the end of the copy under the buttons.
            .presentationDetents(dynamicTypeSize > .large || verticalSizeClass == .compact ? [.large] : [.medium, .large])
        }
    }

    // MARK: - Pieces

    /// Two arrangements of the same parts. Upright: the indicator above the
    /// transcript, as on any phone. Short and wide (a landscape phone, an
    /// iPhone Duo on its side): the indicator beside the transcript, because
    /// stacking a 190 pt circle, the status, the transcript and the button
    /// needs more height than a landscape phone has, and the old layout
    /// pushed Tap to talk off the bottom of the screen.
    @ViewBuilder
    private var layout: some View {
        if #available(iOS 27.1, *) {
            // An arrangement view: side by side when the window is wider
            // than tall, stacked when taller than wide, and on iPhone Duo
            // it keeps both halves clear of the hinge when the phone is
            // half open - the indicator on one side of the fold, the
            // transcript and the button on the other.
            ArrangementView {
                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    statusIndicator
                    statusText
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } secondary: {
                VStack(spacing: 12) {
                    transcriptArea
                    controls
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
            .arrangementViewStyle(.split)
        } else if verticalSizeClass == .compact {
            HStack(spacing: 20) {
                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    statusIndicator
                    statusText
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 12) {
                    transcriptArea
                    controls
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
        } else {
            VStack(spacing: 24) {
                Spacer()
                statusIndicator
                statusText
                Spacer()
                transcriptArea
                controls
            }
            .padding()
        }
    }

    /// The indicator shrinks with the window; a fixed 190 pt circle is a
    /// third of a landscape phone's height.
    private var indicatorSize: CGFloat {
        verticalSizeClass == .compact ? 120 : 190
    }

    private var statusIndicator: some View {
        ZStack {
            Circle()
                .fill(indicatorColor.opacity(0.15))
                .frame(width: indicatorSize, height: indicatorSize)
                // Reduce Motion: a 190 pt circle pulsing ten times a second
                // is exactly the effect that setting exists to switch off.
                .scaleEffect(reduceMotion ? 1 : 1 + voice.micLevel * 0.5)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: voice.micLevel)

            Circle()
                .fill(indicatorColor.opacity(0.25))
                .frame(width: indicatorSize * 0.74, height: indicatorSize * 0.74)

            Image(systemName: indicatorSymbol)
                .font(.system(size: indicatorSize * 0.27, weight: .medium))
                .foregroundStyle(indicatorColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .contentShape(Circle())
        .onTapGesture {
            indicatorTapped()
        }
        // The screen's main control, and the one place VoiceOver can learn
        // the state: it is a button, its value is the status line (which
        // VoiceOver was never told to re-read), and that value changes.
        .accessibilityElement()
        .accessibilityLabel(Text("Voice status"))
        .accessibilityValue(Text(verbatim: statusDescription))
        .accessibilityHint(turn == .listening
                           ? Text("Double tap to send now")
                           : Text("Double tap to interrupt and speak"))
        .accessibilityAddTraits([.isButton, .updatesFrequently])
        .accessibilityAction { indicatorTapped() }
    }

    /// `statusText` as one string, for VoiceOver.
    private var statusDescription: String {
        if permissionDenied {
            return L10n.text("AiGoodbye needs microphone access for voice conversations. You can enable it in the Settings app.")
        }
        switch turn {
        case .blocked(let reason):
            return reason
        case .speaking:
            return L10n.text("Speaking · tap the circle to interrupt")
        case .thinking:
            return appState.engine.mlx.isPreparingModel ? modelLoadingMessage : L10n.text("Thinking...")
        case .listening where voice.listeningState == .preparing:
            return voice.preparingProgress > 0
                ? L10n.text("Downloading the speech model for this language...")
                : L10n.text("Getting ready to listen...")
        case .listening:
            return L10n.text("Listening · pause to send")
        case .starting, .idle:
            return L10n.text("Tap to talk")
        }
    }

    private var indicatorColor: Color {
        switch turn {
        case .speaking: return .green
        case .thinking: return .purple
        case .listening: return .blue
        default: return .gray
        }
    }

    private var indicatorSymbol: String {
        switch turn {
        case .speaking: return "speaker.wave.2.fill"
        case .thinking: return "brain"
        case .listening: return "mic.fill"
        default: return "mic.slash.fill"
        }
    }

    @ViewBuilder
    private var statusText: some View {
        Group {
            if permissionDenied {
                Text("AiGoodbye needs microphone access for voice conversations. You can enable it in the Settings app.")
            } else if case .blocked(let reason) = turn {
                Text(reason)
            } else {
                switch turn {
                case .speaking:
                    Text("Speaking · tap the circle to interrupt")
                case .thinking where appState.engine.mlx.isPreparingModel:
                    // A first answer from a downloaded model can take ten to
                    // thirty seconds of loading; "Thinking..." for all of it
                    // invited a second tap, which cancels the load.
                    VStack(spacing: 6) {
                        Text(modelLoadingMessage)
                        ProgressView()
                    }
                case .thinking:
                    Text("Thinking...")
                case .listening where voice.listeningState == .preparing:
                    if voice.preparingProgress > 0 {
                        VStack(spacing: 6) {
                            Text("Downloading the speech model for this language...")
                            ProgressView(value: voice.preparingProgress)
                                .frame(maxWidth: 220)
                        }
                    } else {
                        Text("Getting ready to listen...")
                    }
                case .listening:
                    Text("Listening · pause to send")
                default:
                    Text("Tap to talk")
                }
            }
        }
        .font(.subheadline)
        // Primary: secondary gray on the voice screen's light gradient
        // measured below 4.5:1, and this line is the screen's state.
        .foregroundStyle(.primary)
        .multilineTextAlignment(.center)
        // Claims its full height at the width it is given. Inside an
        // arrangement view the parts are measured first and the status
        // was being measured as one line, then truncated to "…" once it
        // had to wrap.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal)
    }

    private var modelLoadingMessage: String {
        let name = appState.engine.mlx.loadingModelName ?? appState.engine.selectedModel.name
        return L10n.text("Loading \(name) - the first answer takes a moment")
    }

    private var shownTranscript: String {
        #if DEBUG
        if !demoTranscript.isEmpty { return demoTranscript }
        #endif
        return voice.liveTranscript
    }

    private var transcriptArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !shownTranscript.isEmpty {
                    Text(shownTranscript)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.blue)
                }
                if !lastStreamed.isEmpty {
                    Text(lastStreamed)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxHeight: verticalSizeClass == .compact ? .infinity : 220)
        .defaultScrollAnchor(.bottom)
    }

    private var controls: some View {
        Button {
            bargeIn()
        } label: {
            Label("Tap to talk", systemImage: "mic.badge.plus")
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
        }
        // Darker than the default blue in light mode: plain systemBlue on
        // the screen's pale gradient measured below 4.5:1.
        .tint(Color.tintedBlue)
        .disabled(turn == .listening || permissionDenied)
        .padding(.bottom, 8)
    }

    // MARK: - Flow

    private func start() {
        voice.playsListeningSounds = appState.settings.listeningSounds
        voice.speechRate = Float(appState.settings.speechRate)
        voice.onFinalTranscript = { text in
            Task { @MainActor in
                guard isActive else { return }
                spokenOffset = 0
                lastStreamed = ""
                turn = .thinking
                await viewModel.sendVoicePrompt(text)
            }
        }
        voice.onFinishedSpeaking = {
            Task { @MainActor in
                guard isActive, inForeground, !viewModel.isGenerating else { return }
                if turn == .speaking {
                    beginListening()
                } else if turn == .thinking {
                    // Only the model-loading notice was playing, and the turn
                    // ended without an answer to speak (`finishAssistantTurn`
                    // leaves `.thinking` alone while something is speaking).
                    turn = .idle
                }
            }
        }
        voice.onListeningEnded = {
            Task { @MainActor in
                guard isActive, turn == .listening else { return }
                turn = .idle
            }
        }
        voice.onSpeechInterrupted = {
            Task { @MainActor in
                // A phone call or Siri cut the answer off. Nothing will finish
                // playing, so the turn is handed back; the user taps to go on.
                guard isActive, turn == .speaking else { return }
                turn = .idle
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["AIG_DEMO_VOICE"] == "1" {
            // A finished turn, frozen for a screenshot. No microphone.
            demoTranscript = "What can I cook tonight with eggs, spinach and feta?"
            lastStreamed = "A spinach and feta frittata. Sauté the spinach with a little garlic, pour over six beaten eggs, crumble the feta on top and bake at 200 degrees for about fifteen minutes. Serve with crusty bread. Want a side salad to go with it?"
            turn = .speaking
            return
        }
        #endif
        Task {
            let granted = await VoiceService.requestPermissions()
            if granted {
                beginListening()
            } else {
                permissionDenied = true
                turn = .idle
            }
        }
    }

    private func teardown() {
        isActive = false
        loadingCueTask?.cancel()
        loadingCueTask = nil
        voice.shutdown()   // also clears the callbacks (no retain cycle)
        ScreenAwake.set(.voiceMode, false)
    }

    /// Side effects of a turn change that belong to the turn itself rather
    /// than to whichever path caused it.
    private func turnChanged(to newTurn: Turn) {
        // Awake only while the conversation is actually doing something. A
        // hands-free conversation has nobody touching the screen, so the
        // default 30-second auto-lock used to cut an answer off mid-sentence
        // (backgrounding stops all audio) and the microphone never reopened.
        // Idle and blocked let the phone lock as usual.
        let working = newTurn == .listening || newTurn == .thinking || newTurn == .speaking
        ScreenAwake.set(.voiceMode, isActive && working)

        loadingCueTask?.cancel()
        loadingCueTask = nil
        guard isActive else { return }
        if newTurn == .thinking { scheduleLoadingCue() }
        // VoiceOver users were told nothing when the microphone opened.
        // "Listening" is posted as the listen is requested, while the
        // microphone is still being readied, so VoiceOver's own voice is not
        // what the recognizer hears first; the begin tone marks the moment
        // it is actually live.
        switch newTurn {
        case .listening: announceForVoiceOver(L10n.text("Listening"))
        case .thinking: announceForVoiceOver(L10n.text("Thinking..."))
        default: break
        }
    }

    /// Say out loud that a model is loading, once, if thinking has lasted
    /// three seconds and a load is the reason. Eyes-off there is otherwise
    /// nothing at all for up to half a minute, and the natural reaction -
    /// tapping or talking again - cancels the load and starts it over.
    private func scheduleLoadingCue() {
        loadingCueTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, isActive, inForeground, turn == .thinking,
                  appState.engine.mlx.isPreparingModel, !voice.isSpeaking else { return }
            voice.speak(modelLoadingMessage)
        }
    }

    /// The app's own voice stays out of this: with VoiceOver off, the status
    /// text, the tones and the haptics carry the same information.
    private func announceForVoiceOver(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// The circle is the screen's one big control.
    private func indicatorTapped() {
        if turn == .speaking || turn == .thinking || voice.isSpeaking {
            // Barge-in: interrupt the answer (including any generation still
            // streaming, which would otherwise speak over the user) and talk.
            bargeIn()
        } else if turn == .listening {
            // Tap to send: don't wait for the pause. This used to do nothing,
            // and "Tap to talk" is disabled while listening, so there was no
            // way to say "that's all" except to stop talking and wait.
            voice.finishListeningNow()
        } else if turn == .idle {
            beginListening()
        }
    }

    private func beginListening() {
        guard isActive, inForeground, !permissionDenied else { return }
        // Asynchronous: the engine may need a moment (or, once per
        // language, a model download). The outcome arrives through
        // `voice.listeningState`, handled in `listeningStateChanged`.
        voice.startListening(language: appState.settings.appLanguage)
        turn = .listening
    }

    /// The user interrupts the answer to talk. The generation is cancelled
    /// and the spoken-text bookkeeping reset, so when `isGenerating` flips to
    /// false a moment later nothing of the abandoned answer is read out over
    /// the user (`finishAssistantTurn` also refuses while `.listening`).
    private func bargeIn() {
        viewModel.stopGeneration()
        voice.stopSpeaking()
        spokenOffset = 0
        lastStreamed = ""
        beginListening()
    }

    private func listeningStateChanged(_ state: VoiceService.ListeningState) {
        guard isActive else { return }
        if case .unavailable(let reason) = state {
            // Said here, on the screen, in place of the old behaviour of
            // silently dropping back to "Tap to talk" as if nothing were
            // wrong.
            turn = .blocked(reason)
        }
    }

    /// Speak completed sentences as they stream in.
    private func speakNewSentences(in text: String) {
        let safeOffset = min(spokenOffset, text.count)
        let start = text.index(text.startIndex, offsetBy: safeOffset)
        guard let range = SpeechChunker.speakableSlice(of: text, from: start) else { return }
        let slice = String(text[range])
        spokenOffset = safeOffset + slice.count
        voice.speak(slice)
    }

    /// Speak whatever remains once generation finishes, then hand the turn
    /// back to the user.
    private func finishAssistantTurn() {
        guard isActive else { return }
        // Only while an assistant turn is actually in progress. The user may
        // have barged in (`.listening` - speaking the tail of the answer they
        // just interrupted would kill their listen and talk over them), the
        // screen may be showing an error (`.blocked` - a failed generation
        // sets the banner, clears the text and ends generation in one
        // transaction, and whichever observer fired first used to lose), or
        // the turn was ended by a pause (`.idle`).
        guard turn == .speaking || turn == .thinking else { return }
        // Away from the screen nothing is read out; the answer is in the chat.
        guard inForeground else {
            turn = .idle
            return
        }
        // Only ever speak THIS turn's text (never an older message).
        let text = lastStreamed
        guard !text.isEmpty else {
            // Nothing was generated (cancelled, blocked, or empty).
            if !voice.isSpeaking { turn = .idle }
            return
        }
        let safeOffset = min(spokenOffset, text.count)
        let start = text.index(text.startIndex, offsetBy: safeOffset)
        let remainder = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        spokenOffset = text.count
        // `speak` returns false when the tail has nothing sayable in it - a
        // closing "**" after the last sentence's full stop, a lone "#" or
        // "|". The turn then ends here, or when the earlier sentences finish
        // playing, instead of sitting on "Speaking" until the user taps.
        if !remainder.isEmpty, voice.speak(remainder) {
            turn = .speaking
        } else if !voice.isSpeaking {
            beginListening()
        }
    }
}
