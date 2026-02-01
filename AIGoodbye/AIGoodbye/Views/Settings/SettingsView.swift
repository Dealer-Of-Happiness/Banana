//
//  SettingsView.swift
//  AIGoodbye
//
//  Complete settings screen with all configuration options
//

import SwiftUI
import Combine
import UIKit

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
                    Task {
                        await viewModel.exportConversations(
                            format: format,
                            conversations: appState.conversationManager.conversations
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $viewModel.showShareSheet) {
            if let url = viewModel.exportURL {
                ShareSheet(items: [url])
            }
        }
        .alert("Export Error", isPresented: Binding(
            get: { viewModel.exportError != nil },
            set: { if !$0 { viewModel.exportError = nil } }
        )) {
            Button("OK") {
                viewModel.exportError = nil
            }
        } message: {
            Text(viewModel.exportError ?? "An error occurred during export")
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
                                try await appState.mlxService.reloadModel()
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

            if let emailURL = AppConfig.Contact.supportEmailURL {
                Link(destination: emailURL) {
                    HStack {
                        Text("Contact Us")
                        Spacer()
                        Text(AppConfig.Contact.supportEmail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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
    @Published var exportURL: URL?
    @Published var showShareSheet = false
    @Published var exportError: String?

    func loadSettings(from settings: SettingsManager) {
        temperature = settings.temperature
        contextWindow = Double(settings.contextWindow)
    }

    func exportConversations(format: ExportFormat, conversations: [Conversation]) async {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let fileName = "AiGoodbye_Export_\(Date().formatted(date: .numeric, time: .omitted).replacingOccurrences(of: "/", with: "-"))"
        let tempDir = FileManager.default.temporaryDirectory

        do {
            switch format {
            case .txt:
                let content = generateTextExport(conversations: conversations, dateFormatter: dateFormatter)
                let fileURL = tempDir.appendingPathComponent("\(fileName).txt")
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
                exportURL = fileURL
                showShareSheet = true

            case .json:
                let content = generateJSONExport(conversations: conversations)
                let fileURL = tempDir.appendingPathComponent("\(fileName).json")
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
                exportURL = fileURL
                showShareSheet = true

            case .pdf:
                if let pdfData = generatePDFExport(conversations: conversations, dateFormatter: dateFormatter) {
                    let fileURL = tempDir.appendingPathComponent("\(fileName).pdf")
                    try pdfData.write(to: fileURL)
                    exportURL = fileURL
                    showShareSheet = true
                } else {
                    exportError = "Failed to generate PDF. Please try another format."
                }
            }
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }

    private func generateTextExport(conversations: [Conversation], dateFormatter: DateFormatter) -> String {
        var text = "AiGoodbye Conversations Export\n"
        text += "Exported on: \(dateFormatter.string(from: Date()))\n"
        text += "Total conversations: \(conversations.count)\n"
        text += String(repeating: "=", count: 50) + "\n\n"

        for conversation in conversations {
            text += "CONVERSATION: \(conversation.title)\n"
            text += "Created: \(dateFormatter.string(from: conversation.createdAt))\n"
            text += "Updated: \(dateFormatter.string(from: conversation.updatedAt))\n"
            text += String(repeating: "-", count: 40) + "\n"

            let sortedMessages = conversation.messages.sorted { $0.timestamp < $1.timestamp }
            for message in sortedMessages {
                let role = message.role.rawValue.uppercased()
                let time = dateFormatter.string(from: message.timestamp)
                text += "[\(role)] (\(time))\n"
                text += "\(message.content)\n\n"
            }

            text += "\n" + String(repeating: "=", count: 50) + "\n\n"
        }

        return text
    }

    private func generateJSONExport(conversations: [Conversation]) -> String {
        var exportData: [[String: Any]] = []

        for conversation in conversations {
            var convDict: [String: Any] = [
                "id": conversation.id.uuidString,
                "title": conversation.title,
                "createdAt": ISO8601DateFormatter().string(from: conversation.createdAt),
                "updatedAt": ISO8601DateFormatter().string(from: conversation.updatedAt)
            ]

            let sortedMessages = conversation.messages.sorted { $0.timestamp < $1.timestamp }
            var messagesArray: [[String: Any]] = []
            for message in sortedMessages {
                messagesArray.append([
                    "id": message.id.uuidString,
                    "role": message.role.rawValue,
                    "content": message.content,
                    "timestamp": ISO8601DateFormatter().string(from: message.timestamp)
                ])
            }
            convDict["messages"] = messagesArray

            exportData.append(convDict)
        }

        let wrapper: [String: Any] = [
            "exportDate": ISO8601DateFormatter().string(from: Date()),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            "totalConversations": conversations.count,
            "conversations": exportData
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted, .sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }

        return "{}"
    }

    private func generatePDFExport(conversations: [Conversation], dateFormatter: DateFormatter) -> Data? {
        let pageWidth: CGFloat = 612  // Letter size
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 50
        let contentWidth = pageWidth - (margin * 2)

        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        let data = pdfRenderer.pdfData { context in
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 24),
                .foregroundColor: UIColor.black
            ]
            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 14),
                .foregroundColor: UIColor.darkGray
            ]
            let roleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 12),
                .foregroundColor: UIColor.systemBlue
            ]
            let contentAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.black
            ]
            let metaAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.italicSystemFont(ofSize: 9),
                .foregroundColor: UIColor.gray
            ]

            var yPosition: CGFloat = margin

            func startNewPage() {
                context.beginPage()
                yPosition = margin
            }

            func checkPageBreak(neededHeight: CGFloat) {
                if yPosition + neededHeight > pageHeight - margin {
                    startNewPage()
                }
            }

            // First page with title
            startNewPage()

            let title = "AiGoodbye Conversations"
            title.draw(at: CGPoint(x: margin, y: yPosition), withAttributes: titleAttributes)
            yPosition += 35

            let exportInfo = "Exported: \(dateFormatter.string(from: Date())) | \(conversations.count) conversations"
            exportInfo.draw(at: CGPoint(x: margin, y: yPosition), withAttributes: metaAttributes)
            yPosition += 40

            for conversation in conversations {
                checkPageBreak(neededHeight: 100)

                // Conversation title
                let convTitle = conversation.title
                convTitle.draw(at: CGPoint(x: margin, y: yPosition), withAttributes: headerAttributes)
                yPosition += 20

                let convMeta = "Created: \(dateFormatter.string(from: conversation.createdAt))"
                convMeta.draw(at: CGPoint(x: margin, y: yPosition), withAttributes: metaAttributes)
                yPosition += 25

                let sortedMessages = conversation.messages.sorted { $0.timestamp < $1.timestamp }
                for message in sortedMessages {
                    let roleText = message.role.rawValue.uppercased()
                    let textHeight = (message.content as NSString).boundingRect(
                        with: CGSize(width: contentWidth - 20, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: contentAttributes,
                        context: nil
                    ).height

                    checkPageBreak(neededHeight: textHeight + 30)

                    roleText.draw(at: CGPoint(x: margin, y: yPosition), withAttributes: roleAttributes)
                    yPosition += 15

                    let contentRect = CGRect(x: margin + 10, y: yPosition, width: contentWidth - 20, height: textHeight + 5)
                    message.content.draw(in: contentRect, withAttributes: contentAttributes)
                    yPosition += textHeight + 15
                }

                yPosition += 20

                // Draw separator line
                checkPageBreak(neededHeight: 10)
                let linePath = UIBezierPath()
                linePath.move(to: CGPoint(x: margin, y: yPosition))
                linePath.addLine(to: CGPoint(x: pageWidth - margin, y: yPosition))
                UIColor.lightGray.setStroke()
                linePath.stroke()
                yPosition += 20
            }
        }

        return data
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

                    if let emailURL = AppConfig.Contact.supportEmailURL {
                        Link(AppConfig.Contact.supportEmail, destination: emailURL)
                            .foregroundStyle(.blue)
                    }
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

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AppState())
    }
}
