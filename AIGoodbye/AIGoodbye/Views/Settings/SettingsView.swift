//
//  SettingsView.swift
//  AIGoodbye
//
//  Settings screen: model choice, AI behavior, feedback, privacy, and data.
//  Presented by SideMenuView inside a NavigationStack sheet.
//

import SwiftUI
import UIKit
import AVFoundation
import AppIntents
import Combine

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showModelPicker = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            ModelSection(engine: appState.engine, settings: appState.settings, showModelPicker: $showModelPicker)
            PersonalizationSection()
            LanguageSection(settings: appState.settings)
            BehaviorSection(settings: appState.settings, engine: appState.engine)
            SpeechSection(settings: appState.settings)
            SiriSection()
            FeedbackSection(settings: appState.settings)
            PrivacySection()
            DataSection()
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // Every other sheet in the app has one; this is the deepest screen
        // and the only one that could be left by swipe alone.
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") { dismiss() }
            }
        }
        // Presented from the Form level: presenting from a Section inside an
        // already-presented sheet can grab the wrong presentation context and
        // dismiss the whole Settings sheet on some devices.
        .sheet(isPresented: $showModelPicker) {
            ModelSelectionView()
                .environmentObject(appState)
        }
    }
}

// MARK: - AI Model Section

private struct ModelSection: View {
    @ObservedObject var engine: ChatEngine
    @EnvironmentObject var appState: AppState
    @ObservedObject var settings: SettingsManager
    @Binding var showModelPicker: Bool

    var body: some View {
        Section {
            Button {
                showModelPicker = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.selectedModel.name)
                            .foregroundStyle(.primary)

                        Text(engine.selectedModel.shortDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current AI model: \(engine.selectedModel.name). \(engine.selectedModel.shortDescription)")
            .accessibilityHint("Opens the model picker")

            NavigationLink("Manage Storage") {
                ModelsSettingsView()
            }

            Toggle(isOn: $settings.wifiOnlyDownloads) {
                Label("Download over Wi-Fi only", systemImage: "wifi")
            }
        } header: {
            Text("AI Model")
        } footer: {
            Text("Models are 1-6 GB, so downloading over Wi-Fi is recommended.")
        }
    }
}

// MARK: - Personalization Section

private struct PersonalizationSection: View {
    @ObservedObject private var personas = PersonaStore.shared
    @ObservedObject private var memory = MemoryStore.shared

