//
//  SettingsView.swift
//  AI goodbye
//
//  Complete settings screen with all configuration options
//

import SwiftUI
import Combine
import CloudKit
import EventKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = SettingsViewModel()
    @State private var showClearCacheAlert = false
    @State private var showExportOptions = false
    @State private var showICloudError = false
    @State private var iCloudErrorMessage = ""
    @State private var showPermissionDenied = false
    @State private var permissionDeniedSource: KnowledgeBaseSource?

    var body: some View {
        Form {
            // AI Configuration
            aiConfigurationSection

            // Cloud Connections
            cloudConnectionsSection

            // Language
            languageSection

            // Voice & Sound
            voiceSoundSection

            // Personal Knowledge Base
            knowledgeBaseSection

            // Data & Privacy
            dataPrivacySection

            // About
            aboutSection

            // Apple Watch
            watchSection
        }
        .navigationTitle("Settings")
        .onAppear {
            viewModel.loadSettings(from: appState.settings)
        }
        .onChange(of: viewModel.temperature) { _, newValue in
            appState.settings.temperature = newValue
        }
        .onChange(of: viewModel.contextWindow) { _, newValue in
            appState.settings.contextWindow = Int(newValue)
        }
        .alert("Delete All Conversations?", isPresented: $showClearCacheAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                Task { await viewModel.clearCache() }
            }
        } message: {
            Text("This will permanently delete all your chat history, including chats in locked folders. This action cannot be undone.")
        }
        .confirmationDialog("Export Format", isPresented: $showExportOptions) {
            ForEach(ExportFormat.allCases, id: \.self) { format in
                Button(format.displayName) {
                    Task { await viewModel.exportConversations(format: format) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("iCloud Not Available", isPresented: $showICloudError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(iCloudErrorMessage)
        }
        .alert("Permission Denied", isPresented: $showPermissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let source = permissionDeniedSource {
                Text("AI goodbye needs access to \(source.displayName). Please enable it in Settings.")
            } else {
                Text("Permission was denied. Please enable it in Settings.")
            }
        }
    }

    // MARK: - AI Configuration Section

    private var aiConfigurationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.1f", viewModel.temperature))
                        .foregroundStyle(.secondary)
                }

                Slider(value: $viewModel.temperature, in: 0...2, step: 0.1)
                    .tint(.blue)

                Text("Controls creativity. Lower = more focused and deterministic. Higher = more creative and varied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Context Window")
                    Spacer()
                    Text("\(Int(viewModel.contextWindow)) tokens")
                        .foregroundStyle(.secondary)
                }

                Slider(value: $viewModel.contextWindow, in: 1024...8192, step: 512)
                    .tint(.blue)

                Text("How much conversation history the AI remembers. Higher = better context but slower responses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Active Model")
                Spacer()
                Text("Llama 3.2 3B")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("AI Configuration", systemImage: "brain")
        }
    }

    // MARK: - Cloud Connections Section

    private var cloudConnectionsSection: some View {
        Section {
            CloudConnectionRow(
                provider: .chatGPT,
                isEnabled: $viewModel.chatGPTEnabled,
                apiKey: $viewModel.chatGPTApiKey
            )

            CloudConnectionRow(
                provider: .claude,
                isEnabled: $viewModel.claudeEnabled,
                apiKey: $viewModel.claudeApiKey
            )

            CloudConnectionRow(
                provider: .google,
                isEnabled: $viewModel.googleEnabled,
                apiKey: $viewModel.googleApiKey
            )
        } header: {
            Label("Cloud Connections", systemImage: "cloud")
        } footer: {
            Text("Optional. Connect using your own API keys for enhanced capabilities.")
        }
    }

    // MARK: - Language Section

    private var languageSection: some View {
        Section {
            Picker("Input Language", selection: $viewModel.inputLanguage) {
                ForEach(SupportedLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }

            Picker("Output Language", selection: $viewModel.outputLanguage) {
                ForEach(SupportedLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
        } header: {
            Label("Language", systemImage: "globe")
        }
    }

    // MARK: - Voice & Sound Section

    private var voiceSoundSection: some View {
        Section {
            Toggle("Haptic Feedback", isOn: $viewModel.hapticFeedback)

            Picker("Voice Input Mode", selection: $viewModel.voiceInputMode) {
                ForEach(VoiceInputMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Speech Rate")
                    Spacer()
                    Text(String(format: "%.1fx", viewModel.speechRate))
                        .foregroundStyle(.secondary)
                }

                Slider(value: $viewModel.speechRate, in: 0.5...2.0, step: 0.1)
                    .tint(.blue)
            }
        } header: {
            Label("Voice & Sound", systemImage: "speaker.wave.2")
        }
    }

    // MARK: - Knowledge Base Section

    private var knowledgeBaseSection: some View {
        Section {
            ForEach(KnowledgeBaseSource.allCases) { source in
                KnowledgeBaseRow(
                    source: source,
                    isEnabled: binding(for: source),
                    permissionStatus: viewModel.permissionStatus(for: source),
                    onToggle: { isEnabled in
                        if isEnabled {
                            Task {
                                await requestPermission(for: source)
                            }
                        }
                    }
                )
            }
        } header: {
            Label("Personal Knowledge Base", systemImage: "brain.head.profile")
        } footer: {
            Text("Allow AI goodbye to access your personal data to provide more relevant responses.")
        }
    }

    private func binding(for source: KnowledgeBaseSource) -> Binding<Bool> {
        switch source {
        case .calendar: return $viewModel.calendarEnabled
        case .notes: return $viewModel.notesEnabled
        case .email: return $viewModel.emailEnabled
        case .reminders: return $viewModel.remindersEnabled
        }
    }

    private func requestPermission(for source: KnowledgeBaseSource) async {
        do {
            let granted = try await appState.knowledgeBaseService.requestPermission(for: source)
            if !granted {
                await MainActor.run {
                    // Turn off the toggle if permission not granted
                    setToggle(for: source, to: false)
                    permissionDeniedSource = source
                    showPermissionDenied = true
                }
            }
        } catch {
            await MainActor.run {
                setToggle(for: source, to: false)
                permissionDeniedSource = source
                showPermissionDenied = true
            }
        }
    }

    private func setToggle(for source: KnowledgeBaseSource, to value: Bool) {
        switch source {
        case .calendar: viewModel.calendarEnabled = value
        case .notes: viewModel.notesEnabled = value
        case .email: viewModel.emailEnabled = value
        case .reminders: viewModel.remindersEnabled = value
        }
    }

    // MARK: - Data & Privacy Section

    private var dataPrivacySection: some View {
        Section {
            Toggle("iCloud Sync", isOn: $viewModel.iCloudSync)
                .onChange(of: viewModel.iCloudSync) { _, newValue in
                    if newValue {
                        Task {
                            await checkICloudAvailability()
                        }
                    }
                }

            Button("Export All Conversations") {
                showExportOptions = true
            }

            Button("Clear Cache (Delete All Chats)", role: .destructive) {
                showClearCacheAlert = true
            }
        } header: {
            Label("Data & Privacy", systemImage: "lock.shield")
        }
    }

    private func checkICloudAvailability() async {
        do {
            let container = CKContainer.default()
            let status = try await container.accountStatus()

            await MainActor.run {
                switch status {
                case .available:
                    // iCloud is available, sync will happen
                    appState.settings.iCloudSyncEnabled = true
                case .noAccount:
                    viewModel.iCloudSync = false
                    iCloudErrorMessage = "No iCloud account found. Please sign in to iCloud in Settings."
                    showICloudError = true
                case .restricted:
                    viewModel.iCloudSync = false
                    iCloudErrorMessage = "iCloud access is restricted on this device."
                    showICloudError = true
                case .couldNotDetermine:
                    viewModel.iCloudSync = false
                    iCloudErrorMessage = "Could not determine iCloud status. Please try again later."
                    showICloudError = true
                case .temporarilyUnavailable:
                    viewModel.iCloudSync = false
                    iCloudErrorMessage = "iCloud is temporarily unavailable. Please try again later."
                    showICloudError = true
                @unknown default:
                    viewModel.iCloudSync = false
                    iCloudErrorMessage = "iCloud is not available."
                    showICloudError = true
                }
            }
        } catch {
            await MainActor.run {
                viewModel.iCloudSync = false
                iCloudErrorMessage = "Failed to check iCloud status: \(error.localizedDescription)"
                showICloudError = true
            }
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text("1.0.0")
                    .foregroundStyle(.secondary)
            }

            NavigationLink("Terms and Conditions") {
                TermsDetailView()
            }

            NavigationLink("Privacy Policy") {
                PrivacyPolicyView()
            }

            Link(destination: URL(string: "mailto:marketing@dealerofhappiness.com")!) {
                HStack {
                    Text("Contact Us")
                    Spacer()
                    Text("marketing@dealerofhappiness.com")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } header: {
            Label("About", systemImage: "info.circle")
        }
    }

    // MARK: - Watch Section

    private var watchSection: some View {
        Section {
            HStack {
                Text("Watch App Status")
                Spacer()
                Text(viewModel.watchAppStatus)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Apple Watch", systemImage: "applewatch")
        }
    }
}

// MARK: - Cloud Connection Row

struct CloudConnectionRow: View {
    let provider: CloudAIProvider
    @Binding var isEnabled: Bool
    @Binding var apiKey: String
    @State private var showApiKeyField = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isEnabled) {
                HStack {
                    Image(systemName: provider.iconName)
                        .foregroundStyle(.blue)
                    Text(provider.displayName)
                }
            }

            if isEnabled {
                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)
                    .font(.footnote)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Knowledge Base Row

struct KnowledgeBaseRow: View {
    let source: KnowledgeBaseSource
    @Binding var isEnabled: Bool
    let permissionStatus: String
    var onToggle: ((Bool) -> Void)? = nil

    // Check if this source is supported
    private var isSupported: Bool {
        source != .notes && source != .email
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $isEnabled) {
                HStack {
                    Image(systemName: source.iconName)
                        .foregroundStyle(isSupported ? .blue : .gray)
                        .frame(width: 24)
                    Text(source.displayName)
                        .foregroundStyle(isSupported ? .primary : .secondary)
                }
            }
            .disabled(!isSupported)
            .onChange(of: isEnabled) { _, newValue in
                if isSupported {
                    onToggle?(newValue)
                }
            }

            HStack {
                Text(source.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(permissionStatus)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusBackgroundColor)
                    .foregroundStyle(statusTextColor)
                    .clipShape(Capsule())
            }
        }
    }

    private var statusBackgroundColor: Color {
        switch permissionStatus {
        case "Granted": return Color.green.opacity(0.2)
        case "Not Available": return Color.orange.opacity(0.2)
        case "Denied": return Color.red.opacity(0.2)
        default: return Color.gray.opacity(0.2)
        }
    }

    private var statusTextColor: Color {
        switch permissionStatus {
        case "Granted": return .green
        case "Not Available": return .orange
        case "Denied": return .red
        default: return .gray
        }
    }
}

// MARK: - Settings View Model

@MainActor
class SettingsViewModel: ObservableObject {
    // AI Configuration
    @Published var temperature: Double = 0.7
    @Published var contextWindow: Double = 4096

    // Cloud Connections
    @Published var chatGPTEnabled = false
    @Published var chatGPTApiKey = ""
    @Published var claudeEnabled = false
    @Published var claudeApiKey = ""
    @Published var googleEnabled = false
    @Published var googleApiKey = ""

    // Language
    @Published var inputLanguage: SupportedLanguage = .english
    @Published var outputLanguage: SupportedLanguage = .english

    // Voice & Sound
    @Published var hapticFeedback = true
    @Published var voiceInputMode: VoiceInputMode = .pushToTalk
    @Published var speechRate: Double = 1.0

    // Knowledge Base
    @Published var calendarEnabled = false
    @Published var notesEnabled = false
    @Published var emailEnabled = false
    @Published var remindersEnabled = false

    // Data & Privacy
    @Published var iCloudSync = false

    // Watch
    @Published var watchAppStatus = "Not Connected"

    func loadSettings(from settings: SettingsManager) {
        temperature = settings.temperature
        contextWindow = Double(settings.contextWindow)
        hapticFeedback = settings.hapticFeedbackEnabled
        iCloudSync = settings.iCloudSyncEnabled
        inputLanguage = settings.inputLanguage
        outputLanguage = settings.outputLanguage
    }

    func permissionStatus(for source: KnowledgeBaseSource) -> String {
        // Check actual permission status from the system
        switch source {
        case .calendar:
            let status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .fullAccess, .authorized: return "Granted"
            case .denied, .restricted: return "Denied"
            default: return "Not Set"
            }
        case .reminders:
            let status = EKEventStore.authorizationStatus(for: .reminder)
            switch status {
            case .fullAccess, .authorized: return "Granted"
            case .denied, .restricted: return "Denied"
            default: return "Not Set"
            }
        case .notes:
            return "Not Available" // Notes doesn't have a public API
        case .email:
            return "Not Available" // Email requires custom integration
        }
    }

    func clearCache() async {
        // Clear all conversations and cached data
    }

    func exportConversations(format: ExportFormat) async {
        // Export conversations in selected format
    }
}

// MARK: - Terms Detail View

struct TermsDetailView: View {
    var body: some View {
        ScrollView {
            Text("Terms and Conditions content here...")
                .padding()
        }
        .navigationTitle("Terms and Conditions")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Privacy Policy View

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Privacy Policy")
                    .font(.title.bold())

                Text("""
                AI goodbye is designed with privacy as a core principle. Say goodbye to monthly subscriptions, sharing your private data, and requiring internet connection.

                **Local Processing**
                All AI processing happens directly on your device. Your conversations and documents never leave your device unless you explicitly enable cloud AI services.

                **Your Data**
                - Documents are stored locally and encrypted
                - Conversations stay on your device
                - Personal knowledge base access is optional and revocable
                - iCloud sync is optional and encrypted

                **Cloud Services**
                When you enable cloud AI (ChatGPT, Claude, Google), your queries are sent to those services. You use your own API keys and are subject to their privacy policies.

                **No Tracking**
                We don't collect analytics, usage data, or personal information.

                **Contact**
                marketing@dealerofhappiness.com
                """)
            }
            .padding()
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AppState())
    }
}
