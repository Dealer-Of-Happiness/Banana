//
//  MemoryStore.swift
//  AIGoodbye
//
//  Private memory: facts the user chooses to save so the AI remembers them
//  across conversations ("I'm vegetarian", "I write Swift", "my daughter is
//  called Mia").
//
//  Everything here is opt-in, visible, editable and deletable by the user,
//  and never leaves the device - the whole point of doing this locally is
//  that a cloud assistant cannot make the same promise.
//

import Foundation
import Combine

struct MemoryFact: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var text: String
    var createdAt: Date = Date()
}

@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published private(set) var facts: [MemoryFact] = []
    /// Master switch. Off means nothing is stored or sent to the model.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "memory_enabled"
    private static let maxFacts = 50

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AiGoodbyeMemory", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = false // memory is worth restoring
            var mutable = dir
            try? mutable.setResourceValues(values)
        }
        return dir.appendingPathComponent("facts.json")
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        load()
    }

    // MARK: - CRUD

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !facts.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        facts.append(MemoryFact(text: String(trimmed.prefix(300))))
        if facts.count > Self.maxFacts {
            facts.removeFirst(facts.count - Self.maxFacts)
        }
        save()
    }

    func update(_ fact: MemoryFact, text: String) {
        guard let index = facts.firstIndex(where: { $0.id == fact.id }) else { return }
        facts[index].text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        save()
    }

    func delete(_ fact: MemoryFact) {
        facts.removeAll { $0.id == fact.id }
        save()
    }

    func deleteAll() {
        facts.removeAll()
        save()
    }

    /// Block of remembered facts for the system prompt, or empty.
    var promptBlock: String {
        guard isEnabled, !facts.isEmpty else { return "" }
        let list = facts.map { "- \($0.text)" }.joined(separator: "\n")
        return "Things the user has asked you to remember about them:\n\(list)"
    }

    // MARK: - Detecting "remember this"

    /// Recognizes an explicit request to remember something and returns the
    /// fact to store. Deliberately conservative: memory is only ever written
    /// when the user clearly asks for it.
    nonisolated static func requestedFact(in message: String) -> String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        for trigger in prefixTriggers where lowered.hasPrefix(trigger) {
            var fact = String(text.dropFirst(trigger.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            // "Note that I like tea" keeps its subject.
            if trigger == "note that i " { fact = "I " + fact }
            return fact.isEmpty ? nil : fact
        }
        for trigger in suffixTriggers where lowered.hasSuffix(trigger) {
            let fact = String(text.dropLast(trigger.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "、,，。"))
            return fact.isEmpty ? nil : fact
        }
        return nil
    }

    /// The phrases the Memory screen tells people to use, in every app
    /// language (the tip is translated, so the triggers must be too;
    /// English-only triggers made the feature dead in 12 of 13 languages).
    /// Lower-case; the English ones stay available in every language.
    nonisolated static let prefixTriggers: [String] = [
        // English
        "remember that ", "remember this: ", "remember: ",
        "keep in mind that ", "note that i ", "don't forget that ",
        // German
        "merk dir, dass ", "merke dir, dass ", "merk dir dass ", "merke dir dass ",
        // Spanish
        "recuerda que ", "acuérdate de que ",
        // French
        "retiens que ", "souviens-toi que ", "rappelle-toi que ",
        // Italian
        "ricorda che ", "ricordati che ",
        // Portuguese
        "lembre-se de que ", "lembre-se que ", "lembre que ",
        // Russian
        "запомни, что ", "запомни что ",
        // Ukrainian
        "запам'ятай, що ", "запам'ятай що ", "запам’ятай, що ", "запам’ятай що ",
        // Greek
        "θυμήσου ότι ", "να θυμάσαι ότι ",
        // Korean
        "기억해 줘: ", "기억해: ", "기억해줘: ",
        // Chinese (Simplified and Traditional)
        "记住：", "记住:", "记住，", "记住,", "請記住：", "請記住:", "記住：", "記住:", "記住，", "記住,"
    ]

    /// Verb-final languages put the request at the end.
    nonisolated static let suffixTriggers: [String] = [
        // Japanese
        "を覚えておいてください", "を覚えておいて", "を覚えておいてね", "を覚えて",
        // Korean
        "를 기억해 줘", "을 기억해 줘", "를 기억해줘", "을 기억해줘", "를 기억해", "을 기억해"
    ]

    // MARK: - Persistence

    /// True when the file exists but could not be read. Saving then is
    /// refused: writing the empty in-memory list over it would erase every
    /// fact the user ever saved.
    private(set) var loadFailed = false

    private func load() {
        guard FileManager.default.fileExists(atPath: Self.fileURL.path) else { return }
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([MemoryFact].self, from: data) else {
            loadFailed = true
            return
        }
        facts = decoded
    }

    private func save() {
        guard !loadFailed, let data = try? JSONEncoder().encode(facts) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        // Readable at launch after the first unlock: `.complete` kept the
        // file unreadable while the device was locked, which is exactly
        // when a background launch read it, decided the list was empty,
        // and could have overwritten it.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: Self.fileURL.path
        )
    }
}
