//
//  FeedbackMail.swift
//  AIGoodbye
//
//  "Send Feedback": an email to the developer with the details that make a
//  report useful (app version, device, iOS, the model in use, how much memory
//  iOS gives the app) already filled in. Nothing from conversations is
//  included, and nothing is sent until the person taps Send in Mail.
//

import SwiftUI
import MessageUI
import UIKit

enum FeedbackMail {

    static let address = "marketing@dealerofhappiness.com"

    /// The device's model identifier ("iPhone14,6"), which says exactly which
    /// phone it is - the marketing name alone doesn't distinguish RAM sizes.
    static var deviceIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }

    /// The details block at the bottom of the email. English on purpose:
    /// it is for the developer, whatever language the app is in.
    @MainActor
    static func details(modelName: String, languageName: String) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let system = ProcessInfo.processInfo.isiOSAppOnMac
            ? "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
            : "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000_000
        var lines = [
            "AiGoodbye \(version) (\(build))",
            "\(deviceIdentifier), \(system)",
            String(format: "Device memory: %.1f GB", ram),
        ]
        if let limit = DeviceCapability.appMemoryLimitBytes {
            lines.append(String(format: "Memory iOS gives the app: %.1f GB", Double(limit) / 1_000_000_000))
        }
        lines.append("Model: \(modelName)")
        lines.append("App language: \(languageName)")
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func body(details: String) -> String {
        "\n\n\n" + L10n.text("Please keep the details below. They help us find the problem.") + "\n---\n" + details
    }

    static func mailtoURL(subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }
}

/// Mail's compose sheet, prefilled.
struct FeedbackMailComposer: UIViewControllerRepresentable {
    let subject: String
    let body: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.setToRecipients([FeedbackMail.address])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        controller.mailComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            dismiss()
        }
    }
}

/// Makes any button send feedback: Mail's own sheet when Mail is set up,
/// otherwise whichever mail app handles mailto:, and if there is none, the
/// address to copy.
struct SendFeedbackModifier: ViewModifier {
    @Binding var isPresented: Bool
    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL
    @State private var showComposer = false
    @State private var showAddress = false

    private var subject: String { L10n.text("AiGoodbye feedback") }

    private var mailBody: String {
        FeedbackMail.body(details: FeedbackMail.details(
            modelName: appState.engine.selectedModel.name,
            languageName: appState.settings.appLanguage.displayName
        ))
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, wanted in
                guard wanted else { return }
                isPresented = false
                if MFMailComposeViewController.canSendMail() {
                    showComposer = true
                } else if let url = FeedbackMail.mailtoURL(subject: subject, body: mailBody) {
                    openURL(url) { accepted in
                        if !accepted { showAddress = true }
                    }
                } else {
                    showAddress = true
                }
            }
            .sheet(isPresented: $showComposer) {
                FeedbackMailComposer(subject: subject, body: mailBody)
                    .ignoresSafeArea()
            }
            .alert(Text("Send Feedback"), isPresented: $showAddress) {
                Button {
                    UIPasteboard.general.string = FeedbackMail.address
                } label: {
                    Text("Copy Address")
                }
                Button(role: .cancel) {} label: { Text("OK") }
            } message: {
                Text(L10n.text("No mail app is set up on this device. Write to \(FeedbackMail.address) from any email account."))
            }
    }
}

extension View {
    func sendFeedback(isPresented: Binding<Bool>) -> some View {
        modifier(SendFeedbackModifier(isPresented: isPresented))
    }
}
