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

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemBackground), Color.blue.opacity(0.12)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                header
                Spacer()
                statusIndicator
                statusText
                Spacer()
                transcriptArea
                controls
            }
            .padding()
        }
        .onAppear(perform: start)
        .onDisappear(perform: teardown)
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding doesn't fire onDisappear: never leave the mic hot.
            // `pause` keeps the callbacks so the screen still works on return.
            if phase != .active {
                voice.pause()
                if isActive { turn = .idle }
            }
        }
        .onChange(of: viewModel.streamingText) { _, text in
            if let text, !text.isEmpty {
                lastStreamed = text
                turn = .speaking
                speakNewSentences(in: text)
            }
        }
        .onChange(of: viewModel.isGenerating) { _, generating in
            if generating {
                turn = .thinking
            } else {
                finishAssistantTurn()
            }
        }
        .onChange(of: viewModel.errorBanner) { _, banner in
            // Errors are surfaced in the chat screen behind this cover.
            if banner != nil { dismiss() }
        }
        .onChange(of: viewModel.consentRequest?.id) { _, request in
            // A model download needs the consent sheet in the chat screen.
            if request != nil { dismiss() }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice Conversation")
                    .font(.headline)
                Text("100% on your device")
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
            .accessibilityLabel(Text("Close voice mode"))
        }
    }

    private var statusIndicator: some View {
        ZStack {
            Circle()
                .fill(indicatorColor.opacity(0.15))
                .frame(width: 190, height: 190)
                .scaleEffect(1 + voice.micLevel * 0.5)
                .animation(.easeOut(duration: 0.12), value: voice.micLevel)

            Circle()
                .fill(indicatorColor.opacity(0.25))
                .frame(width: 140, height: 140)

            Image(systemName: indicatorSymbol)
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(indicatorColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .contentShape(Circle())
        .onTapGesture {
            // Barge-in: interrupt the answer (including any generation still
            // streaming, which would otherwise speak over the user) and talk.
            if turn == .speaking || turn == .thinking || voice.isSpeaking {
                viewModel.stopGeneration()
                voice.stopSpeaking()
                beginListening()
            } else if turn == .idle {
                beginListening()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Voice status"))
        .accessibilityHint(Text("Double tap to interrupt and speak"))
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
                Text("AiGoodbye needs microphone and speech access for voice conversations. You can enable both in the Settings app.")
            } else if case .blocked(let reason) = turn {
                Text(reason)
            } else {
                switch turn {
                case .speaking:
                    Text("Speaking · tap the circle to interrupt")
                case .thinking:
                    Text("Thinking...")
                case .listening:
                    Text("Listening · pause to send")
                default:
                    Text("Tap to talk")
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
    }

    private var transcriptArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !voice.liveTranscript.isEmpty {
                    Text(voice.liveTranscript)
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
        .frame(maxHeight: 220)
        .defaultScrollAnchor(.bottom)
    }

    private var controls: some View {
        Button {
            viewModel.stopGeneration()
            voice.stopSpeaking()
            beginListening()
        } label: {
            Label("Tap to talk", systemImage: "mic.badge.plus")
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
        }
        .disabled(turn == .listening || permissionDenied)
        .padding(.bottom, 8)
    }

    // MARK: - Flow

    private func start() {
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
                guard isActive, !viewModel.isGenerating, turn == .speaking else { return }
                beginListening()
            }
        }
        voice.onListeningEnded = {
            Task { @MainActor in
                guard isActive, turn == .listening else { return }
                turn = .idle
            }
        }
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
        voice.shutdown()   // also clears the callbacks (no retain cycle)
    }

    private func beginListening() {
        guard isActive, !permissionDenied else { return }
        voice.startListening(language: appState.settings.appLanguage)
        if case .unavailable(let reason) = voice.listeningState {
            turn = .blocked(reason)
        } else {
            turn = .listening
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
        if !remainder.isEmpty {
            turn = .speaking
            voice.speak(remainder)
        } else if !voice.isSpeaking {
            beginListening()
        }
    }
}
