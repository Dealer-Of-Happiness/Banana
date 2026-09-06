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
            PersonaEditor(persona: persona) { updated in
                store.update(updated)
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
                    .frame(width: 28)

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
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private let symbols = ["star", "sparkles", "pencil.and.outline", "lightbulb",
                           "character.bubble", "chevron.left.forwardslash.chevron.right",
                           "book", "briefcase", "heart", "graduationcap", "fork.knife", "airplane"]

    var body: some View {
        NavigationStack {
            Form {
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
                            .accessibilityLabel(Text(symbol))
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Icon")
                }
            }
            .navigationTitle("Persona")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(persona)
                        dismiss()
                    }
                    .disabled(persona.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
