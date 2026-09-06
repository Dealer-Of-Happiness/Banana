//
//  VocabularyView.swift
//  AIGoodbye
//
//  Words the recognizer should get right: colleagues' names, product names,
//  medical or legal terms.
//
//  Speech models are measurably weakest on exactly these words, and they are
//  also the ones a reader notices immediately when a transcript gets them
//  wrong. This list is handed to the recognizer before every recording.
//

import SwiftUI

struct VocabularyView: View {
    @ObservedObject private var store = RecordingStore.shared
    @State private var newWord = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add a name or word", text: $newWord)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(trimmed.isEmpty)
                    .accessibilityLabel(Text("Add word"))
                }
            } footer: {
                Text("Names and unusual words are where transcription most often goes wrong. Anything you add here is given to the recognizer before each recording, and never leaves this device.")
            }

            if !store.customVocabulary.isEmpty {
                Section {
                    ForEach(store.customVocabulary, id: \.self) { word in
                        Text(word)
                    }
                    .onDelete { offsets in
                        // Map first: the offsets index the live array.
                        let doomed = offsets.map { store.customVocabulary[$0] }
                        store.customVocabulary.removeAll { doomed.contains($0) }
                    }
                } header: {
                    Text("Words")
                }
            }
        }
        .navigationTitle(Text("Get These Right"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var trimmed: String {
        newWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        let word = trimmed
        guard !word.isEmpty,
              !store.customVocabulary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame })
        else { return }
        store.customVocabulary.append(word)
        newWord = ""
        isFocused = true
    }
}
