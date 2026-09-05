//
//  VoiceModeView.swift
//  AIGoodbye
//
//  Hands-free voice conversation, fully offline: speak, the AI answers out
//  loud, and listening resumes automatically. Turns are saved into the
//  current chat like typed messages.
//

import SwiftUI

struct VoiceModeView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var voice = VoiceService()
    @Environment(\.dismiss) private var dismiss

    @State private var permissionDenied = false
    @State private var spokenOffset: Int = 0
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
        .onDisappear {
            isActive = false
            voice.shutdown()
        }
        .onChange(of: viewModel.streamingText) { _, _ in
            speakNewSentences()
        }
        .onChange(of: viewModel.isGenerating) { _, generating in
            if !generating { speakRemainder() }
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
            // Pulsing ring driven by mic level / speaking state.
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
            // Barge-in: interrupt the answer and talk.
            if voice.isSpeaking {
                voice.stopSpeaking()
                restartListening()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Voice status"))
        .accessibilityHint(Text("Double tap to interrupt and speak"))
    }

    private var indicatorColor: Color {
        if voice.isSpeaking { return .green }
        if viewModel.isGenerating { return .purple }
        if voice.listeningState == .listening { return .blue }
        return .gray
    }

    private var indicatorSymbol: String {
        if voice.isSpeaking { return "speaker.wave.2.fill" }
        if viewModel.isGenerating { return "brain" }
        if voice.listeningState == .listening { return "mic.fill" }
        return "mic.slash.fill"
    }

    @ViewBuilder
    private var statusText: some View {
        if permissionDenied {
            Text("AiGoodbye needs microphone and speech access for voice conversations. You can enable both in the Settings app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else if case .unavailable(let reason) = voice.listeningState {
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else if voice.isSpeaking {
            Text("Speaking · tap the circle to interrupt")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if viewModel.isGenerating {
            Text("Thinking...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if voice.listeningState == .listening {
            Text("Listening · pause to send")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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
                if let streaming = viewModel.streamingText, !streaming.isEmpty {
                    Text(streaming)
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
        HStack(spacing: 40) {
            Button {
                restartListening()
            } label: {
                Label("Tap to talk", systemImage: "mic.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
            }
            .disabled(voice.listeningState == .listening)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Flow

    private func start() {
        voice.onFinalTranscript = { text in
            Task { @MainActor in
                guard isActive else { return }
                spokenOffset = 0
                await viewModel.sendVoicePrompt(text)
            }
        }
        voice.onFinishedSpeaking = {
            Task { @MainActor in
                guard isActive, !viewModel.isGenerating else { return }
                restartListening()
            }
        }
        Task {
            let granted = await VoiceService.requestPermissions()
            if granted {
                restartListening()
            } else {
                permissionDenied = true
            }
        }
    }

    private func restartListening() {
        guard isActive else { return }
        voice.startListening(language: appState.settings.appLanguage)
    }

    /// Speak completed sentences as they stream in.
    private func speakNewSentences() {
        guard let text = viewModel.streamingText else { return }
        let start = text.index(text.startIndex, offsetBy: min(spokenOffset, text.count))
        guard let range = SpeechChunker.speakableSlice(of: text, from: start) else { return }
        let slice = String(text[range])
        spokenOffset += slice.count
        voice.speak(slice)
    }

    /// Speak whatever remains once generation finishes.
    private func speakRemainder() {
        guard isActive else { return }
        // The final text lives in the last assistant message once streaming ends.
        let finalText = viewModel.streamingText
            ?? viewModel.messages.last(where: { $0.role == .assistant })?.content
        guard let finalText else { restartListening(); return }
        let start = finalText.index(finalText.startIndex, offsetBy: min(spokenOffset, finalText.count))
        let remainder = String(finalText[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        spokenOffset = finalText.count
        if !remainder.isEmpty {
            voice.speak(remainder)
        } else if !voice.isSpeaking {
            restartListening()
        }
    }
}
