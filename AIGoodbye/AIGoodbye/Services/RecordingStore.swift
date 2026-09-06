//
//  RecordingStore.swift
//  AIGoodbye
//
//  Private recordings: meetings, lectures, appointments and interviews,
//  transcribed and summarized entirely on this device.
//
//  This is the feature people who legally cannot use cloud transcription
//  have been waiting for - therapists, lawyers, doctors, journalists - so
//  the audio and the transcript must never leave the device, and deleting
//  one must really delete everything, including any copy the user pushed
//  into the Knowledge Library.
//

import Foundation
import Combine

struct Recording: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var duration: TimeInterval
    var transcript: String
    var summary: String?
    /// File name inside the recordings directory, when the audio was kept.
    var audioFileName: String?
    /// Language the speech was recognized in.
    var languageCode: String
    /// Set when the transcript was copied into the Knowledge Library, so
    /// deleting the recording can delete that copy too.
    var libraryDocumentId: UUID?
}

/// A recording in progress, written to disk every few seconds.
///
/// Without this, a crash, a jetsam kill or a force-quit at minute 179 of a
/// three-hour meeting lost every word: the transcript lived only in memory,
/// and the orphan sweep deleted the half-written audio on the next launch
/// before anyone could look at it.
nonisolated struct RecordingCheckpoint: Codable, Equatable {
    var id: UUID
    var startedAt: Date
    var transcript: String
    var duration: TimeInterval
    var audioFileName: String?
    var languageCode: String
}

