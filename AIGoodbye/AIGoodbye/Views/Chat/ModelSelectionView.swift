//
//  ModelSelectionView.swift
//  AIGoodbye
//
//  Sheet for choosing the AI engine: built-in Apple Intelligence or a
//  downloadable on-device model.
//

import SwiftUI

struct ModelSelectionView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var modelManager = ModelManager.shared
    @Environment(\.dismiss) private var dismiss
    /// Lines the download control up with the row text, past the checkmark
    /// column; scaled so it stays aligned at large text sizes.
    @ScaledMetric(relativeTo: .body) private var checkmarkIndent: CGFloat = 29
    /// Rows whose full description is open.
    @State private var expandedIds: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                builtInSection
                downloadableSection
            }
            .navigationTitle("Choose AI Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Icon and title: iPhone Duo shows only icons in its
                    // vertical bar, so a text-only Done would not appear.
                    Button("Done", systemImage: "checkmark") {
                        dismiss()
                    }
                }
            }
        }
        // The unavailable row tells people to turn Apple Intelligence on in
        // Settings; when they come back having done it, the row must say so.
        // (A flip to available also moves a selection that could not answer
        // yet - see `ChatEngine.adoptAppleIntelligenceIfNothingDownloaded`.)
        .onAppear { appState.engine.appleIntelligence.refreshAvailability() }
    }

    // MARK: - Sections

    private var builtInSection: some View {
        Section {
            if appState.engine.appleIntelligence.isAvailable {
                modelRow(for: AIModel.appleIntelligence)
            } else {
                unavailableRow
            }
        } header: {
            Text("Built In")
        }
    }

    private var downloadableSection: some View {
        Section {
            ForEach(downloadableChoices) { model in
                modelRow(for: model)
            }

            // Where people look for more models; it used to live only under
            // Settings > Manage Storage > Your Models.
            NavigationLink {
                AddCustomModelView()
            } label: {
                Label("Add a model from Hugging Face", systemImage: "plus.circle")
            }
        } header: {
            Text("Downloadable")
        } footer: {
            Text("Models download once and then work fully offline. You can delete them anytime in Settings.")
        }
    }

    /// Every downloadable model, including the ones too large for this
    /// device - shown disabled with the reason, so nobody goes looking for
    /// the Pro model the store page mentions. Legacy models only when they
    /// are still on disk.
    private var downloadableChoices: [AIModel] {
        let models = AIModel.allModels.filter { !$0.isLegacy || $0.isDownloaded }
        // The Recommended model first: on a 12 GB phone the catalog order
        // put the 8B Pro above it, so the first thing offered was the
        // slowest, largest download.
        // Then everything this device can run, then the ones it can't: with
        // ten models, a 4 GB phone would otherwise scroll past a column of
        // greyed-out 12 GB models to reach its own.
        let recommendedId = AIModel.recommendedDownloadModel.id
        let others = models.filter { $0.id != recommendedId }
        return models.filter { $0.id == recommendedId }
            + others.filter { $0.fitsThisDevice() }
            + others.filter { !$0.fitsThisDevice() }
    }

    // MARK: - Rows

    private func modelRow(for model: AIModel) -> some View {
        let isSelected = appState.engine.selectedModel.id == model.id
        let fits = model.fitsThisDevice()
        let isExpanded = expandedIds.contains(model.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button {
                    appState.engine.select(model)
                    dismiss()
                } label: {
                    ModelChoiceRow(model: model, isSelected: isSelected, fits: fits, notice: notice(for: model))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!fits)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: model, isSelected: isSelected, fits: fits))

                // The catalog's long description ("Requires a phone with
                // 12 GB of RAM... slower than the 2B model") is the only
                // place "Pro" is explained; it was translated and never shown.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded { expandedIds.remove(model.id) } else { expandedIds.insert(model.id) }
                    }
                } label: {
                    Image(systemName: isExpanded ? "info.circle.fill" : "info.circle")
                        .foregroundStyle(.blue)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Details"))
                .accessibilityAddTraits(isExpanded ? [.isSelected] : [])
            }

            if isExpanded {
                Text(model.fullDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, checkmarkIndent)
            }

            // A sibling of the row's button, not inside it: a button nested
            // in another button's label fires both.
            if fits, model.backend == .mlx,
               !model.isDownloaded || appState.engine.mlx.loadingModelId == model.id {
                ModelDownloadControl(model: model, engine: appState.engine)
                    .padding(.leading, checkmarkIndent)
            }
        }
    }

    /// Shown when Apple Intelligence is not usable on this device. Not tappable.
    private var unavailableRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Intelligence")
                    .font(.headline)
                Text(unavailabilityReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Apple Intelligence, unavailable. \(unavailabilityReason)")
    }

    private var unavailabilityReason: String {
        if case .unavailable(let reason) = appState.engine.appleIntelligence.availability {
            return reason
        }
        return ""
    }

    /// A limitation worth knowing before choosing: Apple Intelligence does
    /// not speak every language the app does.
    private func notice(for model: AIModel) -> String? {
        guard model.backend == .appleIntelligence,
              let language = appState.engine.appleIntelligence.unsupportedLanguageName else { return nil }
        return L10n.text("Doesn't support \(language)")
    }

    // MARK: - Accessibility

    private func accessibilityLabel(for model: AIModel, isSelected: Bool, fits: Bool) -> String {
        var parts: [String] = [model.name, model.shortDescription, model.size, model.memoryRequired]
        if let notice = notice(for: model) {
            parts.append(notice)
        }
        if !fits {
            parts.append(L10n.text("Too large for this iPhone"))
            return parts.joined(separator: ", ")
        }
        if model.id == AIModel.recommendedDownloadModel.id {
            parts.append(L10n.text("Recommended"))
        }
        if isSelected {
            parts.append(L10n.text("Currently selected"))
        }
        if model.backend == .mlx {
            parts.append(model.isDownloaded
                ? L10n.text("Downloaded")
                : L10n.text("Not downloaded") + ", " + L10n.text("Downloads on first use"))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Model Choice Row

private struct ModelChoiceRow: View {
    let model: AIModel
    let isSelected: Bool
    /// False for a model this device can never run: shown, but not choosable.
    var fits: Bool = true
    var notice: String?

    private var isRecommended: Bool {
        model.id == AIModel.recommendedDownloadModel.id
    }

    private var nameText: some View {
        Text(model.name)
            .font(.headline)
            .foregroundStyle(fits ? Color.primary : Color.secondary)
    }

    private var recommendedBadge: some View {
        Text("Recommended")
            .font(.caption2.bold())
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.blue.opacity(0.15)))
            .overlay(Capsule().strokeBorder(Color.blue, lineWidth: 1))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Selection indicator on the leading edge. Kept in the layout even
            // when hidden so all rows align.
            Image(systemName: "checkmark")
                .font(.body.bold())
                .foregroundStyle(.blue)
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                // Name and badge on one line when they fit; otherwise the
                // badge goes underneath, rather than squeezing a name like
                // "Qwen3.5 Vision 2B" onto two lines beside it.
                if isRecommended {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            nameText
                            recommendedBadge
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            nameText
                            recommendedBadge
                        }
                    }
                } else {
                    nameText
                }

                Text(model.shortDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(model.size) - \(model.memoryRequired)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    ForEach(model.capabilities, id: \.self) { capability in
                        Image(systemName: capability.icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityHidden(true)

                if let notice {
                    Label {
                        Text(notice)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }

                if !fits {
                    Label {
                        Text("Too large for this iPhone")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "nosign")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                } else if model.backend == .mlx && !model.isDownloaded {
                    // Colour on the icon only: orange caption text on white
                    // is about 2:1, unreadable for low vision.
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.orange)
                        Text("Not downloaded")
                            .foregroundStyle(.secondary)
                        Text("Downloads on first use")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }

            Spacer(minLength: 0)

            if model.isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Download Control

/// "Download" for a model that is not on this device yet, with its progress
/// and any failure shown in place. Never changes the selection: this is for
/// fetching a model ahead of time - the vision model before a trip, the Pro
/// model on home Wi-Fi - not for switching to it. Used by the picker and by
/// the storage screen.
struct ModelDownloadControl: View {
    let model: AIModel
    @ObservedObject var engine: ChatEngine
    @State private var errorMessage: String?

    private var mlx: MLXService { engine.mlx }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if mlx.loadingModelId == model.id {
                progress
            } else if !model.isDownloaded {
                Button {
                    startDownload()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                // One model moves at a time: starting a load now would cancel
                // whatever is loading, or pull the weights out from under an
                // answer being written.
                .disabled(mlx.isBusy)
            }

            if let errorMessage {
                Label {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        if mlx.isPreparingModel && !mlx.isDownloading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing \(model.name)...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: mlx.downloadProgress)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if mlx.isWaitingForWiFi {
                    Text("Waiting for Wi-Fi. Connect to Wi-Fi, or turn off \"Download over Wi-Fi only\" in Settings.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if mlx.isDownloadStalled {
                    Text("Download stalled. Check your internet connection.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var progressText: String {
        if mlx.totalDownloadBytes > 1, mlx.downloadedBytes > 0 {
            let done = AIModel.formattedBytes(mlx.downloadedBytes)
            let total = AIModel.formattedBytes(mlx.totalDownloadBytes)
            return L10n.text("Downloading \(model.name) · \(done) of \(total)")
        }
        return L10n.text("Downloading...")
    }

    private func startDownload() {
        errorMessage = nil
        let engine = self.engine
        let model = self.model
        engine.approveDownload(for: model)
        Task {
            do {
                try await engine.prepare(model)
                // Fetched ahead of time, not chosen: don't keep gigabytes of
                // weights resident for a model nothing is using.
                engine.releaseBorrowedVisionModel(model)
            } catch is CancellationError {
                // Stopped on purpose; nothing to explain.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    ModelSelectionView()
        .environmentObject(AppState())
}
