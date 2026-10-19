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
    // Observed so the button flips between "Download" and "Load" when a
    // download completes or a model is deleted while the sheet is open.
    @ObservedObject private var modelManager = ModelManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var chosen: AIModel = AIModel.recommendedDownloadModel
    @State private var isOnWiFi = true
    @State private var monitor: NWPathMonitor?

    private var appleIntelligenceReady: Bool {
        appState.engine.appleIntelligence.isAvailable
    }

    /// The chosen model is on disk already. This sheet is also where a model
    /// that failed to *load* sends the user, and offering "Download X · 1.8 GB"
    /// for files that are fully installed reads as "the app lost my download".
    private var chosenIsInstalled: Bool {
        modelManager.isModelDownloaded(chosen)
    }

    /// Models this device can run - the same gate as the picker and the
    /// load preflight (`AIModel.fitsThisDevice`). Not filtered by what is
    /// free at this instant: that hid models the picker offered, and a
    /// momentary shortage is reported at load time with what to do about it.
    private var choices: [AIModel] {
        AIModel.builtInModels.filter { !$0.isLegacy && $0.fitsThisDevice() }
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
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .onAppear {
            startWatchingNetwork()
            // Apple Intelligence may have been switched on, or finished
            // preparing, since launch; the "ready" card depends on it.
            appState.engine.appleIntelligence.refreshAvailability()
        }
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
            // Green on the icon only: green headline text on white is
            // about 2:1.
            Label {
                Text("You're ready to go")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.headline)
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
                    .foregroundStyle(Color.tintedBlue)
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
                Button {
                    dismiss()
                } label: {
                    // Sized inside the label: a frame on the button grew the
                    // layout but not the tappable area.
                    Text("Done")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        } else {
            modelChoiceSection
        }
    }

    private var modelChoiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.headline)

            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(choices) { model in
                modelRow(model)
            }

            if !isOnWiFi && !chosenIsInstalled {
                Label("You're not on Wi-Fi. This is a large download - it will wait until you are, unless you turn that off in Settings.",
                      systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                // With Apple Intelligence available the download is an add-on
                // for photos: text keeps going to the instant built-in model
                // (image questions already borrow the vision model). Selecting
                // the download here used to route every plain question to it
                // and lock the composer for the whole 1.8 GB. Someone who
                // already chose a downloaded model (and is here because it
                // failed to load) still gets the one they pick now.
                let keepsAppleIntelligence = appleIntelligenceReady
                    && appState.engine.selectedModel.backend == .appleIntelligence
                if !keepsAppleIntelligence {
                    appState.engine.select(chosen)
                }
                appState.engine.approveDownload(for: chosen)
                let engine = appState.engine
                let chat = appState.chatViewModel
                let model = chosen
                Task {
                    do {
                        // Weights only. Building a chat session here on top
                        // of the load left a stray session behind that the
                        // first real message then had to tear down.
                        try await engine.prepare(model)
                    } catch is CancellationError {
                        // The user stopped it; nothing to explain.
                    } catch {
                        // Never swallowed. A download or load that fails
                        // here used to leave only a "Set up your AI model"
                        // chip with no reason, which reads as "the app is
                        // broken" - and is exactly how it was described.
                        chat.errorBanner = .init(message: error.localizedDescription, canRetry: false)
                    }
                }
                dismiss()
            } label: {
                Label(
                    chosenIsInstalled
                        ? L10n.text("Load \(chosen.name)")
                        : L10n.text("Download \(chosen.name) · \(chosen.size)"),
                    systemImage: chosenIsInstalled ? "arrow.clockwise.circle.fill" : "arrow.down.circle.fill"
                )
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.blue.opacity(0.15)))
                    .foregroundStyle(Color.tintedBlue)
            }
            .buttonStyle(.plain)

            Button {
                dismiss()
            } label: {
                // Sized inside the label: a frame on the button grew the
                // layout but not the tappable area.
                Text("Not now")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var heading: String {
        if chosenIsInstalled { return L10n.text("Try Again") }
        return appleIntelligenceReady
            ? L10n.text("Want to analyze photos and documents?")
            : L10n.text("Download a model")
    }

    /// Why the user is here. A model that is installed but failed to load
    /// gets told so; everyone else gets the download pitch.
    private var explanation: String {
        if chosenIsInstalled {
            return L10n.text("\(chosen.name) is already on this device but couldn't be loaded last time. Try again, or choose another model.")
        }
        return appleIntelligenceReady
            ? L10n.text("Apple Intelligence handles text. A downloaded model adds image understanding and works in every language the app supports.")
            : L10n.text("This device doesn't have Apple Intelligence, so AiGoodbye needs one model downloaded before it can answer. It only happens once.")
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
                                .overlay(Capsule().strokeBorder(Color.blue, lineWidth: 1))
                                .foregroundStyle(.primary)
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
