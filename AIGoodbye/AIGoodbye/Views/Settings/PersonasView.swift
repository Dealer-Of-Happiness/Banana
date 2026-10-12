//
//  PersonasView.swift
//  AIGoodbye
//
//  Choose how the AI behaves, and create your own personas.
//

import SwiftUI

struct PersonasView: View {
    @ObservedObject private var store = PersonaStore.shared
    @EnvironmentObject var appState: AppState

    @State private var editing: Persona?
    @State private var isCreating = false
    /// Icon column width, scaled with Dynamic Type so large icons are not
    /// clipped and the names stay aligned.
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    var body: some View {
        List {
            Section {
                ForEach(store.all) { persona in
                    row(for: persona)
                        .deleteDisabled(persona.isBuiltIn)
                }
                .onDelete { offsets in
                    // Resolve every element BEFORE deleting: deleting shifts
                    // the indices of the ones that follow.
                    let doomed = offsets.map { store.all[$0] }.filter { !$0.isBuiltIn }
                    doomed.forEach(store.delete)
                    appState.engine.resetSessions()
                }
            } header: {
                Text("Personas")
            } footer: {
                Text("A persona changes how the AI answers. Your choice applies to new messages in every chat.")
            }

            Section {
                Button {
                    isCreating = true
                } label: {
                    Label("Create Persona", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("Personas")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isCreating) {
            PersonaEditor(persona: Persona(name: "", instructions: "", symbol: "star")) { new in
                store.add(new)
                store.selectedId = new.id
                appState.engine.resetSessions()
            }
        }
        .sheet(item: $editing) { persona in
            PersonaEditor(persona: persona) { saved in
                if store.custom.contains(where: { $0.id == saved.id }) {
                    store.update(saved)
                } else {
                    // A copy of a built-in: new, and chosen, like a created one.
                    store.add(saved)
                    store.selectedId = saved.id
                }
                appState.engine.resetSessions()
            }
        }
    }

    private func row(for persona: Persona) -> some View {
        Button {
            // Tapping the General Assistant clears the persona.
            store.selectedId = (persona.instructions.isEmpty && persona.isBuiltIn) ? nil : persona.id
            appState.engine.resetSessions()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: persona.symbol)
                    .font(.body)
                    .foregroundStyle(.blue)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(persona.name)
                        .foregroundStyle(.primary)
                    if !persona.instructions.isEmpty {
                        Text(persona.instructions)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                if isSelected(persona) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                }

                if !persona.isBuiltIn {
                    Button {
                        editing = persona
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Edit persona"))
                } else if !persona.instructions.isEmpty {
                    // Built-ins open read-only: the row shows two lines of
                    // their instructions, and the full text is the only way
                    // to know what a persona will do - or to start a copy.
                    Button {
                        editing = persona
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("View persona"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The checkmark is drawn, not spoken; say "selected" instead.
        .accessibilityAddTraits(isSelected(persona) ? [.isSelected] : [])
    }

    private func isSelected(_ persona: Persona) -> Bool {
        if store.selectedId == nil {
            return persona.isBuiltIn && persona.instructions.isEmpty
        }
        return store.selectedId == persona.id
    }
}

// MARK: - Editor

private struct PersonaEditor: View {
    @State var persona: Persona
    let onSave: (Persona) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Built-ins are shown, not edited; "Make a Copy" swaps in an editable
    /// custom copy, which Save then adds.
    private var isReadOnly: Bool { persona.isBuiltIn }

    private let symbols = ["star", "sparkles", "pencil.and.outline", "lightbulb",
                           "character.bubble", "chevron.left.forwardslash.chevron.right",
                           "book", "briefcase", "heart", "graduationcap", "fork.knife", "airplane"]

    /// What VoiceOver calls each icon, in the app language. SF Symbol names
    /// are English identifiers ("chevron left forwardslash chevron right").
    private static let symbolNames: [String: LocalizedStringKey] = [
        "star": "Star",
        "sparkles": "Sparkles",
        "pencil.and.outline": "Pencil",
        "lightbulb": "Light Bulb",
        "character.bubble": "Speech Bubble",
        "chevron.left.forwardslash.chevron.right": "Code",
        "book": "Book",
        "briefcase": "Briefcase",
        "heart": "Heart",
        "graduationcap": "Graduation Cap",
        "fork.knife": "Food",
        "airplane": "Airplane"
    ]

    private func symbolName(_ symbol: String) -> Text {
        if let key = Self.symbolNames[symbol] { return Text(key) }
        return Text(verbatim: symbol.replacingOccurrences(of: ".", with: " "))
    }

    var body: some View {
        NavigationStack {
            Form {
                if isReadOnly {
                    readOnlySections
                } else {
                    editableSections
                }
            }
            .navigationTitle("Persona")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isReadOnly {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Make a Copy", systemImage: "plus.square.on.square") {
                            persona = Persona(
                                name: persona.name,
                                instructions: persona.instructions,
                                symbol: persona.symbol
                            )
                        }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", systemImage: "checkmark") {
                            onSave(persona)
                            dismiss()
                        }
                        .disabled(persona.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var readOnlySections: some View {
        Section {
            Label {
                Text(persona.name)
            } icon: {
                Image(systemName: persona.symbol)
                    .foregroundStyle(.blue)
            }
        } header: {
            Text("Name")
        }

        Section {
            Text(persona.instructions)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Instructions")
        } footer: {
            Text("Built-in personas can't be changed. Make a copy to adjust one.")
        }
    }

    @ViewBuilder
    private var editableSections: some View {
        Section {
            TextField(L10n.text("Name"), text: $persona.name)
        } header: {
            Text("Name")
        }

        Section {
            TextField(
                L10n.text("Describe how the AI should behave..."),
                text: $persona.instructions,
                axis: .vertical
            )
            .lineLimit(4...10)
        } header: {
            Text("Instructions")
        } footer: {
            Text("Written in the AI's own instructions. For example: answer only in bullet points, or always reply in formal Japanese.")
        }

        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 50))], spacing: 12) {
                ForEach(symbols, id: \.self) { symbol in
                    Button {
                        persona.symbol = symbol
                    } label: {
                        Image(systemName: symbol)
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(persona.symbol == symbol ? Color.blue.opacity(0.2) : Color(.systemGray6))
                            )
                    }
                    .buttonStyle(.plain)
                    // A translated name, not the symbol's identifier, and
                    // VoiceOver learns which one is chosen.
                    .accessibilityLabel(symbolName(symbol))
                    .accessibilityAddTraits(persona.symbol == symbol ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Icon")
        }
    }
}
