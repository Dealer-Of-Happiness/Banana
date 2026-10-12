//
//  TextEntrySheet.swift
//  AIGoodbye
//
//  A one-field prompt: a name for a new folder, a new title for a chat or a
//  recording.
//

import SwiftUI

/// A sheet rather than an alert with a text field, deliberately.
///
/// On iOS 27, once the chat composer had shown the keyboard, taps on an
/// alert's buttons stopped registering while the alert's own text field was
/// editing - Return still worked, the buttons did not. New Folder's Create
/// simply did nothing, and so did every Rename. A sheet's toolbar buttons are
/// not affected, and the field gets room for long names and large text.
struct TextEntrySheet: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    let placeholder: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    let onCommit: (String) -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        placeholder: LocalizedStringKey,
        actionTitle: LocalizedStringKey,
        initialText: String = "",
        onCommit: @escaping (String) -> Void
    ) {
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.actionTitle = actionTitle
        self.onCommit = onCommit
        _text = State(initialValue: initialText)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(placeholder, text: $text)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(commit)
                } footer: {
                    if let message {
                        Text(message)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Toolbar items with symbols: on iPhone Duo the system moves
                // them into the bar beside the display.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, systemImage: "checkmark", action: commit)
                        .disabled(trimmed.isEmpty)
                }
            }
        }
        // Short, like the alert it replaces; full height when the text is
        // large enough that a short sheet would clip the field.
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(240), .large])
        .onAppear { isFocused = true }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}
