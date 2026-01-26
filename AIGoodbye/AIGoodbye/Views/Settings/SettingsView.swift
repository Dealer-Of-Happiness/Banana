//
//  SettingsView.swift
//  AIGoodbye
//
//  Complete settings screen with all configuration options
//

import SwiftUI
import Combine

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = SettingsViewModel()
    @State private var showClearCacheAlert = false
    @State private var showExportOptions = false

    /// App version string from bundle (e.g., "1.1.2")
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            // AI Settings (Context Window)
            aiSettingsSection

            // Data & Privacy
            dataPrivacySection

            // About
            aboutSection
        }
        .navigationTitle("Settings")
        .onAppear {
            viewModel.loadSettings(from: appState.settings)
        }
        .alert("Delete All Conversations?", isPresented: $showClearCacheAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                appState.conversationManager.clearAllData()
                appState.currentConversation = nil
            }
        } message: {
            Text("This will permanently delete all your chat history and folders. This action cannot be undone.")
        }
        .confirmationDialog("Export Format", isPresented: $showExportOptions) {
            ForEach(ExportFormat.allCases, id: \.self) { format in
                Button(format.displayName) {
                    Task { await viewModel.exportConversations(format: format) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - AI Settings Section

    private var aiSettingsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Context Window")
                    Spacer()
                    Text("\(Int(viewModel.contextWindow / 1024))K tokens")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(
                    value: $viewModel.contextWindow,
                    in: 4096...32768,
                    step: 4096
                ) {
                    Text("Context Window")
                } minimumValueLabel: {
                    Text("4K")
                        .font(.caption2)
                } maximumValueLabel: {
                    Text("32K")
                        .font(.caption2)
                }
                .onChange(of: viewModel.contextWindow) { oldValue, newValue in
                    appState.settings.contextWindow = Int(newValue)

                    // Auto-reload model if context window changed significantly
                    if abs(oldValue - newValue) >= 1024 {
                        Task {
                            do {
                                try await appState.llamaService.reloadModel()
                            } catch {
                                print("[Settings] Failed to reload model: \(error)")
                            }
                        }
                    }
                }

                // Guidance text based on selected value
                Text(contextWindowGuidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.vertical, 4)
        } header: {
            Label("AI Performance", systemImage: "cpu")
        } footer: {
            Text("Higher values allow longer conversations but use more memory. Model reloads automatically when changed.")
        }
    }

    private var contextWindowGuidance: String {
        let tokens = Int(viewModel.contextWindow)
        switch tokens {
        case 0..<6000:
            return "4K: Recommended for iPhone 13/14 and devices with 4-6GB RAM. Supports ~10-15 message conversations."
        case 6000..<12000:
            return "8K: Recommended for iPhone 15/15 Plus with 6GB RAM. Supports ~20-30 message conversations."
        case 12000..<20000:
            return "16K: Recommended for iPhone 15 Pro/16 with 8GB RAM. Supports ~40-50 message conversations."
        case 20000..<28000:
            return "24K: Recommended for iPhone 16 Pro with 8GB+ RAM. Supports ~60-70 message conversations."
        default:
            return "32K: Recommended for iPhone 16 Pro Max and future devices with 12GB+ RAM. Maximum conversation length."
        }
    }

    // MARK: - Data & Privacy Section

    private var dataPrivacySection: some View {
        Section {
            Button("Export All Conversations") {
                showExportOptions = true
            }

            Button("Delete All Chats", role: .destructive) {
                showClearCacheAlert = true
            }
        } header: {
            Label("Data & Privacy", systemImage: "lock.shield")
        } footer: {
            Text("All data is stored locally on your device.")
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(appVersion)
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

}

// MARK: - Settings View Model

@MainActor
class SettingsViewModel: ObservableObject {
    // AI Configuration
    @Published var temperature: Double = 0.7
    @Published var contextWindow: Double = 4096

    func loadSettings(from settings: SettingsManager) {
        temperature = settings.temperature
        contextWindow = Double(settings.contextWindow)
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
                    sectionTitle("Welcome to AiGoodbye!")

                    Text("""
                    These Terms and Conditions ("Terms") constitute a legally binding agreement between you and AiGoodbye regarding your use of our application and services. By accessing or using AiGoodbye, you agree to comply with and be bound by these Terms.
                    """)

                    sectionTitle("Acceptance of Terms")

                    Text("""
                    By using AiGoodbye, you confirm that you are of legal age and capacity to enter into these Terms. If you do not agree to these Terms, you must not use our app.
                    """)

                    sectionTitle("AI Model Limitations and Disclaimers")

                    Text("You acknowledge and agree that:")
                        .fontWeight(.medium)

                    bulletPoints([
                        "The AI models in AiGoodbye may generate content that is incorrect, incomplete, misleading, or inappropriate.",
                        "You should not rely on AI-generated content for medical, legal, financial, or other professional advice.",
                        "The AI models may occasionally produce biased, offensive, or harmful content despite our best efforts to prevent such outputs.",
                        "You are solely responsible for verifying any information or content generated by the AI models before acting upon it.",
                        "AiGoodbye is not responsible for any decisions, actions, or consequences resulting from your use of AI-generated content."
                    ])
                }

                Group {
                    sectionTitle("Data and Privacy")

                    Text("Regarding data privacy and processing:")
                        .fontWeight(.medium)

                    bulletPoints([
                        "All AI processing occurs entirely on your device - no data is sent to external servers",
                        "Your conversations and data never leave your phone",
                        "You are responsible for the security of your device and any data you input into the app",
                        "You are responsible for ensuring you have the right to use any content you input into the app"
                    ])

                    sectionTitle("Offline Operation")

                    Text("Regarding offline functionality:")
                        .fontWeight(.medium)

                    bulletPoints([
                        "AiGoodbye operates 100% offline after the initial model download",
                        "No internet connection is required to use the AI features",
                        "No accounts, logins, or subscriptions are required",
                        "Your privacy is guaranteed by design"
                    ])
                }

                Group {
                    sectionTitle("Prohibited Uses")

                    Text("You agree not to use AiGoodbye:")
                        .fontWeight(.medium)

                    bulletPoints([
                        "For any unlawful purpose or to generate content that promotes illegal activities",
                        "To generate content that is discriminatory, hateful, or promotes harm against individuals or groups",
                        "To create misleading or fraudulent content",
                        "To generate spam, malware, or other malicious content"
                    ])

                    sectionTitle("Disclaimer of Warranties")

                    Text("""
                    AIGOODBYE IS PROVIDED "AS IS" AND "AS AVAILABLE" WITHOUT ANY WARRANTIES OF ANY KIND, WHETHER EXPRESS OR IMPLIED. We specifically disclaim any implied warranties of merchantability, fitness for a particular purpose, and non-infringement.
                    """)
                    .fontWeight(.medium)
                }

                Group {
                    sectionTitle("Limitation of Liability")

                    Text("TO THE MAXIMUM EXTENT PERMITTED BY LAW:")
                        .fontWeight(.bold)

                    bulletPoints([
                        "AIGOODBYE SHALL NOT BE LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES",
                        "OUR TOTAL LIABILITY FOR ANY CLAIMS ARISING FROM OR RELATED TO YOUR USE OF THE APP SHALL NOT EXCEED THE AMOUNT YOU PAID FOR THE APP",
                        "WE ARE NOT LIABLE FOR ANY ACTIONS YOU TAKE OR REFRAIN FROM TAKING BASED ON AI-GENERATED CONTENT"
                    ])

                    sectionTitle("Changes to Terms")

                    Text("""
                    We reserve the right to modify these Terms at any time. We will notify you of material changes through the app or website. Your continued use after such modifications constitutes acceptance of the updated Terms.
                    """)

                    sectionTitle("Contact Us")

                    Text("If you have any questions about these Terms, please contact us at:")

                    Link("marketing@dealerofhappiness.com", destination: URL(string: "mailto:marketing@dealerofhappiness.com")!)
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
                AiGoodbye is designed with privacy as a core principle. Say goodbye to monthly subscriptions, sharing your private data, and requiring internet connection.

                **100% Offline & Private**
                All AI processing happens directly on your device. Your conversations never leave your phone - no servers, no cloud, no data collection.

                **Your Data Stays Yours**
                - All conversations are stored locally on your device
                - Nothing is ever uploaded or shared
                - Delete your data anytime from Settings

                **No Tracking**
                We don't collect analytics, usage data, or personal information. The app works completely offline.

                **No Account Required**
                Use AiGoodbye without creating an account or signing in. Your privacy is guaranteed by design.

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
