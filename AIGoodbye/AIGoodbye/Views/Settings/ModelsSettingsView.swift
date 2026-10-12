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
    /// Space left on the device, read when the screen appears and after a
    /// delete - the question this screen exists to answer is "do I have room
    /// for that model?".
    @State private var freeBytes: Int64?

    var body: some View {
        List {
            storageSection
            modelsSection
            customSection
            builtInSection
        }
        // The Settings row that leads here says "Manage Storage"; a screen
        // titled differently reads as a wrong turn.
        .navigationTitle("Manage Storage")
        // Sizes come from cached values; refresh them once on appear rather
        // than walking gigabytes of directories on every render.
        .task {
            modelManager.refreshDiskState()
            freeBytes = Self.currentFreeBytes()
        }
        .onChange(of: modelManager.revision) { _, _ in
            freeBytes = Self.currentFreeBytes()
        }
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

            if let freeBytes {
                HStack {
                    Label("Free on this iPhone", systemImage: "externaldrive.badge.checkmark")
                    Spacer()
                    Text(AIModel.formattedBytes(freeBytes))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Storage")
        }
    }

    /// Built-in models worth a row here: ones this device can run, plus
    /// anything that occupies space (even a legacy or too-large model must
    /// stay deletable). A 6 GB phone used to list the 8B Pro it can never
    /// get, and everyone saw the retired Qwen2 model as "Not downloaded".
    private var listedBuiltInModels: [AIModel] {
        AIModel.builtInModels.filter { model in
            let hasFiles = modelManager.downloadedSizeBytes(for: model) > 0
            return hasFiles || (model.fitsThisDevice() && !model.isLegacy)
        }
    }

    private var modelsSection: some View {
        Section {
            ForEach(listedBuiltInModels) { model in
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
                let model = AIModel(custom: spec)
                modelRow(for: model)
                    // The Remove button was disabled while downloading, the
                    // swipe was not: removing mid-download orphaned the
                    // folder the transfer then refilled - gigabytes the
                    // app could no longer see or free.
                    .deleteDisabled(isBusy(for: model))
            }
            .onDelete { offsets in
                // Map first: removing shifts the indices underneath. Bounds
                // checked too - the array can change between the render that
                // produced these offsets and this callback.
                let doomed = offsets.compactMap { index in
                    customStore.specs.indices.contains(index) ? customStore.specs[index] : nil
                }
                for spec in doomed where !isBusy(for: AIModel(custom: spec)) {
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
        let isLoading = appState.engine.mlx.loadingModelId == model.id
        return VStack(alignment: .leading, spacing: 6) {
            modelSummary(for: model)
            // Below the summary rather than inside it: the summary is one
            // combined VoiceOver element, which would swallow the button.
            // Not for a model this device can never run: it is listed only
            // so its leftover files can be deleted.
            if isLoading || (!isDownloaded && model.fitsThisDevice()) {
                ModelDownloadControl(model: model, engine: appState.engine)
            }
        }
    }

    private func modelSummary(for model: AIModel) -> some View {
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
                    // be reclaimed. Colour on the icon only: orange caption
                    // text fails contrast in light mode.
                    Label {
                        Text("Partial download · \(onDiskSize(for: model))")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                } else {
                    Text("Not downloaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            if isDownloaded || bytesOnDisk > 0 {
                Button(role: .destructive) {
                    modelToDelete = model
                    showDeleteConfirmation = true
                } label: {
                    // Sized inside the label: a frame on the button itself
                    // grew the layout but not the tappable area, which stayed
                    // the height of one line of text.
                    Text(isDownloaded ? L10n.text("Delete") : L10n.text("Remove"))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isBusy(for: model))
                .accessibilityLabel("Delete \(model.name)")
            }
        }
        .padding(.vertical, 2)
    }

    /// True while the engine is downloading or preparing this model.
    ///
    /// Keyed on the model being loaded, not on the selection: a vision
    /// download borrowed by a photo while Apple Intelligence is selected, and
    /// the "Preparing" phase after the bytes landed, both had Delete enabled -
    /// and deleting then either reverted silently when the transfer finished
    /// or triggered a full, invisible re-download from the loader's retry.
    private func isBusy(for model: AIModel) -> Bool {
        appState.engine.mlx.loadingModelId == model.id
    }

    // MARK: - Helpers

    private func onDiskSize(for model: AIModel) -> String {
        AIModel.formattedBytes(modelManager.downloadedSizeBytes(for: model))
    }

    /// Off the cached disk state on purpose: it is one cheap volume query.
    private static func currentFreeBytes() -> Int64? {
        try? URL.documentsDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
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
