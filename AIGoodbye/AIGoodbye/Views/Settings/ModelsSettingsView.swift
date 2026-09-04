//
//  ModelsSettingsView.swift
//  AIGoodbye
//
//  Storage management for downloaded AI models: see what is on disk,
//  how much space it uses, and delete models to free space.
//

import SwiftUI

struct ModelsSettingsView: View {
    @ObservedObject var modelManager = ModelManager.shared
    @EnvironmentObject var appState: AppState

    @State private var showDeleteConfirmation = false
    @State private var modelToDelete: AIModel?

    var body: some View {
        List {
            storageSection
            modelsSection
            builtInSection
        }
        .navigationTitle("AI Models")
        .alert(
            deleteDialogTitle,
            isPresented: $showDeleteConfirmation,
            presenting: modelToDelete
        ) { model in
            Button("Delete", role: .destructive) {
                modelManager.deleteModel(model)
                appState.engine.modelWasDeleted(model)
                modelToDelete = nil
            }

            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
        } message: { model in
            Text(deleteDialogMessage(for: model))
        }
    }

    // MARK: - Sections

    private var storageSection: some View {
        Section {
            HStack {
                Label("Total Space Used", systemImage: "internaldrive")
                Spacer()
                Text(modelManager.formattedTotalSize)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Storage")
        }
    }

    private var modelsSection: some View {
        Section {
            ForEach(AIModel.allModels) { model in
                modelRow(for: model)
            }
        } header: {
            Text("Downloadable Models")
        } footer: {
            Text("Deleting a model frees space immediately. It will be downloaded again the next time you use it.")
        }
    }

    private var builtInSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Intelligence")
                    .font(.headline)
                Text("Managed by iOS - uses no app storage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        } header: {
            Text("Built In")
        }
    }

    // MARK: - Rows

    private func modelRow(for model: AIModel) -> some View {
        let isDownloaded = modelManager.isModelDownloaded(model)
        let bytesOnDisk = modelManager.downloadedSizeBytes(for: model)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.headline)

                Text(model.shortDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isDownloaded {
                    Text(onDiskSize(for: model))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if bytesOnDisk > 0 {
                    // Interrupted download: show what it occupies so it can
                    // be reclaimed.
                    Text("Partial download · \(onDiskSize(for: model))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Not downloaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            if isDownloaded || bytesOnDisk > 0 {
                Button(isDownloaded ? "Delete" : "Remove", role: .destructive) {
                    modelToDelete = model
                    showDeleteConfirmation = true
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .accessibilityLabel("Delete \(model.name)")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func onDiskSize(for model: AIModel) -> String {
        ByteCountFormatter.string(
            fromByteCount: modelManager.downloadedSizeBytes(for: model),
            countStyle: .file
        )
    }

    private var deleteDialogTitle: String {
        if let model = modelToDelete {
            return L10n.text("Delete \(model.name)?")
        }
        return L10n.text("Delete Model?")
    }

    private func deleteDialogMessage(for model: AIModel) -> String {
        let size = onDiskSize(for: model)
        if appState.engine.selectedModel.id == model.id {
            return L10n.text("This frees \(size) right away. \(model.name) is your current model, so it will be re-downloaded the next time you use it.")
        }
        return L10n.text("This frees \(size) right away. You can download \(model.name) again anytime.")
    }
}

#Preview {
    NavigationStack {
        ModelsSettingsView()
    }
    .environmentObject(AppState())
}
