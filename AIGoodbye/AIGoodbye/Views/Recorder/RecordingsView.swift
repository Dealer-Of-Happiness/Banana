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
import MediaPlayer
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Recording", systemImage: "mic.badge.plus") {
                        showingRecorder = true
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

    /// A search that matched nothing, as opposed to an empty library.
    private var searchCameUpEmpty: Bool {
        results.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        // An overlay rather than a replacement: `searchable` lives on the
        // list, and swapping the list out would take the search field (and
        // the query) with it. Without this the rows simply vanished under the
        // search field, which reads as "the recordings are gone".
        .overlay {
            if searchCameUpEmpty {
                ContentUnavailableView.search(text: query)
                    .background(Color(.systemGroupedBackground))
            }
        }
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
                Text(recording.createdAt.aigFormatted(date: .abbreviated, time: .shortened))
                Text("·")
                    .accessibilityHidden(true)
                Text(ConversationExporter.durationText(recording.duration))
                    .accessibilityLabel(Text(verbatim: Recording.spokenDuration(recording.duration)))
                if recording.summary == nil {
                    Text("·")
                        .accessibilityHidden(true)
                    Text("No summary yet")
                }
                if recording.audioFileName != nil {
                    Image(systemName: "waveform")
                        .accessibilityHidden(true)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        // One stop per recording: title, date, length and summary state read
        // together, instead of the dots and the waveform glyph as separate
        // elements and "1:23" read as a time of day.
        .accessibilityElement(children: .combine)
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
    /// The temporary, title-named copy of the audio handed to the share sheet.
    @State private var sharedAudioCopy: URL?
    @State private var isSummarizing = false
    @State private var summaryStep = ""
    @State private var summaryProgress: Double = 0
    @State private var summaryFailed: String?
    @State private var summaryTask: Task<Void, Never>?
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var audioMissing = false
    /// Where the playback slider's thumb is while a finger drags it.
    @State private var scrubPosition: TimeInterval?
    @State private var isScrubbing = false

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
            removeSharedAudioCopy()
        }
        .sheet(item: $exportURL) { url in
            ShareSheet(items: [url])
        }
        .alert("Couldn't export this recording", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try again.")
        }
        .sheet(isPresented: $renaming) {
            TextEntrySheet(
                title: "Rename recording",
                placeholder: "Title",
                actionTitle: "Save",
                initialText: draftTitle
            ) { title in
                guard var updated = recording else { return }
                updated.title = title
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
                        Button {
                            summaryTask?.cancel()
                            isSummarizing = false
                        } label: {
                            // The 44 pt target is part of the label, so the
                            // whole of it is tappable - a frame outside the
                            // button only pads the layout, not the hit area.
                            Text("Stop")
                                .font(.subheadline)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
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
            Text("\(recording.createdAt.aigFormatted(date: .abbreviated, time: .shortened)) · \(ConversationExporter.durationText(recording.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The position the slider shows: where the finger is while scrubbing,
    /// otherwise where playback is.
    private var shownPosition: TimeInterval {
        min(scrubPosition ?? player.position, max(player.duration, 0))
    }

    private func playerControls(for recording: Recording) -> some View {
        VStack(spacing: 8) {
            if player.failed {
                Label(L10n.text("The audio for this recording is missing."), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Minute 47 of a lecture used to mean playing from the start.
                // Seeks when the finger lifts, not on every pixel of the drag;
                // VoiceOver's swipe up/down (no drag) seeks straight away.
                Slider(
                    value: Binding(
                        get: { shownPosition },
                        set: { value in
                            if isScrubbing { scrubPosition = value } else { player.seek(to: value) }
                        }
                    ),
                    in: 0...max(player.duration, 0.1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing {
                            if let target = scrubPosition { player.seek(to: target) }
                            scrubPosition = nil
                        }
                    }
                )
                .disabled(player.duration <= 0)
                .accessibilityLabel(Text("Playback position"))
                .accessibilityValue(Text(verbatim: L10n.text(
                    "\(Recording.spokenDuration(shownPosition)) of \(Recording.spokenDuration(player.duration))"
                )))

                HStack {
                    Text(verbatim: ConversationExporter.durationText(shownPosition))
                    Spacer()
                    Text(verbatim: ConversationExporter.durationText(player.duration))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                // The slider's value already says both.
                .accessibilityHidden(true)
            }

            HStack(spacing: 18) {
                skipButton(back: true)

                Button {
                    if player.isPlaying {
                        player.pause()
                    } else if let name = recording.audioFileName {
                        player.play(url: RecordingStore.audioURL(named: name), title: recording.title)
                    }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                        // The glyph is 40 pt; the tappable area must not be. Inside
                        // the label, so the padding is part of the hit test.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(player.isPlaying ? L10n.text("Pause") : L10n.text("Play")))

                skipButton(back: false)

                Spacer(minLength: 0)

                rateMenu
            }
            .disabled(player.failed)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        .onAppear {
            // Opened, not played: the length is known and the slider works
            // before the first tap on Play.
            if let name = recording.audioFileName {
                player.load(url: RecordingStore.audioURL(named: name))
            }
        }
    }

    private func skipButton(back: Bool) -> some View {
        Button {
            player.skip(by: back ? -RecordingPlayer.skipInterval : RecordingPlayer.skipInterval)
        } label: {
            Image(systemName: back ? "gobackward.15" : "goforward.15")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(player.duration <= 0)
        .accessibilityLabel(Text(back ? L10n.text("Back 15 seconds") : L10n.text("Forward 15 seconds")))
    }

    private var rateMenu: some View {
        Menu {
            Picker("Playback speed", selection: Binding(
                get: { player.rate },
                set: { player.setRate($0) }
            )) {
                ForEach(RecordingPlayer.rates, id: \.self) { rate in
                    Text(verbatim: Self.rateLabel(rate)).tag(rate)
                }
            }
        } label: {
            Text(verbatim: Self.rateLabel(player.rate))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Playback speed"))
        .accessibilityValue(Text(verbatim: Self.rateLabel(player.rate)))
    }

    /// "1.5×", with the decimal separator of the app's language.
    private static func rateLabel(_ rate: Float) -> String {
        Double(rate).formatted(.number.precision(.fractionLength(0...2)).locale(L10n.locale)) + "×"
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
                        guard let added = try? await library.add(
                            name: recording.title,
                            fullText: recording.transcript
                        ) else { return }
                        // Remembered so deleting the recording also deletes
                        // this copy of the transcript.
                        store.modify(id: recording.id) { $0.libraryDocumentId = added.id }
                    }
                }
                .disabled(addedToLibrary)
                Divider()
                actionRow("Copy transcript", systemImage: "doc.on.doc") {
                    copyLocally(recording.transcript)
                }
                Divider()
            }
            if let summary = recording.summary, !summary.isEmpty {
                actionRow("Copy summary", systemImage: "doc.on.clipboard") {
                    copyLocally(summary)
                }
                Divider()
            }
            if let audioName = recording.audioFileName {
                // "Keep the audio" was on, but the audio could never leave
                // the app - a journalist couldn't hand the interview to an
                // editor, nobody could archive it.
                actionRow("Share audio", systemImage: "waveform") {
                    shareAudio(named: audioName, title: recording.title)
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

    /// Local only, and short-lived: the plain clipboard syncs to the user's
    /// other devices through Apple's servers, which is exactly what this app
    /// promises not to do.
    private func copyLocally(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(300)
            ]
        )
    }

    /// Share a copy named after the recording - the stored file is a UUID,
    /// which means nothing to whoever receives it.
    private func shareAudio(named name: String, title: String) {
        removeSharedAudioCopy()
        let source = RecordingStore.audioURL(named: name)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.audioFileName(for: title))
        do {
            try? FileManager.default.removeItem(at: copy)
            // A clone on the same volume, so even hours of audio are instant.
            try FileManager.default.copyItem(at: source, to: copy)
            sharedAudioCopy = copy
            exportURL = copy
        } catch {
            exportFailed = true
        }
    }

    /// The audio is the most sensitive thing in a recording, so its shared
    /// copy is removed once the user leaves the recording (or shares again)
    /// - not when the share sheet closes, which can be while AirDrop or Mail
    /// is still reading it.
    private func removeSharedAudioCopy() {
        guard let copy = sharedAudioCopy else { return }
        try? FileManager.default.removeItem(at: copy)
        sharedAudioCopy = nil
    }

    private static func audioFileName(for title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? L10n.text("Recording") : String(cleaned.prefix(60))) + ".m4a"
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
        let languageCode = recording.languageCode
        summaryTask = Task {
            do {
                let outcome = try await RecordingSummarizer.summarize(
                    transcript: transcript,
                    languageCode: languageCode,
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
            } catch let error as RecordingSummarizer.SummarizerError {
                // Says what to do (download the model from the chat screen,
                // wait for the other task) rather than a generic shrug.
                summaryFailed = error.errorDescription
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
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var rate: Float = 1
    /// Set when the audio file is gone, so the UI can say so instead of
    /// showing a play button that does nothing.
    @Published private(set) var failed = false

    /// The speeds every voice-memo app offers; 1.5x and 2x are how most
    /// people re-listen to a lecture or a meeting.
    static let rates: [Float] = [1, 1.25, 1.5, 2]
    static let skipInterval: TimeInterval = 15

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var ownsSession = false
    private var title = ""
    private var interruptionObserver: NSObjectProtocol?

    private struct RemoteTarget {
        let command: MPRemoteCommand
        let token: Any
    }
    private var remoteTargets: [RemoteTarget] = []

    private enum RemoteAction: Sendable {
        case play, pause, toggle, skipForward, skipBackward, seek
    }

    /// Open `url` without playing it, so the length is known and the slider
    /// works before the first tap on Play. Never touches the audio session.
    @discardableResult
    func load(url: URL) -> Bool {
        if let player, player.url == url { return true }
        guard FileManager.default.fileExists(atPath: url.path),
              let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
            failed = true
            return false
        }
        newPlayer.delegate = self
        // Must be set before `prepareToPlay`, or every rate but 1x is
        // silently ignored.
        newPlayer.enableRate = true
        newPlayer.rate = rate
        newPlayer.prepareToPlay()
        player = newPlayer
        failed = false
        duration = newPlayer.duration
        position = 0
        return true
    }

    @discardableResult
    func play(url: URL, title: String) -> Bool {
        guard load(url: url) else { return false }
        self.title = title
        return resume()
    }

    /// Continue the loaded file from where it is.
    @discardableResult
    private func resume() -> Bool {
        guard let player else { return false }
        // Every time, not only for a new file: a phone call in between
        // deactivates the session, and playing on an inactive one is silent.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        ownsSession = true
        player.rate = rate
        player.play()
        isPlaying = true
        startTimer()
        observeInterruptions()
        registerRemoteCommands()
        updateNowPlaying()
        return true
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate(); timer = nil
        syncPosition()
        updateNowPlaying()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(time, 0), player.duration)
        syncPosition()
        updateNowPlaying()
    }

    func skip(by seconds: TimeInterval) {
        guard let player else { return }
        seek(to: player.currentTime + seconds)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        player?.rate = newRate
        updateNowPlaying()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        position = 0
        duration = 0
        timer?.invalidate(); timer = nil
        // Lock-screen controls and the Now Playing card belong to this
        // screen; nothing is left behind pointing at a closed recording.
        removeRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        // Only release the session if this player took it; another screen
        // may be mid-sentence behind us.
        if ownsSession {
            ownsSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func syncPosition() {
        position = player?.currentTime ?? 0
    }

    private func startTimer() {
        timer?.invalidate()
        let tick = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            let owner = self
            Task { @MainActor in
                guard let owner, let player = owner.player else { return }
                owner.position = player.currentTime
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    // MARK: Interruptions

    /// A call or Siri pauses the player underneath us; without this the
    /// screen kept showing Pause and the timer kept ticking over silence.
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            // A Notification is not Sendable; only the value crosses.
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let owner = self
            Task { @MainActor in owner?.handleInterruption(raw) }
        }
    }

    private func handleInterruption(_ rawType: UInt?) {
        guard let raw = rawType,
              AVAudioSession.InterruptionType(rawValue: raw) == .began,
              isPlaying else { return }
        isPlaying = false
        timer?.invalidate(); timer = nil
        syncPosition()
        updateNowPlaying()
    }

    // MARK: Lock screen and headphones

    /// Play, pause and skip from the lock screen, Control Center and
    /// AirPods. Registered on the first play, removed in `stop`.
    private func registerRemoteCommands() {
        guard remoteTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        let interval = [NSNumber(value: Self.skipInterval)]
        center.skipForwardCommand.preferredIntervals = interval
        center.skipBackwardCommand.preferredIntervals = interval
        addRemoteTarget(center.playCommand, .play)
        addRemoteTarget(center.pauseCommand, .pause)
        addRemoteTarget(center.togglePlayPauseCommand, .toggle)
        addRemoteTarget(center.skipForwardCommand, .skipForward)
        addRemoteTarget(center.skipBackwardCommand, .skipBackward)
        addRemoteTarget(center.changePlaybackPositionCommand, .seek)
    }

    private func addRemoteTarget(_ command: MPRemoteCommand, _ action: RemoteAction) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] event in
            // Read here; the event object itself does not cross into the task.
            let target = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            let owner = self
            Task { @MainActor in owner?.performRemote(action, seekTarget: target) }
            return .success
        }
        remoteTargets.append(RemoteTarget(command: command, token: token))
    }

    private func removeRemoteCommands() {
        for target in remoteTargets {
            target.command.removeTarget(target.token)
        }
        remoteTargets.removeAll()
    }

    private func performRemote(_ action: RemoteAction, seekTarget: TimeInterval?) {
        switch action {
        case .play:
            if !isPlaying { resume() }
        case .pause:
            if isPlaying { pause() }
        case .toggle:
            if isPlaying { pause() } else { resume() }
        case .skipForward:
            skip(by: Self.skipInterval)
        case .skipBackward:
            skip(by: -Self.skipInterval)
        case .seek:
            if let seekTarget { seek(to: seekTarget) }
        }
    }

    private func updateNowPlaying() {
        // Only once this screen has played something: loading a file to
        // show its length must not put a card on the lock screen.
        guard !remoteTargets.isEmpty, let player else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
    }
}

extension RecordingPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false
            self.player?.currentTime = 0
            position = 0
            timer?.invalidate(); timer = nil
            updateNowPlaying()
        }
    }
}
