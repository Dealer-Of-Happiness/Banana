//
//  PersonaStore.swift
//  AIGoodbye
//
//  Personas: saved instructions that change how the AI behaves ("Translator",
//  "Editor", "Explain simply"). Stored on the device only, like everything
//  else in this app.
//

import Foundation
import Combine

struct Persona: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var instructions: String
    var symbol: String          // SF Symbol name
    var isBuiltIn: Bool = false

    /// Built-in starting points. Localized at read time so they follow the
    /// in-app language.
    static var builtIns: [Persona] {
        [
            Persona(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                name: L10n.text("General Assistant"),
                instructions: "",
                symbol: "sparkles",
                isBuiltIn: true
            ),
            Persona(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!,
                name: L10n.text("Editor"),
                instructions: L10n.text("Act as a careful writing editor. Improve clarity, flow and grammar while preserving the author's voice. Show the improved text first, then briefly list what you changed."),
                symbol: "pencil.and.outline",
                isBuiltIn: true
            ),
            Persona(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!,
                name: L10n.text("Explain Simply"),
                instructions: L10n.text("Explain everything in plain, simple language a curious 12-year-old would understand. Use short sentences, concrete examples and analogies. Avoid jargon; when a technical term is unavoidable, define it immediately."),
                symbol: "lightbulb",
                isBuiltIn: true
            ),
            Persona(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!,
                name: L10n.text("Translator"),
                instructions: L10n.text("Act as a precise translator. When given text, translate it and nothing else. Preserve tone, formatting and names. If the target language is unclear, translate to the language the user is writing in."),
                symbol: "character.bubble",
                isBuiltIn: true
            ),
            Persona(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!,
                name: L10n.text("Brainstorm Partner"),
                instructions: L10n.text("Act as an energetic brainstorming partner. Offer several distinct options rather than one answer, build on the user's ideas, and end by asking which direction to explore further."),
                symbol: "bubbles.and.sparkles",
                isBuiltIn: true
            ),
            Persona(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A6")!,
                name: L10n.text("Code Helper"),
                instructions: L10n.text("Act as a pragmatic programming assistant. Give working code first with brief comments, then a short explanation. Point out edge cases and likely mistakes. Prefer clear, standard solutions over clever ones."),
                symbol: "chevron.left.forwardslash.chevron.right",
                isBuiltIn: true
            )
        ]
    }
}

@MainActor
final class PersonaStore: ObservableObject {
    static let shared = PersonaStore()

    @Published private(set) var custom: [Persona] = []
    /// nil means the plain General Assistant.
    @Published var selectedId: UUID? {
        didSet { UserDefaults.standard.set(selectedId?.uuidString, forKey: Self.selectedKey) }
    }

    private static let customKey = "personas_custom"
    private static let selectedKey = "persona_selected"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.customKey),
           let decoded = try? JSONDecoder().decode([Persona].self, from: data) {
            custom = decoded
        }
        if let raw = UserDefaults.standard.string(forKey: Self.selectedKey) {
            selectedId = UUID(uuidString: raw)
        }
    }

    var all: [Persona] { Persona.builtIns + custom }

    var selected: Persona? {
        guard let selectedId else { return nil }
        return all.first { $0.id == selectedId }
    }

    /// Instructions to append to the system prompt (empty when none).
    var activeInstructions: String {
        guard let persona = selected, !persona.instructions.isEmpty else { return "" }
        return persona.instructions
    }

    func add(_ persona: Persona) {
        custom.append(persona)
        save()
    }

    func update(_ persona: Persona) {
        guard let index = custom.firstIndex(where: { $0.id == persona.id }) else { return }
        custom[index] = persona
        save()
    }

    func delete(_ persona: Persona) {
        custom.removeAll { $0.id == persona.id }
        if selectedId == persona.id { selectedId = nil }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: Self.customKey)
        }
    }
}
