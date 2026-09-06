//
//  AddCustomModelView.swift
//  AIGoodbye
//
//  Add any MLX model from Hugging Face by name. The repo is checked first -
//  files, size, and whether this phone has the memory for it - so the user
//  finds out before a multi-gigabyte download, not after.
//

import SwiftUI

struct AddCustomModelView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var store = CustomModelStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var isChecking = false
    @State private var candidate: CustomModelSpec?
    @State private var errorMessage: String?
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                TextField("owner/model-name", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { check() }
                    .onChange(of: input) { _, _ in
                        candidate = nil
                        errorMessage = nil
                    }

                Button {
                    check()
                } label: {
                    HStack {
                        if isChecking { ProgressView().padding(.trailing, 6) }
                        Text(isChecking ? "Checking..." : "Check model")
                    }
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
            } header: {
                Text("Hugging Face model")
            } footer: {
                Text("Paste a model address such as mlx-community/Qwen3-VL-2B-Instruct-4bit. Only models converted for MLX will work; the mlx-community organization publishes thousands of them.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let candidate {
                Section {
                    LabeledContent(L10n.text("Model"), value: candidate.repoId)
                    LabeledContent(
                        L10n.text("Download size"),
                        value: ByteCountFormatter.string(fromByteCount: candidate.sizeBytes, countStyle: .file)
                    )
                    LabeledContent(
                        L10n.text("Memory needed"),
                        value: L10n.text("About \(AIModel.workingSetGB(forModelBytes: candidate.sizeBytes)) GB")
                    )
                    LabeledContent(
                        L10n.text("Images"),
                        value: candidate.supportsVision ? L10n.text("Supported") : L10n.text("Text only")
                    )

                    // Two buttons, not one. "Add and use" used to be the only
                    // option, so adding an untested community model silently
                    // replaced the model that was working - and if the new
                    // one then refused to load, every message failed.
                    Button {
                        store.add(candidate)
                        if let model = AIModel.model(withId: candidate.id) {
                            appState.engine.select(model)
                            appState.engine.approveDownload(for: model)
                        }
                        dismiss()
                    } label: {
                        Label("Add and use this model", systemImage: "plus.circle.fill")
                    }
                    .disabled(!store.canAddMore)

                    Button {
                        store.add(candidate)
                        dismiss()
                    } label: {
                        Label("Just add it", systemImage: "plus")
                    }
                    .disabled(!store.canAddMore)
                } header: {
                    Text("Found it")
                } footer: {
                    Text("Community models aren't tested by us: quality, speed and language support vary, and some won't load at all. You can remove it again at any time. The one-time download comes from Hugging Face; after that the model runs offline like every other.")
                }
            }

            if !store.canAddMore {
                Section {
                    Text("You can keep up to \(CustomModelStore.maximumCount) added models. Remove one first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(Text("Add a Model"))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { checkTask?.cancel() }
    }

    private func check() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let repoId = HuggingFaceValidator.normalize(text), store.contains(repoId: repoId) {
            errorMessage = ModelValidationError.alreadyAdded.errorDescription
            return
        }

        checkTask?.cancel()
        errorMessage = nil
        candidate = nil
        isChecking = true
        checkTask = Task {
            // Only the live check may clear the spinner: a superseded one
            // finishing late would re-enable the button mid-request.
            defer { if !Task.isCancelled { isChecking = false } }
            do {
                let spec = try await HuggingFaceValidator.validate(text)
                guard !Task.isCancelled else { return }
                candidate = spec
            } catch let error as ModelValidationError {
                guard !Task.isCancelled else { return }
                errorMessage = error.errorDescription
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = ModelValidationError.network.errorDescription
            }
        }
    }
}
