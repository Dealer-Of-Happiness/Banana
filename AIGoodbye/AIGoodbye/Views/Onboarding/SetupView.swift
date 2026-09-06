//
//  SetupView.swift
//  AIGoodbye
//
//  The first thing a new user sees after accepting the terms.
//
//  Before this existed, someone on a device without Apple Intelligence saw a
//  chat screen that looked completely ready, typed a question, and only then
//  got a sheet demanding a 1.8 GB download. This screen tells them where they
//  stand before they type anything, and either says "you're ready" or offers
//  the download with its real size and a Wi-Fi check.
//

import SwiftUI
import Network

struct SetupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var chosen: AIModel = AIModel.recommendedDownloadModel
    @State private var isOnWiFi = true
    @State private var monitor: NWPathMonitor?

    private var appleIntelligenceReady: Bool {
        appState.engine.appleIntelligence.isAvailable
    }

    /// Models this device can actually run.
    ///
    /// Filtered by the memory the app can really have, not by physical RAM -
    /// otherwise the button offers a download that `performLoad` will refuse
    /// the moment it starts, and the sheet just closes with nothing
    /// happening.
    private var choices: [AIModel] {
        AIModel.builtInModels.filter {
            !$0.isLegacy
                && $0.fitsThisDevice()
                && AIModel.workingSetGB(forModelBytes: $0.sizeBytes) <= DeviceCapability.usableMemoryGB
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if appleIntelligenceReady {
                        readyCard
                    }

                    downloadSection
                }
                .padding()
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Text("Set Up"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear(perform: startWatchingNetwork)
        .onDisappear {
            monitor?.cancel()
            monitor = nil
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.blue)
            Text("Choose how AiGoodbye thinks")
                .font(.title2.bold())
            Text("The AI runs on this device. Nothing you type is ever uploaded.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var readyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("You're ready to go", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("Apple Intelligence is built into this device, so you can start chatting straight away with no download at all.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                appState.engine.select(.appleIntelligence)
                dismiss()
            } label: {
                Text("Start chatting")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.blue.opacity(0.15)))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private var downloadSection: some View {
        if choices.isEmpty {
            // Nothing fits. Say so plainly rather than offering a button
            // that silently does nothing.
            VStack(alignment: .leading, spacing: 10) {
                Label("No model fits this device", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(appleIntelligenceReady
                     ? L10n.text("This device doesn't have enough free memory for a downloadable model, so image understanding isn't available here. Everything else works with Apple Intelligence.")
                     : L10n.text("This device doesn't have enough free memory to run an AI model. Closing other apps may help - reopen AiGoodbye afterwards."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Done") { dismiss() }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        } else {
            modelChoiceSection
        }
    }

    private var modelChoiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appleIntelligenceReady
                 ? L10n.text("Want to analyze photos and documents?")
                 : L10n.text("Download a model"))
                .font(.headline)

            Text(appleIntelligenceReady
                 ? L10n.text("Apple Intelligence handles text. A downloaded model adds image understanding and works in every language the app supports.")
                 : L10n.text("This device doesn't have Apple Intelligence, so AiGoodbye needs one model downloaded before it can answer. It only happens once."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(choices) { model in
                modelRow(model)
            }

            if !isOnWiFi {
                Label("You're not on Wi-Fi. This is a large download - it will wait until you are, unless you turn that off in Settings.",
                      systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                appState.engine.select(chosen)
                appState.engine.approveDownload(for: chosen)
                Task { try? await appState.engine.startConversation(model: chosen, history: []) }
                dismiss()
            } label: {
                Label("Download \(chosen.name) · \(chosen.size)", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.blue.opacity(0.15)))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)

            Button("Not now") { dismiss() }
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func modelRow(_ model: AIModel) -> some View {
        Button {
            chosen = model
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: chosen.id == model.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(.blue)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.subheadline.weight(.medium))
                        if model.id == AIModel.recommendedDownloadModel.id {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.blue.opacity(0.15)))
                                .foregroundStyle(.blue)
                        }
                    }
                    Text(model.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(model.size) · \(model.memoryRequired)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen.id == model.id ? [.isSelected] : [])
    }

    // MARK: - Network

    private func startWatchingNetwork() {
        // onAppear can fire more than once; a second monitor would leak the
        // first along with its queue and callback.
        monitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in
                isOnWiFi = !path.isExpensive && path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "aig.setup.network"))
        self.monitor = monitor
        // Seed from the current path, with the same test as the handler, so
        // "no network at all" doesn't render as "on Wi-Fi".
        let path = monitor.currentPath
        isOnWiFi = !path.isExpensive && path.status == .satisfied
    }
}
