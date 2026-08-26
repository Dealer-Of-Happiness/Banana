//
//  SettingsView.swift
//  AIGoodbye
//
//  Settings screen: model choice, AI behavior, feedback, privacy, and data.
//  Presented by SideMenuView inside a NavigationStack sheet.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            ModelSection(engine: appState.engine)
            LanguageSection(settings: appState.settings)
            BehaviorSection(settings: appState.settings)
            FeedbackSection(settings: appState.settings)
            PrivacySection()
            DataSection()
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - AI Model Section

private struct ModelSection: View {
    @ObservedObject var engine: ChatEngine
    @EnvironmentObject var appState: AppState
    @State private var showModelPicker = false

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
        } header: {
            Text("AI Model")
        }
        .sheet(isPresented: $showModelPicker) {
            ModelSelectionView()
                .environmentObject(appState)
        }
    }
}

// MARK: - AI Behavior Section

private struct BehaviorSection: View {
    @ObservedObject var settings: SettingsManager
    @EnvironmentObject var appState: AppState

    private var temperatureText: String {
        settings.temperature.formatted(.number.precision(.fractionLength(1)))
    }

    private var contextWindowText: String {
        "\(settings.contextWindow / 1024)K tokens"
    }

    private var contextWindowBinding: Binding<Double> {
        Binding(
            get: { Double(settings.contextWindow) },
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

                Slider(value: $settings.temperature, in: 0.1...1.0, step: 0.1) {
                    Text("Creativity")
                }
                .accessibilityValue(temperatureText)

                Text("Lower = more precise, higher = more creative.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Conversation Memory")
                    Spacer()
                    Text(contextWindowText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(value: contextWindowBinding, in: 4096...32768, step: 4096) {
                    Text("Conversation Memory")
                } minimumValueLabel: {
                    Text("4K")
                        .font(.caption2)
                } maximumValueLabel: {
                    Text("32K")
                        .font(.caption2)
                }
                .accessibilityValue(contextWindowText)

                Text("How much of the conversation the AI re-reads. Higher remembers more but uses more memory and can be slower on older iPhones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("AI Behavior")
        }
        .onChange(of: settings.temperature) { _, _ in
            appState.engine.resetSessions()
        }
        .onChange(of: settings.contextWindow) { _, _ in
            appState.engine.resetSessions()
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
            Text("Changes the app and the AI's answers. With Automatic, the app follows your iPhone language and the AI replies in whatever language you write in.")
        }
        .onChange(of: settings.appLanguage) { _, _ in
            appState.engine.resetSessions()
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
    var body: some View {
        Section {
            Label("All AI runs on your device", systemImage: "iphone")

            Label("No data collection, no tracking", systemImage: "hand.raised.fill")

            NavigationLink("About & Legal") {
                AboutView()
            }
        } header: {
            Text("Privacy")
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
                    appState.conversationManager.clearAllData()
                    appState.engine.resetSessions()
                    appState.currentConversation = nil
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
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Restores every setting to its default value. Your conversations are not affected.")
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
    private let appVersion = "3.0.0"

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
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("About & Legal")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(LegalText.appName)
                .font(.title2.bold())

            Text("Version \(appVersion)")
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
