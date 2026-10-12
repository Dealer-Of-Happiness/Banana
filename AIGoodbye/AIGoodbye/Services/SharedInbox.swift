//
//  SharedInbox.swift
//  AIGoodbye
//
//  Handoff between the share extension / widgets and the main app.
//
//  A share extension gets very little memory - far too little to run a
//  language model - so it never does inference. It writes what the user
//  shared into the App Group container and opens the app, which picks it up
//  here. Nothing is uploaded; the handoff is a file on the same device.
//

import Foundation

enum SharedInbox {

    static let appGroup = "group.com.aigoodbye.AIGoodbye"
    static let urlScheme = "aigoodbye"

    struct Item: Codable {
        enum Kind: String, Codable { case text, url, file }
        var kind: Kind
        var text: String?
        /// File name inside the shared container (for `.file`).
        var fileName: String?
        var displayName: String?
        var createdAt: Date = Date()
    }

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    private static var inboxURL: URL? {
        guard let container = containerURL else { return nil }
        let dir = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var pendingURL: URL? {
        inboxURL?.appendingPathComponent("pending.json")
    }

    // MARK: - Writing (extension side)

    /// Largest file the app will import; the same cap as its document
    /// picker, applied here so the copy is never made.
    static let maxFileBytes: Int64 = 25 * 1024 * 1024

    static func write(_ item: Item) {
        guard let pendingURL, let data = try? JSONEncoder().encode(item) else { return }
        try? data.write(to: pendingURL, options: .atomic)
        // The shared text itself lives in this file; protect it like the
        // copied files.
        protect(pendingURL)
    }

    /// Copy a shared file into the group container and return its name.
    static func copyIntoContainer(_ source: URL) -> String? {
        guard let inboxURL else { return nil }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        if let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(size) > maxFileBytes {
            return nil
        }

        let name = UUID().uuidString + "-" + source.lastPathComponent
        let destination = inboxURL.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            protect(destination)
            return name
        } catch {
            return nil
        }
    }

    /// Write raw bytes (a shared image, say) into the group container.
    static func writeIntoContainer(_ data: Data, suggestedName: String) -> String? {
        guard let inboxURL, Int64(data.count) <= maxFileBytes else { return nil }
        let name = UUID().uuidString + "-" + suggestedName
        let destination = inboxURL.appendingPathComponent(name)
        do {
            try data.write(to: destination, options: .atomic)
            protect(destination)
            return name
        } catch {
            return nil
        }
    }

    /// Encrypt handed-over content at rest while the device is locked.
    private static func protect(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Reading (app side)

    /// Takes the pending item, if any, and clears it.
    static func takePending() -> Item? {
        guard let pendingURL,
              let data = try? Data(contentsOf: pendingURL),
              let item = try? JSONDecoder().decode(Item.self, from: data) else { return nil }
        try? FileManager.default.removeItem(at: pendingURL)
        return item
    }

    static func fileURL(named name: String) -> URL? {
        inboxURL?.appendingPathComponent(name)
    }

    static func cleanUp(fileName: String?) {
        guard let fileName, let url = fileURL(named: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Remove leftovers from shares that were never opened, so copies of the
    /// user's files don't accumulate in the shared container.
    static func sweepStaleFiles(olderThan age: TimeInterval = 60 * 60 * 24) {
        guard let inboxURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: inboxURL.path) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for name in names where name != "pending.json" {
            let url = inboxURL.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// The screen a Control Center control, the Action Button or an
/// open-the-app intent asked for, handed to the app through App Group
/// defaults. A control's action is an intent, and that intent may run in
/// the widget extension rather than the app, so a shared value is the one
/// channel both sides see. Lives here because this file is compiled into
/// the app and both extensions.
///
/// Route names are the deep-link hosts: "voice", "camera", "translate",
/// "describe", "recorder", "new".
enum WidgetLaunchBridge {
    private static let key = "launch_route"
    /// Written by the voice-only control in 3.5 and earlier. An update
    /// replaces app and extension together, so this can only be a tap made
    /// just before the update; it is honoured once and then gone.
    private static let legacyVoiceKey = "launch_into_voice"

    static func requestLaunch(route: String) {
        UserDefaults(suiteName: SharedInbox.appGroup)?.set(route, forKey: key)
    }

    /// Takes the requested route, if any, and clears it.
    static func consumeLaunchRoute() -> String? {
        guard let defaults = UserDefaults(suiteName: SharedInbox.appGroup) else { return nil }
        if let route = defaults.string(forKey: key) {
            defaults.removeObject(forKey: key)
            return route
        }
        if defaults.bool(forKey: legacyVoiceKey) {
            defaults.removeObject(forKey: legacyVoiceKey)
            return "voice"
        }
        return nil
    }
}
