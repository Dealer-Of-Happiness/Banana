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
    @ObservedObject private var customStore = CustomModelStore.shared
    @EnvironmentObject var appState: AppState

    @State private var showDeleteConfirmation = false
    @State private var modelToDelete: AIModel?

    var body: some View {
        List {
            storageSection
            modelsSection
            customSection
            builtInSection
        }
        .navigationTitle("AI Models")
        // Sizes come from cached values; refresh them once on appear rather
        // than walking gigabytes of directories on every render.
        .task { modelManager.refreshDiskState() }
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
            ForEach(AIModel.builtInModels) { model in
                modelRow(for: model)
            }
        } header: {
            Text("Downloadable Models")
        } footer: {
            Text("Deleting a model frees space immediately. It will be downloaded again the next time you use it.")
        }
    }

    private var customSection: some View {
        Section {
            // Rows and specs must line up one to one, or a swipe could
            // delete the wrong model.
            ForEach(customStore.specs) { spec in
                modelRow(for: AIModel(custom: spec))
            }
            .onDelete { offsets in
                // Map first: removing shifts the indices underneath. Bounds
                // checked too - the array can change between the render that
                // produced these offsets and this callback.
                let doomed = offsets.compactMap { index in
                    customStore.specs.indices.contains(index) ? customStore.specs[index] : nil
                }
                for spec in doomed {
                    customStore.remove(spec, engine: appState.engine)
                }
            }

            NavigationLink {
                AddCustomModelView()
            } label: {
                Label("Add a model from Hugging Face", systemImage: "plus.circle")
            }
        } header: {
            Text("Your Models")
        } footer: {
            Text("Run any MLX model from Hugging Face on your device. Community models aren't tested by us, and swipe to remove deletes the download too.")
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
                // Deleting the directory while the prefetcher is writing into
                // it leaves a half-model that later looks complete.
                let isBusy = appState.engine.mlx.isDownloading
                    && appState.engine.selectedModel.id == model.id
                Button(isDownloaded ? "Delete" : "Remove", role: .destructive) {
                    modelToDelete = model
                    showDeleteConfirmation = true
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .disabled(isBusy)
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
