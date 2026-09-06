//
//  MemoryView.swift
//  AIGoodbye
//
//  What the AI remembers about you - stored only on this device, and fully
//  under your control.
//

import SwiftUI

struct MemoryView: View {
    @ObservedObject private var store = MemoryStore.shared
    @EnvironmentObject var appState: AppState

    @State private var newFact = ""
    @State private var showDeleteAll = false

    var body: some View {
        List {
            Section {
                Toggle("Remember things about me", isOn: $store.isEnabled)
                    .onChange(of: store.isEnabled) { _, _ in
                        appState.engine.resetSessions()
                    }
            } footer: {
                Text("When on, the AI can use the notes below in every chat. They are stored only on this device and are never sent anywhere.")
            }

            Section {
                HStack(spacing: 8) {
                    TextField(L10n.text("Add something to remember..."), text: $newFact, axis: .vertical)
                        .lineLimit(1...3)
                    Button {
                        store.add(newFact)
                        newFact = ""
                        appState.engine.resetSessions()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(Text("Add memory"))
                }
            } header: {
                Text("Add")
            } footer: {
                Text("Tip: in any chat you can also write \"Remember that ...\" and it will be saved here.")
            }

            Section {
                if store.facts.isEmpty {
                    Text("Nothing remembered yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.facts) { fact in
                        Text(fact.text)
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { store.facts[$0] }
                        doomed.forEach(store.delete)
                        appState.engine.resetSessions()
                    }
                }
            } header: {
                Text("Remembered")
            }

            if !store.facts.isEmpty {
                Section {
                    Button("Forget Everything", role: .destructive) {
                        showDeleteAll = true
                    }
                }
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Forget everything?", isPresented: $showDeleteAll) {
            Button("Forget Everything", role: .destructive) {
                store.deleteAll()
                appState.engine.resetSessions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All remembered notes will be deleted from this device. This can't be undone.")
        }
    }
}
