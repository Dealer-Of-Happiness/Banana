//
//  RecorderView.swift
//  AIGoodbye
//
//  Record a meeting, lecture or appointment and get a transcript, summary and
//  action items without a single byte leaving the device. This is the feature
//  for people who are not allowed to use cloud transcription at all:
//  clinicians, lawyers, therapists, journalists and their sources.
//

import SwiftUI
import AVFoundation
import Speech
import UIKit

struct RecorderView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var recorder = RecordingService()
    @ObservedObject private var store = RecordingStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    enum Stage: Equatable { case ready, capturing, saving, finished }

    @State private var stage: Stage = .ready
    @State private var permissionDenied = false
    @State private var savedId: UUID?
    @State private var summaryTask: Task<Void, Never>?
    @State private var summaryProgress: Double = 0
    @State private var summaryStep = ""
    @State private var summaryFailed: String?
    @State private var nothingCaptured = false
    @State private var isStopping = false
    @State private var isStarting = false
    @State private var saveFailed: String?
    @State private var confirmingDiscard = false
    @State private var showingRecovery = false
    /// Held across a failed save, so the transcript isn't lost with the alert.
    @State private var unsaved: Recording?

    private var saved: Recording? {
        savedId.flatMap { id in store.recordings.first { $0.id == id } }
    }

    /// True from the tap on Start until audio is actually being captured.
    private var isPreparing: Bool { recorder.phase == .preparing || isStarting }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .ready, .capturing: captureScreen
                case .saving, .finished: resultScreen
                }
            }
            .navigationTitle(Text("Record"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        close()
                    } label: {
                        Text(stage == .finished ? "Done" : "Close")
                    }
                    .accessibilityLabel(Text("Close recorder"))
                    .disabled(isStopping)
                }
            }
            .alert("Nothing was recorded", isPresented: $nothingCaptured) {
                Button("OK", role: .cancel) {}
            } message: {
                // Only ever reached when the microphone delivered silence, so
                // the advice is true. Sound that couldn't be recognized is
                // saved as audio instead and never lands here.
                Text("No sound reached the microphone, so nothing was saved. Check that it isn't covered or in use by another app.")
            }
            .alert(
                "Couldn't save this recording",
                isPresented: Binding(get: { saveFailed != nil }, set: { if !$0 { saveFailed = nil } })
            ) {
                // The recording is still held in `unsaved`, so retrying is a
                // real option rather than a polite fiction.
                Button("Try again") {
                    saveFailed = nil
                    Task { await retrySave() }
                }
                Button("Discard", role: .destructive) {
                    saveFailed = nil
                    if let name = unsaved?.audioFileName {
                        try? FileManager.default.removeItem(at: RecordingStore.audioURL(named: name))
                    }
                    unsaved = nil
                    store.clearCheckpoint()
                    stage = .ready
                }
                Button("Keep trying later", role: .cancel) { saveFailed = nil }
            } message: {
                Text(saveFailed ?? "")
            }
            .confirmationDialog(
                "Discard this recording?",
                isPresented: $confirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Save and close") {
                    Task {
                        await stopRecording()
                        // Only leave if it actually saved. Dismissing here
                        // regardless took the failure alert - and the only
                        // in-memory copy of the transcript - away with the
                        // sheet.
                        guard saveFailed == nil, unsaved == nil, !nothingCaptured else { return }
                        close(force: true)
                    }
                }
                Button("Discard recording", role: .destructive) { close(force: true) }
                Button("Keep recording", role: .cancel) {}
            } message: {
                Text("This recording hasn't been saved yet.")
            }
            .alert("Recover the interrupted recording?", isPresented: $showingRecovery) {
                Button("Recover") {
                    store.recoverPendingCheckpoint(
                        title: RecordingSummarizer.fallbackTitle(
                            from: store.pendingCheckpoint?.transcript ?? ""
                        )
                    )
                }
                Button("Delete", role: .destructive) { store.discardPendingCheckpoint() }
                Button("Decide later", role: .cancel) {}
            } message: {
                Text("AiGoodbye stopped while a recording was in progress. What was captured up to that point can be saved.")
            }
        }
        .onAppear {
            // Something interrupted a recording last time - a crash, running
            // out of memory, or a force quit. Whatever was captured is still
            // on disk; offer it rather than silently deleting it.
            if store.pendingCheckpoint != nil { showingRecovery = true }
        }
        .onDisappear {
            summaryTask?.cancel()
            // Only throw away a recording that is still in progress: after
            // it has been saved, cancelling would delete its audio file.
            if recorder.phase != .idle && !isStopping { recorder.cancel() }
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: recorder.phase) { _, phase in
            // Keep the screen awake only while actually capturing.
            UIApplication.shared.isIdleTimerDisabled = (phase == .recording)
        }
        .onChange(of: recorder.reachedLimit) { _, hit in
            // Four hours is the cap: save what we have rather than leaving a
            // paused recording the user can't restart.
            if hit && stage == .capturing { Task { await stopRecording() } }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from Settings after granting permission.
            if phase == .active { permissionDenied = false }
        }
        .interactiveDismissDisabled(stage == .capturing || stage == .saving)
    }

    // MARK: - Capture

    private var captureScreen: some View {
        VStack(spacing: 0) {
            statusBlock

            Divider()

            transcriptBlock

            Divider()

            controlBlock
        }
        .background(Color(.systemGroupedBackground))
    }

    private var statusBlock: some View {
        VStack(spacing: 10) {
            Text(ConversationExporter.durationText(recorder.elapsed))
                .font(.system(size: 46, weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityLabel(Text("Recorded so far: \(ConversationExporter.durationText(recorder.elapsed))"))

            levelMeter

            if isPreparing {
                // First use of a language downloads a system speech model,
                // which can take minutes. Silence here looked like a dead
                // button, and invited the second tap that broke the session.
                VStack(spacing: 6) {
                    if recorder.preparingProgress > 0 {
                        ProgressView(value: recorder.preparingProgress)
                            .frame(maxWidth: 240)
                        Text("Downloading the speech model for this language, once.")
                    } else {
                        ProgressView()
                        Text("Getting the microphone ready...")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityElement(children: .combine)
            } else if let notice = recorder.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else if recorder.phase == .paused {
                Text("Paused")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if recorder.phase == .recording {
                Label(
                    recorder.transcribes
                        ? L10n.text("Transcribing on this device")
                        : L10n.text("Recording audio only"),
                    systemImage: "lock.fill"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    private var levelMeter: some View {
        HStack(spacing: 4) {
            ForEach(0..<24, id: \.self) { index in
                let threshold = Double(index) / 24
                let lit = recorder.phase == .recording && recorder.level > threshold
                Capsule()
                    .fill(lit ? Color.red : Color.secondary.opacity(0.25))
                    .frame(width: 5, height: lit ? 10 + CGFloat(recorder.level) * 22 : 10)
            }
        }
        .animation(.easeOut(duration: 0.15), value: recorder.level)
        .frame(height: 34)
        .accessibilityHidden(true)
    }

    /// The last few thousand characters of the live transcript.
    private var visibleTranscript: String {
        let limit = 4000
        let text = recorder.transcript
        guard text.count > limit else { return text }
        return "..." + String(text.suffix(limit))
    }

    private var transcriptBlock: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if recorder.transcript.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text(stage == .ready
                             ? L10n.text("Record a meeting, lecture or appointment. The transcript, summary and action items are all made on this device - nothing is uploaded.")
                             : L10n.text("Listening..."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 50)
                    .padding(.horizontal, 32)
                } else {
                    // Only the tail is rendered while capturing. Laying out a
                    // three-hour transcript several times a second is what
                    // made this screen stutter and the phone run hot; the
                    // whole thing is shown on the result screen.
                    Text(visibleTranscript)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                        .id("transcript")
                }
            }
            .onChange(of: recorder.transcript) { _, _ in
                withAnimation { proxy.scrollTo("transcript", anchor: .bottom) }
            }
        }
    }

    private var controlBlock: some View {
        VStack(spacing: 12) {
            if permissionDenied {
                Text("AiGoodbye needs microphone access to record. You can enable it in the Settings app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                if stage == .ready {
                    Button {
                        beginRecording()
                    } label: {
                        Label(
                            isPreparing ? L10n.text("Getting ready...") : L10n.text("Start recording"),
                            systemImage: isPreparing ? "hourglass" : "record.circle.fill"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.red.opacity(0.15)))
                        .foregroundStyle(isPreparing ? Color.secondary : Color.red)
                    }
                    .buttonStyle(.plain)
                    // Two taps used to start two sessions on top of each
                    // other, because everything in between is asynchronous
                    // and the screen looked completely idle throughout.
                    .disabled(isPreparing)
                } else {
                    Button {
                        if recorder.phase == .recording { recorder.pause() } else { recorder.resume() }
                    } label: {
                        Label(
                            recorder.phase == .recording ? L10n.text("Pause") : L10n.text("Resume"),
                            systemImage: recorder.phase == .recording ? "pause.fill" : "play.fill"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
                    }
                    .buttonStyle(.plain)
                    .disabled(isStopping)

                    Button {
                        Task { await stopRecording() }
                    } label: {
                        Label("Stop and save", systemImage: "stop.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.blue.opacity(0.15)))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(isStopping)
                }
            }

            if stage == .ready {
                Toggle(isOn: Binding(
                    get: { store.keepsAudio },
                    set: { store.keepsAudio = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep the audio")
                        Text("Off by default. The transcript is kept either way.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Result

    private var resultScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if stage == .saving {
                    VStack(alignment: .leading, spacing: 10) {
                        ProgressView(value: summaryProgress)
                        Text(summaryStep.isEmpty ? L10n.text("Summarizing on this device...") : summaryStep)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Skip summary") {
                            summaryTask?.cancel()
                            stage = .finished
                        }
                        .font(.subheadline)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
                }

                if let failure = summaryFailed {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let saved {
                    Text(saved.title)
                        .font(.title2.bold())

                    Text("\(saved.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(ConversationExporter.durationText(saved.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let summary = saved.summary, !summary.isEmpty {
                        MarkdownText(content: summary)
                    }

                    if !saved.transcript.isEmpty {
                        DisclosureGroup(L10n.text("Transcript")) {
                            Text(saved.transcript)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        }
                        .font(.headline)
                    }

                    Text("Saved to Recordings. You'll find it in the menu.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Actions

    private func beginRecording() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            // The microphone is the only permission asked for here. The
            // speech engine itself decides whether it needs the older
            // recognizer's authorization, and asks for it only then: the
            // system dialog for it claims speech is sent to Apple, which is
            // untrue of this app and contradicts the screen behind it. On
            // iOS 26 the modern engine needs nothing beyond the microphone.
            let mic = await AVAudioApplication.requestRecordPermission()
            guard mic else {
                permissionDenied = true
                return
            }
            if await recorder.start(language: appState.settings.appLanguage,
                                    keepAudio: store.keepsAudio,
                                    customVocabulary: store.customVocabulary) {
                stage = .capturing
            }
        }
    }

    private func stopRecording() async {
        guard !isStopping else { return }
        // A recording that failed to save is still held in `unsaved`, and the
        // service has already given up ownership of its audio file. Stopping
        // again would build a second, audio-less copy under a new id and
        // overwrite the one that still points at the file.
        guard unsaved == nil else {
            saveFailed = store.storageError
                ?? L10n.text("Your recordings couldn't be saved. The device may be out of space.")
            return
        }
        isStopping = true
        defer { isStopping = false }

        let result = await recorder.finish()

        // Nothing captured: don't leave an empty entry behind, and say so.
        guard !result.transcript.isEmpty || result.audioFileName != nil else {
            store.clearCheckpoint()
            // Back to a clean slate: the timer used to keep showing the
            // failed recording's duration over a "Start recording" button.
            recorder.cancel()
            stage = .ready
            nothingCaptured = true
            return
        }

        // Save immediately with a plain title, so a failed or cancelled
        // summary can never cost the user their recording.
        let recording = Recording(
            title: RecordingSummarizer.fallbackTitle(from: result.transcript),
            duration: result.duration,
            transcript: result.transcript,
            summary: nil,
            audioFileName: result.audioFileName,
            languageCode: VoiceService.voiceLocale(for: appState.settings.appLanguage).identifier
        )
        // Never tell the user it was saved if it wasn't - and keep it, so
        // "try again" is a real option. Dropping it here meant the only
        // remaining copy of a three-hour transcript was the text on screen,
        // which vanished with the sheet.
        unsaved = recording
        guard store.add(recording) else {
            saveFailed = store.storageError
                ?? L10n.text("Your recordings couldn't be saved. The device may be out of space.")
            return
        }
        unsaved = nil
        // Saved for real: the crash checkpoint has done its job.
        store.clearCheckpoint()
        savedId = recording.id

        guard !result.transcript.isEmpty else {
            stage = .finished
            return
        }

        stage = .saving
        summaryProgress = 0
        summaryStep = ""
        summaryFailed = nil
        let id = recording.id
        let transcript = recording.transcript
        summaryTask = Task {
            do {
                let outcome = try await RecordingSummarizer.summarize(
                    transcript: transcript,
                    engine: appState.engine,
                    progress: { value, step in
                        summaryProgress = value
                        summaryStep = step
                    }
                )
                guard !Task.isCancelled else { return }
                // Read back through the store: the user may have renamed it
                // while the summary was running.
                store.modify(id: id) { recording in
                    recording.summary = outcome.summary
                    if recording.title == RecordingSummarizer.fallbackTitle(from: transcript) {
                        recording.title = outcome.title
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                summaryFailed = L10n.text("The summary couldn't be made right now. The recording and transcript are saved, and you can summarize it later.")
            }
            stage = .finished
        }
    }

    /// Closing mid-recording used to delete hours of audio on one tap of a
    /// plainly-labelled toolbar button. It now asks, and defaults to saving.
    private func close(force: Bool = false) {
        if !force, stage == .capturing, recorder.phase != .idle {
            confirmingDiscard = true
            return
        }
        summaryTask?.cancel()
        if recorder.phase != .idle { recorder.cancel() }
        UIApplication.shared.isIdleTimerDisabled = false
        dismiss()
    }

    /// Retry a save that failed, using the recording still held in memory.
    private func retrySave() async {
        guard let recording = unsaved else { return }
        guard store.add(recording) else {
            saveFailed = store.storageError
                ?? L10n.text("Your recordings couldn't be saved. The device may be out of space.")
            return
        }
        unsaved = nil
        store.clearCheckpoint()
        savedId = recording.id
        stage = .finished
    }
}