    var body: some View {
        Section {
            NavigationLink {
                PersonasView()
            } label: {
                HStack {
                    Label("Personas", systemImage: "theatermasks")
                    Spacer()
                    Text(personas.selected?.name ?? L10n.text("General Assistant"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            NavigationLink {
                MemoryView()
            } label: {
                HStack {
                    Label("Memory", systemImage: "brain.head.profile")
                    Spacer()
                    Text(memory.isEnabled
                         ? L10n.text("\(String(memory.facts.count)) remembered")
                         : L10n.text("Off"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                KnowledgeLibraryView()
            } label: {
                Label("Knowledge Library", systemImage: "books.vertical")
            }
        } header: {
            Text("Personalization")
        } footer: {
            Text("Personas change how the AI answers. Memory and your library stay on this device.")
        }
    }
}

// MARK: - AI Behavior Section

private struct BehaviorSection: View {
    @ObservedObject var settings: SettingsManager
    @ObservedObject var engine: ChatEngine

    private static let minimumWindow = 4096
    private static let maximumWindow = 32768
    private static let windowStep = 4096

    private var temperatureText: String {
        settings.temperature.formatted(.number.precision(.fractionLength(1)))
    }

    private var contextWindowText: String {
        L10n.text("\(settings.contextWindow / 1024)K tokens")
    }

    private var usesAppleIntelligence: Bool {
        engine.selectedModel.backend == .appleIntelligence
    }

    /// The downloaded model the context setting applies to: the selected one,
    /// or - with Apple Intelligence selected - the vision model a photo
    /// would be answered with (the smallest downloaded one, as routing does).
    private var contextModel: AIModel {
        if engine.selectedModel.backend == .mlx { return engine.selectedModel }
        return AIModel.allModels
            .filter { $0.supportsVision && $0.fitsThisDevice() && $0.isDownloaded }
            .min { $0.sizeBytes < $1.sizeBytes }
            ?? AIModel.recommendedDownloadModel
    }

    /// The slider's upper end: the largest 4K step this iPhone can give the
    /// model's cache. Never below 8K, so the slider always has a track to
    /// move along (on a 6 GB phone the 2B model affords about 6.9K).
    private var sliderUpperBound: Int {
        let affordable = MLXService.effectiveContextWindow(for: contextModel, requested: Self.maximumWindow)
        let stepped = (affordable / Self.windowStep) * Self.windowStep
        return min(Self.maximumWindow, max(Self.minimumWindow * 2, stepped))
    }

    /// What the model will really get when that is less than the setting.
    private var effectiveWindowNote: String? {
        let effective = MLXService.effectiveContextWindow(for: contextModel, requested: settings.contextWindow)
        guard effective < settings.contextWindow else { return nil }
        let thousands = String(effective / 1024)
        return L10n.text("Up to \(thousands)K on this iPhone with \(contextModel.name)")
    }

    private var contextWindowBinding: Binding<Double> {
        let upper = sliderUpperBound
        return Binding(
            // Clamped for display: a value saved on another device, or before
            // the cap existed, must not put the thumb off the track.
            get: { Double(min(max(settings.contextWindow, Self.minimumWindow), upper)) },
            set: { settings.contextWindow = Int($0) }
        )
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Creativity")
                    Spacer()
                    Text(temperatureText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(
                    value: $settings.temperature,
                    in: 0.1...1.0,
                    step: 0.1,
                    onEditingChanged: { editing in
                        // Rebuild sessions once, when the drag ends — not on
                        // every tick.
                        if !editing { engine.resetSessions() }
                    }
                )
                .accessibilityLabel(Text("Creativity"))
                .accessibilityValue(temperatureText)

                Text("Lower = more precise, higher = more creative.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            if usesAppleIntelligence {
                // Apple Intelligence's window is fixed by the system; the
                // slider below still governs the downloaded models (photo
                // questions, or after switching).
                Label {
                    Text("Apple Intelligence always uses a 4K window. Downloaded models use the setting below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                }
                .padding(.vertical, 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Context length")
                    Spacer()
                    Text(contextWindowText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 8) {
                    Text("4K")
                        .font(.caption2)
                    Slider(
                        value: contextWindowBinding,
                        in: Double(Self.minimumWindow)...Double(sliderUpperBound),
                        step: Double(Self.windowStep),
                        onEditingChanged: { editing in
                            if !editing { engine.resetSessions() }
                        }
                    )
                    Text(verbatim: "\(sliderUpperBound / 1024)K")
                        .font(.caption2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Context length"))
                .accessibilityValue(contextWindowText)

                if let note = effectiveWindowNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("How much of the conversation the AI re-reads. Higher remembers more but uses more memory and can be slower on older devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("AI Behavior")
        }
    }
}

// MARK: - Language Section

private struct LanguageSection: View {
    @ObservedObject var settings: SettingsManager
    @EnvironmentObject var appState: AppState

    var body: some View {
        Section {
            Picker(selection: $settings.appLanguage) {
                ForEach(AppLanguage.pickerOrder) { language in
                    Text(verbatim: language.displayName).tag(language)
                }
            } label: {
                Label {
                    Text("App Language")
                } icon: {
                    Image(systemName: "globe")
                        .foregroundStyle(.blue)
                }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("Language")
        } footer: {
            Text("Changes the app and the AI's answers. With Automatic, the app follows your device language and the AI replies in whatever language you write in.")
        }
        .onChange(of: settings.appLanguage) { _, _ in
            appState.engine.resetSessions()
        }
    }
}

// MARK: - Speech Section

/// How spoken answers sound in voice mode, Translate and Describe
/// Surroundings. Blind and low-vision users routinely listen faster than the
/// default; everyone else may want it slower.
private struct SpeechSection: View {
    @ObservedObject var settings: SettingsManager
    @StateObject private var preview = SpeechPreview()

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Speaking rate")
                    Spacer()
                    Button {
                        preview.speak(rate: settings.speechRate, language: settings.appLanguage)
                    } label: {
                        Label("Preview", systemImage: "speaker.wave.2")
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }

                HStack(spacing: 8) {
                    Text("Slower")
                        .font(.caption2)
                    Slider(value: $settings.speechRate, in: SettingsManager.speechRateRange)
                    Text("Faster")
                        .font(.caption2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Speaking rate"))
            }
            .padding(.vertical, 4)

            Toggle("Listening sounds", isOn: $settings.listeningSounds)
        } header: {
            Text("Speech")
        } footer: {
            Text("Plays a short tone when the microphone opens and closes.")
        }
        .onDisappear { preview.stop() }
    }
}

/// Speaks one sample sentence at the chosen rate. A synthesizer of its own,
/// so a preview never interrupts or queues behind the voice conversation's.
@MainActor
private final class SpeechPreview: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(rate: Double, language: AppLanguage) {
        stop()
        let utterance = AVSpeechUtterance(string: L10n.text("This is how spoken answers will sound."))
        utterance.voice = AVSpeechSynthesisVoice(language: VoiceService.speechCode(for: language))
        utterance.rate = Float(rate)
        // The same rule spoken answers follow: with VoiceOver running, the
        // user's own VoiceOver voice and rate win.
        utterance.prefersAssistiveTechnologySettings = UIAccessibility.isVoiceOverRunning
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}

// MARK: - Siri & Shortcuts Section

/// "Hey Siri, ask AiGoodbye" shipped with no pointer to it anywhere in the
/// app; this is where people look for it.
private struct SiriSection: View {
    /// The tip can be dismissed with its close button, and stays dismissed.
    @AppStorage("settings_siri_tip_visible") private var showsSiriTip = true

    var body: some View {
        Section {
            if showsSiriTip {
                SiriTipView(intent: AskAiGoodbyeIntent(), isVisible: $showsSiriTip)
            }
            ShortcutsLink()
                .frame(maxWidth: .infinity)
        } header: {
            Text("Siri & Shortcuts")
        }
    }
}

// MARK: - Feedback Section

private struct FeedbackSection: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        Section {
            Toggle("Haptic Feedback", isOn: $settings.hapticFeedbackEnabled)
        } header: {
            Text("Feedback")
        }
    }
}

// MARK: - Privacy Section

private struct PrivacySection: View {
    @ObservedObject private var lock = AppLock.shared

    var body: some View {
        Section {
            NavigationLink {
                PrivacyCenterView()
            } label: {
                Label("Privacy Center", systemImage: "checkmark.shield")
            }

            if lock.isAvailable {
                // Turning the lock OFF asks for the same authentication the
                // lock uses: otherwise anyone who reached Settings could
                // simply switch it off.
                Toggle(isOn: Binding(
                    get: { lock.isEnabled },
                    set: { wanted in
                        if wanted {
                            lock.isEnabled = true
                        } else {
                            Task { @MainActor in
                                if await lock.authenticateToChangeSetting() {
                                    lock.isEnabled = false
                                }
                            }
                        }
                    }
                )) {
                    Label(L10n.text("Lock with \(lock.biometryName)"), systemImage: "lock")
                }
            }

            Link(destination: URL(string: "https://aigoodbye.ai/privacy-policy.html")!) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }

            NavigationLink("About & Legal") {
                AboutView()
            }
        } header: {
            Text("Privacy")
        } footer: {
            if lock.isAvailable {
                Text("When locked, your conversations are hidden until you unlock the app.")
            }
        }
    }
}

// MARK: - Data Section

private struct DataSection: View {
    @EnvironmentObject var appState: AppState
    @State private var showClearConfirmation = false
    @State private var showResetConfirmation = false

    var body: some View {
        Section {
            Button("Clear All Conversations", role: .destructive) {
                showClearConfirmation = true
            }
            .confirmationDialog(
                "Delete all conversations?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    // Stop and detach the chat on screen BEFORE the store is
                    // emptied: a finalizer or a re-render touching a
                    // deleted SwiftData model traps.
                    Task { @MainActor in
                        await appState.chatViewModel.stopGenerationAndWait()
                        appState.chatViewModel.loadConversation(nil)
                        appState.currentConversation = nil
                        appState.conversationManager.clearAllData()
                        appState.engine.resetSessions()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes all your chats and folders. This cannot be undone.")
            }

            Button("Reset Settings") {
                showResetConfirmation = true
            }
            .confirmationDialog(
                "Reset all settings?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    appState.settings.resetToDefaults()
                    // The live session was built with the old creativity
                    // and context values; rebuild it with the defaults.
                    appState.engine.resetSessions()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Restores creativity, context length, language, speech, haptics and download settings to their defaults. Your conversations are not affected.")
            }
        } header: {
            Text("Data")
        }
    }
}

// MARK: - About View

/// Small about screen reusing the shared LegalText copy, so Settings and
/// onboarding never drift apart.
struct AboutView: View {
    private let appVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.0.1"
    /// The build number, so a support email can say exactly which build.
    private let buildNumber =
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    private static let termsURL = URL(string: "https://aigoodbye.ai/terms.html")
    /// Opens the App Store's "Write a Review" sheet for this app.
    private static let reviewURL = URL(string: "itms-apps://apps.apple.com/app/id6757513032?action=write-review")

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header

                ForEach(LegalText.sections.indices, id: \.self) { index in
                    sectionCard(LegalText.sections[index])
                }

                links
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 600)          // readable width on iPad
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("About & Legal")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(LegalText.appName)
                .font(.title2.bold())

            Text("Version \(appVersion) (\(buildNumber))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private func sectionCard(_ section: (title: String, body: String, icon: String)) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: section.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(section.title)
                    .font(.headline)

                Text(section.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        .accessibilityElement(children: .combine)
    }

    private var links: some View {
        VStack(spacing: 12) {
            Link(destination: URL(string: "https://aigoodbye.ai/privacy-policy.html")!) {
                Label("Privacy Policy", systemImage: "hand.raised")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let termsURL = Self.termsURL {
                Link(destination: termsURL) {
                    Label("Terms of Use", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let reviewURL = Self.reviewURL {
                Link(destination: reviewURL) {
                    Label("Rate AiGoodbye", systemImage: "star")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Link(destination: URL(string: "https://aigoodbye.ai")!) {
                Label("aigoodbye.ai", systemImage: "globe")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Link(destination: URL(string: "mailto:marketing@dealerofhappiness.com")!) {
                Label("marketing@dealerofhappiness.com", systemImage: "envelope")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.subheadline)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        .padding(.top, 4)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AppState())
    }
}
