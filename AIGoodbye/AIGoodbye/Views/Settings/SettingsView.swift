//
//  SettingsView.swift
//  AIGoodbye
//
//  Complete settings screen with all configuration options
//

import SwiftUI
import Combine
import StoreKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var donationService = DonationService()
    @State private var showClearCacheAlert = false
    @State private var showExportOptions = false
    @State private var showICloudError = false
    @State private var iCloudErrorMessage = ""

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

            // Data & Privacy
            dataPrivacySection

            // Support AI goodbye
            supportSection

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
        .sheet(isPresented: $donationService.showThankYou) {
            ThankYouView(isPresented: $donationService.showThankYou)
        }
        .alert("Purchase Error", isPresented: .init(
            get: { donationService.purchaseError != nil },
            set: { if !$0 { donationService.purchaseError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(donationService.purchaseError ?? "")
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

            NavigationLink {
                ModelsSettingsView()
            } label: {
                HStack {
                    Text("AI Models")
                    Spacer()
                    Text(ModelManager.shared.currentModel.name)
                        .foregroundStyle(.secondary)
                }
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
        // iCloud sync is not yet implemented - show message
        await MainActor.run {
            viewModel.iCloudSync = false
            iCloudErrorMessage = "iCloud sync is coming soon in a future update."
            showICloudError = true
        }
    }

    // MARK: - Support Section

    private var supportSection: some View {
        Section {
            ForEach(DonationTier.allCases) { tier in
                DonationRow(
                    tier: tier,
                    product: donationService.products.first { $0.id == tier.rawValue },
                    isLoading: donationService.purchaseInProgress
                ) {
                    Task {
                        await donationService.purchase(tier)
                    }
                }
            }
        } header: {
            Label("Support AI goodbye", systemImage: "heart.fill")
        } footer: {
            Text("Your support helps keep AI goodbye free and ad-free for everyone. Thank you!")
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

// MARK: - Donation Row

struct DonationRow: View {
    let tier: DonationTier
    let product: Product?
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(tier.emoji)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tier.displayName)
                        .font(.body)

                    if let product = product {
                        Text(product.displayPrice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(tier.price)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .foregroundStyle(.primary)
        .disabled(isLoading)
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
            VStack(alignment: .leading, spacing: 20) {
                Text("Effective Date: January 1, 2026")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Group {
                    sectionTitle("Welcome to AI goodbye!")

                    Text("""
                    These Terms and Conditions ("Terms") constitute a legally binding agreement between you and AI goodbye regarding your use of our application and services. By accessing or using AI goodbye, you agree to comply with and be bound by these Terms.
                    """)

                    sectionTitle("Acceptance of Terms")

                    Text("""
                    By using AI goodbye, you confirm that you are of legal age and capacity to enter into these Terms. If you do not agree to these Terms, you must not use our app.
                    """)

                    sectionTitle("AI Model Limitations and Disclaimers")

                    Text("You acknowledge and agree that:")
                        .fontWeight(.medium)

                    bulletPoints([
                        "The AI models in AI goodbye may generate content that is incorrect, incomplete, misleading, or inappropriate.",
                        "You should not rely on AI-generated content for medical, legal, financial, or other professional advice.",
                        "The AI models may occasionally produce biased, offensive, or harmful content despite our best efforts to prevent such outputs.",
                        "You are solely responsible for verifying any information or content generated by the AI models before acting upon it.",
                        "AI goodbye is not responsible for any decisions, actions, or consequences resulting from your use of AI-generated content."
                    ])
                }

                Group {
                    sectionTitle("Data and Privacy")

                    Text("Regarding data privacy and processing:")
                        .fontWeight(.medium)

                    bulletPoints([
                        "When using local models, all processing occurs on your device with no data sent to external servers",
                        "When using cloud models, your conversations and prompts are sent to external servers",
                        "You are responsible for the security of your device and any data you input into the app",
                        "You are responsible for ensuring you have the right to use any content you input into the app"
                    ])

                    sectionTitle("Third-Party Services")

                    Text("Regarding third-party services:")
                        .fontWeight(.medium)

                    bulletPoints([
                        "The integration allows you to access third-party AI models through their APIs",
                        "Your use of third-party services is subject to their terms of service and privacy policy",
                        "AI goodbye is not responsible for the practices, policies, or content of third-party providers",
                        "Your API keys and account management are your responsibility"
                    ])
                }

                Group {
                    sectionTitle("Prohibited Uses")

                    Text("You agree not to use AI goodbye:")
                        .fontWeight(.medium)

                    bulletPoints([
                        "For any unlawful purpose or to generate content that promotes illegal activities",
                        "To generate content that is discriminatory, hateful, or promotes harm against individuals or groups",
                        "To create misleading or fraudulent content",
                        "To generate spam, malware, or other malicious content"
                    ])

                    sectionTitle("Disclaimer of Warranties")

                    Text("""
                    AI GOODBYE IS PROVIDED "AS IS" AND "AS AVAILABLE" WITHOUT ANY WARRANTIES OF ANY KIND, WHETHER EXPRESS OR IMPLIED. We specifically disclaim any implied warranties of merchantability, fitness for a particular purpose, and non-infringement.
                    """)
                    .fontWeight(.medium)
                }

                Group {
                    sectionTitle("Limitation of Liability")

                    Text("TO THE MAXIMUM EXTENT PERMITTED BY LAW:")
                        .fontWeight(.bold)

                    bulletPoints([
                        "AI GOODBYE SHALL NOT BE LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES",
                        "OUR TOTAL LIABILITY FOR ANY CLAIMS ARISING FROM OR RELATED TO YOUR USE OF THE APP SHALL NOT EXCEED THE AMOUNT YOU PAID FOR THE APP",
                        "WE ARE NOT LIABLE FOR ANY ACTIONS YOU TAKE OR REFRAIN FROM TAKING BASED ON AI-GENERATED CONTENT"
                    ])

                    sectionTitle("Changes to Terms")

                    Text("""
                    We reserve the right to modify these Terms at any time. We will notify you of material changes through the app or website. Your continued use after such modifications constitutes acceptance of the updated Terms.
                    """)

                    sectionTitle("Contact Us")

                    Text("If you have any questions about these Terms, please contact us at:")

                    Link("support@aigoodbye.ai", destination: URL(string: "mailto:support@aigoodbye.ai")!)
                        .foregroundStyle(.blue)
                }
            }
            .font(.body)
            .padding()
        }
        .navigationTitle("Terms and Conditions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 8)
    }

    private func bulletPoints(_ points: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(points, id: \.self) { point in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                    Text(point)
                }
            }
        }
        .padding(.leading, 8)
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
