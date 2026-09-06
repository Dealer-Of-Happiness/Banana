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
        let triggers = [
            "remember that ", "remember this: ", "remember: ",
            "keep in mind that ", "note that i ", "don't forget that "
        ]
        for trigger in triggers where lowered.hasPrefix(trigger) {
            let fact = String(text.dropFirst(trigger.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return fact.isEmpty ? nil : fact
        }
        return nil
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([MemoryFact].self, from: data) else { return }
        facts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(facts) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: Self.fileURL.path
        )
    }
}