@MainActor
final class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    @Published private(set) var recordings: [Recording] = []
    /// A recording that was in progress when the app last stopped running.
    @Published private(set) var pendingCheckpoint: RecordingCheckpoint?
    /// Set when the library couldn't be read or written. While this is set,
    /// nothing is saved - overwriting an unreadable file would destroy it.
    @Published private(set) var storageError: String?

    /// Keep the audio file after transcribing (off by default: the
    /// transcript is usually what matters, and audio is large and sensitive).
    @Published var keepsAudio: Bool {
        didSet { UserDefaults.standard.set(keepsAudio, forKey: Self.keepAudioKey) }
    }

    /// Names, jargon and product words the recognizer wouldn't otherwise
    /// know. Getting a colleague's name wrong is the error people notice
    /// most in a meeting transcript, and this is the only lever for it.
    @Published var customVocabulary: [String] {
        didSet { UserDefaults.standard.set(customVocabulary, forKey: Self.vocabularyKey) }
    }

    private static let keepAudioKey = "recordings_keep_audio"
    private static let vocabularyKey = "recordings_custom_vocabulary"
    private var loadFailed = false

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AiGoodbyeRecordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Applied every launch, not only on creation: a single failed call
        // must not silently break the promise made in the UI.
        if (try? dir.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != true {
            var mutable = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutable.setResourceValues(values)
        }
        return dir
    }()

    private static var indexURL: URL { directory.appendingPathComponent("recordings.json") }
    private static var checkpointURL: URL { directory.appendingPathComponent("in-progress.json") }

    private init() {
        keepsAudio = UserDefaults.standard.bool(forKey: Self.keepAudioKey)
        customVocabulary = UserDefaults.standard.stringArray(forKey: Self.vocabularyKey) ?? []
        load()
        loadCheckpoint()
        sweepOrphanedAudio()
    }

    static func audioURL(named name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    // MARK: - Loading

    private func load() {
        let url = Self.indexURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            recordings = try JSONDecoder().decode([Recording].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            // Never treat an unreadable library as an empty one: that would
            // show "No recordings yet" and then overwrite the file for good.
            loadFailed = true
            storageError = L10n.text("Your recordings couldn't be opened. Nothing has been deleted - reopen the app, and if this keeps happening please get in touch.")
        }
    }

    /// Delete audio files no recording refers to (left behind by a crash or
    /// a failed start). Sensitive audio must not linger unreferenced.
    ///
    /// The checkpoint's own file is exempt. It is the audio of a recording
    /// that was interrupted, and deleting it here was destroying the very
    /// thing recovery exists to save.
    private func sweepOrphanedAudio() {
        guard !loadFailed else { return }
        var known = Set(recordings.compactMap(\.audioFileName))
        if let name = pendingCheckpoint?.audioFileName { known.insert(name) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path) else { return }
        for name in names where name.hasSuffix(".m4a") && !known.contains(name) {
            try? FileManager.default.removeItem(at: Self.audioURL(named: name))
        }
    }

    // MARK: - Crash recovery

    private func loadCheckpoint() {
        let url = Self.checkpointURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let checkpoint = try? JSONDecoder().decode(RecordingCheckpoint.self, from: data) else { return }
        // Nothing worth recovering: no words and no audio.
        let hasAudio = checkpoint.audioFileName.map {
            FileManager.default.fileExists(atPath: Self.audioURL(named: $0).path)
        } ?? false
        guard !checkpoint.transcript.isEmpty || hasAudio else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        pendingCheckpoint = checkpoint
    }

    /// Save a snapshot of the recording in progress. Called every few
    /// seconds while recording; cheap, and atomic so a kill mid-write leaves
    /// the previous snapshot intact.
    func writeCheckpoint(_ checkpoint: RecordingCheckpoint) {
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? data.write(to: Self.checkpointURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    /// The recording finished normally (or was deliberately discarded).
    func clearCheckpoint() {
        pendingCheckpoint = nil
        try? FileManager.default.removeItem(at: Self.checkpointURL)
    }

    /// Turn a recovered checkpoint into a real recording.
    @discardableResult
    func recoverPendingCheckpoint(title: String) -> Bool {
        guard let checkpoint = pendingCheckpoint else { return false }
        let hasAudio = checkpoint.audioFileName.map {
            FileManager.default.fileExists(atPath: Self.audioURL(named: $0).path)
        } ?? false
        let recording = Recording(
            id: checkpoint.id,
            title: title,
            createdAt: checkpoint.startedAt,
            duration: checkpoint.duration,
            transcript: checkpoint.transcript,
            summary: nil,
            audioFileName: hasAudio ? checkpoint.audioFileName : nil,
            languageCode: checkpoint.languageCode
        )
        let saved = add(recording)
        if saved { clearCheckpoint() }
        return saved
    }

    /// Throw away a recovered recording the user doesn't want.
    func discardPendingCheckpoint() {
        if let name = pendingCheckpoint?.audioFileName {
            try? FileManager.default.removeItem(at: Self.audioURL(named: name))
        }
        clearCheckpoint()
    }

    // MARK: - Mutations

    /// Every mutation is refused while the library is unreadable: showing a
    /// recording that was never written, or deleting files the index can't
    /// record, both end in lost work.
    @discardableResult
    func add(_ recording: Recording) -> Bool {
        guard !loadFailed else { return false }
        // Idempotent: a retry after a failed save must not produce two rows
        // with the same id - the list would show duplicates and deleting one
        // would delete both.
        guard !recordings.contains(where: { $0.id == recording.id }) else {
            return save()
        }
        recordings.insert(recording, at: 0)
        guard save() else {
            // Rolled back. Leaving it in the published array made a recording
            // the user was told had failed appear in the list anyway, and the
            // next successful save from anywhere else then persisted it.
            recordings.removeAll { $0.id == recording.id }
            return false
        }
        return true
    }

    func update(_ recording: Recording) {
        guard !loadFailed,
              let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[index] = recording
        save()
    }

    /// Apply a change to the stored copy, so a slow background task can't
    /// overwrite an edit the user made in the meantime.
    func modify(id: UUID, _ change: (inout Recording) -> Void) {
        guard !loadFailed,
              let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        change(&recordings[index])
        save()
    }

    func delete(_ recording: Recording) {
        guard !loadFailed else { return }
        removeFiles(for: recording)
        recordings.removeAll { $0.id == recording.id }
        save()
    }

    func deleteAll() {
        guard !loadFailed else { return }
        for recording in recordings { removeFiles(for: recording) }
        recordings.removeAll()
        save()
    }

    /// Everything a recording owns: its audio, and the copy of its
    /// transcript in the Knowledge Library if one was made.
    private func removeFiles(for recording: Recording) {
        if let name = recording.audioFileName {
            try? FileManager.default.removeItem(at: Self.audioURL(named: name))
        }
        if let documentId = recording.libraryDocumentId,
           let document = KnowledgeLibrary.shared.documents.first(where: { $0.id == documentId }) {
            KnowledgeLibrary.shared.delete(document)
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard !loadFailed else { return false }
        do {
            let data = try JSONEncoder().encode(recordings)
            try data.write(to: Self.indexURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            storageError = nil
            return true
        } catch {
            storageError = L10n.text("Your recordings couldn't be saved. The device may be out of space.")
            return false
        }
    }
}
