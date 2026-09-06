//
//  RecordingsView.swift
//  AIGoodbye
//
//  The library of private recordings: browse, search, play, summarize,
//  export, and add to the Knowledge Library so the AI can answer questions
//  about them in any conversation.
//

import SwiftUI
import AVFoundation
import Combine
import UIKit
import UniformTypeIdentifiers

struct RecordingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var store = RecordingStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var showingRecorder = false
    @State private var confirmDeleteAll = false

    private var results: [Recording] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.recordings }
        return store.recordings.filter { recording in
            let haystack = [recording.title, recording.transcript, recording.summary ?? ""]
            return haystack.contains { field in
                field.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let problem = store.storageError {
                    // Never show "no recordings yet" when the truth is that
                    // they couldn't be read.
                    VStack(spacing: 14) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 42))
                            .foregroundStyle(.orange)
                        Text(problem)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                } else if store.recordings.isEmpty {
                    // The vocabulary list is worth reaching before the first
                    // recording, not only after one exists.
                    List {
                        Section {
                            emptyState.listRowBackground(Color.clear)
                        }
                        Section {
                            NavigationLink {
                                VocabularyView()
                            } label: {
                                Label("Names and words to get right", systemImage: "character.book.closed")
                            }
                        }
                    }
                } else {
                    list
                }
            }
            .navigationTitle(Text("Recordings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingRecorder = true
                    } label: {
                        Image(systemName: "mic.badge.plus")
                    }
                    .accessibilityLabel(Text("New recording"))
                }
            }
            .fullScreenCover(isPresented: $showingRecorder) {
                RecorderView()
                    .environmentObject(appState)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("No recordings yet")
                .font(.headline)
            Text("Record a meeting, lecture or appointment. The transcript, summary and action items are all made on this device - nothing is uploaded.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showingRecorder = true
            } label: {
                Label("Start recording", systemImage: "record.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.red.opacity(0.15)))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(32)
    }

    private var list: some View {
        List {
            Section {
                ForEach(results) { recording in
                    NavigationLink {
                        RecordingDetailView(recordingId: recording.id)
                            .environmentObject(appState)
                    } label: {
                        row(for: recording)
                    }
                }
                .onDelete { offsets in
                    // Map first: the offsets index the filtered results.
                    let doomed = offsets.map { results[$0] }
                    for recording in doomed { store.delete(recording) }
                }
            } footer: {
                if !store.recordings.isEmpty {
                    Text("Recordings stay on this device and are excluded from backups.")
                }
            }

            Section {
                NavigationLink {
                    VocabularyView()
                } label: {
                    Label("Names and words to get right", systemImage: "character.book.closed")
                }
            }

            if !store.recordings.isEmpty {
                Section {
                    Button(role: .destructive) {
                        confirmDeleteAll = true
                    } label: {
                        Label("Delete all recordings", systemImage: "trash")
                    }
                }
            }
        }
        .searchable(text: $query, prompt: Text("Search recordings"))
        .alert("Delete all recordings?", isPresented: $confirmDeleteAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) { store.deleteAll() }
        } message: {
            Text("Every transcript, summary and audio file will be permanently deleted.")
        }
    }

    private func row(for recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.title)
                .font(.body)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(ConversationExporter.durationText(recording.duration))
                if recording.summary == nil {
                    Text("·")
                    Text("No summary yet")
                }
                if recording.audioFileName != nil {
                    Image(systemName: "waveform")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct RecordingDetailView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var store = RecordingStore.shared
    @ObservedObject private var library = KnowledgeLibrary.shared
    @StateObject private var player = RecordingPlayer()

    let recordingId: UUID

    @State private var exportURL: URL?
    @State private var exportFailed = false
    @State private var isSummarizing = false
    @State private var summaryStep = ""
    @State private var summaryProgress: Double = 0
    @State private var summaryFailed: String?
    @State private var summaryTask: Task<Void, Never>?
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var audioMissing = false

    private var recording: Recording? {
        store.recordings.first { $0.id == recordingId }
    }

    /// Derived from the stored recording, not local state, so leaving and
    /// returning can't add a second copy to the library.
    private var addedToLibrary: Bool {
        guard let documentId = recording?.libraryDocumentId else { return false }
        return library.documents.contains { $0.id == documentId }
    }

    var body: some View {
        Group {
            if let recording {
                content(for: recording)
            } else {
                // Deleted while open.
                Text("This recording is no longer available.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Text("Recording"))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            summaryTask?.cancel()
            player.stop()
        }
        .sheet(item: $exportURL) { url in
            ShareSheet(items: [url])
        }
        .alert("Couldn't export this recording", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try again.")
        }
        .alert("Rename recording", isPresented: $renaming) {
            TextField("Title", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard var updated = recording else { return }
                let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                updated.title = trimmed
                store.update(updated)
            }
        }
    }

    private func content(for recording: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(for: recording)

                if recording.audioFileName != nil {
                    playerControls(for: recording)
                }

                if isSummarizing {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: summaryProgress)
                        Text(summaryStep.isEmpty ? L10n.text("Summarizing on this device...") : summaryStep)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Stop") {
                            summaryTask?.cancel()
                            isSummarizing = false
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

                if let summary = recording.summary, !summary.isEmpty {
                    MarkdownText(content: summary)
                } else if !isSummarizing && !recording.transcript.isEmpty {
                    Button {
                        summarize(recording)
                    } label: {
                        Label("Summarize with AI", systemImage: "sparkles")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.blue.opacity(0.15)))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }

                if !recording.transcript.isEmpty {
                    DisclosureGroup(L10n.text("Transcript")) {
                        Text(recording.transcript)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .font(.headline)
                }

                actions(for: recording)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private func header(for recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recording.title)
                .font(.title2.bold())
            Text("\(recording.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(ConversationExporter.durationText(recording.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func playerControls(for recording: Recording) -> some View {
        HStack(spacing: 14) {
            Button {
                if player.isPlaying {
                    player.pause()
                } else if let name = recording.audioFileName {
                    player.play(url: RecordingStore.audioURL(named: name))
                }
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(player.isPlaying ? L10n.text("Pause") : L10n.text("Play")))

            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: player.fraction)
                Text(player.failed
                     ? L10n.text("The audio for this recording is missing.")
                     : ConversationExporter.durationText(player.position))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func actions(for recording: Recording) -> some View {
        VStack(spacing: 0) {
            actionRow("Rename", systemImage: "pencil") {
                draftTitle = recording.title
                renaming = true
            }
            Divider()
            if !recording.transcript.isEmpty {
                actionRow(
                    addedToLibrary ? "Added to Knowledge Library" : "Add to Knowledge Library",
                    systemImage: addedToLibrary ? "checkmark.circle" : "books.vertical"
                ) {
                    guard !addedToLibrary else { return }
                    Task {
                        let documentId = await library.add(
                            name: recording.title,
                            fullText: recording.transcript
                        )
                        // Remembered so deleting the recording also deletes
                        // this copy of the transcript.
                        store.modify(id: recording.id) { $0.libraryDocumentId = documentId }
                    }
                }
                .disabled(addedToLibrary)
                Divider()
                actionRow("Copy transcript", systemImage: "doc.on.doc") {
                    // Local only, and short-lived: the plain clipboard syncs
                    // to the user's other devices through Apple's servers,
                    // which is exactly what this app promises not to do.
                    UIPasteboard.general.setItems(
                        [[UTType.utf8PlainText.identifier: recording.transcript]],
                        options: [
                            .localOnly: true,
                            .expirationDate: Date().addingTimeInterval(300)
                        ]
                    )
                }
                Divider()
            }
            actionRow("Export as Markdown", systemImage: "doc.text") {
                if let url = ConversationExporter.markdownFile(for: recording) {
                    exportURL = url
                } else {
                    exportFailed = true
                }
            }
            Divider()
            actionRow("Export as PDF", systemImage: "doc.richtext") {
                if let url = ConversationExporter.pdfFile(for: recording) {
                    exportURL = url
                } else {
                    exportFailed = true
                }
            }
            if recording.summary != nil && !recording.transcript.isEmpty {
                Divider()
                actionRow("Summarize again", systemImage: "arrow.clockwise") {
                    summarize(recording)
                }
                .disabled(isSummarizing)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func actionRow(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func summarize(_ recording: Recording) {
        summaryFailed = nil
        summaryProgress = 0
        summaryStep = ""
        isSummarizing = true
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
                // Read back through the store: the user may have renamed the
                // recording while this was running.
                store.modify(id: id) { recording in
                    recording.summary = outcome.summary
                    // Only replace a title the user hasn't already chosen.
                    if recording.title == RecordingSummarizer.fallbackTitle(from: transcript) {
                        recording.title = outcome.title
                    }
                }
            } catch is CancellationError {
                // Left as it was.
            } catch {
                summaryFailed = L10n.text("The summary couldn't be made right now. The recording and transcript are safe.")
            }
            isSummarizing = false
        }
    }
}

// MARK: - Playback

@MainActor
final class RecordingPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var fraction: Double = 0
    /// Set when the audio file is gone, so the UI can say so instead of
    /// showing a play button that does nothing.
    @Published private(set) var failed = false

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var ownsSession = false

    @discardableResult
    func play(url: URL) -> Bool {
        if player == nil || player?.url != url {
            guard FileManager.default.fileExists(atPath: url.path),
                  let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
                failed = true
                return false
            }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            ownsSession = true
            player = newPlayer
            newPlayer.delegate = self
        }
        guard let player else { return false }
        failed = false
        player.play()
        isPlaying = true
        startTimer()
        return true
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate(); timer = nil
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        position = 0
        fraction = 0
        timer?.invalidate(); timer = nil
        // Only release the session if this player took it; another screen
        // may be mid-sentence behind us.
        if ownsSession {
            ownsSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let tick = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            let owner = self
            Task { @MainActor in
                guard let owner, let player = owner.player else { return }
                owner.position = player.currentTime
                owner.fraction = player.duration > 0 ? player.currentTime / player.duration : 0
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }
}

extension RecordingPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false
            position = 0
            fraction = 0
            timer?.invalidate(); timer = nil
        }
    }
}
