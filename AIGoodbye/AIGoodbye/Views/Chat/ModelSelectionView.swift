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
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
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
        } header: {
            Text("Downloadable")
        } footer: {
            Text("Models download once and then work fully offline. You can delete them anytime in Settings.")
        }
    }

    /// Picker choices minus the built-in entry, which has its own section.
    private var downloadableChoices: [AIModel] {
        appState.engine.availableChoices.filter { $0.backend != .appleIntelligence }
    }

    // MARK: - Rows

    private func modelRow(for model: AIModel) -> some View {
        let isSelected = appState.engine.selectedModel.id == model.id
        return Button {
            appState.engine.select(model)
            dismiss()
        } label: {
            ModelChoiceRow(model: model, isSelected: isSelected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: model, isSelected: isSelected))
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

    // MARK: - Accessibility

    private func accessibilityLabel(for model: AIModel, isSelected: Bool) -> String {
        var parts: [String] = [model.name, model.shortDescription, model.size, model.memoryRequired]
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

    private var isRecommended: Bool {
        model.id == AIModel.recommendedDownloadModel.id
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
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.headline)

                    if isRecommended {
                        Text("Recommended")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.blue))
                    }
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

                if model.backend == .mlx && !model.isDownloaded {
                    HStack(spacing: 4) {
                        Text("Not downloaded")
                            .foregroundStyle(.orange)
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

#Preview {
    ModelSelectionView()
        .environmentObject(AppState())
}
