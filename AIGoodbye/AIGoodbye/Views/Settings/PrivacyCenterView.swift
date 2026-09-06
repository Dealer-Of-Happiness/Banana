//
//  PrivacyCenterView.swift
//  AIGoodbye
//
//  Don't just claim privacy - prove it. Shows what the app can access, a
//  live log of every network request it has made, and a one-tap offline
//  test the user can run themselves.
//

import SwiftUI
import Network
import Combine
import UIKit

struct PrivacyCenterView: View {
    @ObservedObject private var audit = NetworkAudit.shared
    @StateObject private var reachability = Reachability()
    @State private var showAllEvents = false

    var body: some View {
        List {
            headline

            offlineTest

            networkLog

            dataMap

            permissions
        }
        .navigationTitle("Privacy Center")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var headline: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing you say leaves this device")
                            .font(.headline)
                        Text("No servers, no accounts, no analytics, no tracking.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Every answer is produced by a model running on your own hardware. The app only uses the internet to download a model you asked for, or to check one you asked to add. Your messages, files and recordings are never sent anywhere.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var offlineTest: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: reachability.isOnline ? "wifi" : "airplane")
                    .font(.title3)
                    .foregroundStyle(reachability.isOnline ? .blue : .green)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(reachability.isOnline
                         ? L10n.text("This device is online")
                         : L10n.text("This device is offline"))
                        .font(.subheadline.weight(.medium))
                    Text(reachability.isOnline
                         ? L10n.text("Turn on Airplane Mode, then come back and chat. Everything keeps working.")
                         : L10n.text("Go ahead and chat now - the AI still answers, with no connection at all."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        } header: {
            Text("Prove it yourself")
        }
    }

    private var networkLog: some View {
        Section {
            HStack {
                Label("Requests since install", systemImage: "arrow.up.arrow.down")
                Spacer()
                Text("\(audit.totalCount)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)

            if audit.events.isEmpty {
                Label("No network requests this session", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                ForEach(showAllEvents ? audit.events : Array(audit.events.prefix(5))) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.host)
                            .font(.subheadline)
                        Text(event.purpose)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(event.date.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                }

                if audit.events.count > 5 {
                    Button(showAllEvents ? L10n.text("Show Less") : L10n.text("Show All")) {
                        showAllEvents.toggle()
                    }
                }
            }
        } header: {
            Text("Network activity")
        } footer: {
            Text("Requests made by the app are recorded here on your device. Model downloads from Hugging Face are the only ones you should ever see.")
        }
    }

    private var dataMap: some View {
        Section {
            dataRow("Your messages", L10n.text("Stored on this device"), "bubble.left.and.text.bubble.right")
            dataRow("Photos and documents you attach", L10n.text("Read on this device, never uploaded"), "doc.on.doc")
            dataRow("Voice", L10n.text("Recognized on this device by Apple's offline engine"), "waveform")
            dataRow("Memory and library", L10n.text("Stored on this device (included in your iCloud backup, if you use one)"), "brain.head.profile")
            dataRow("Analytics", L10n.text("None collected"), "chart.bar.xaxis")
            dataRow("Advertising", L10n.text("None, ever"), "megaphone")
        } header: {
            Text("Where your data goes")
        }
    }

    private func dataRow(_ title: LocalizedStringKey, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.blue)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var permissions: some View {
        Section {
            Text("The app asks for the camera, microphone and speech recognition only when you use those features, and works fully without them.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                Label("Review permissions in Settings", systemImage: "gear")
            }
        } header: {
            Text("Permissions")
        }
    }
}

// MARK: - Reachability

@MainActor
final class Reachability: ObservableObject {
    @Published private(set) var isOnline: Bool

    private let monitor = NWPathMonitor()

    init() {
        // Seed from the current path so an offline device never briefly
        // claims to be online.
        isOnline = monitor.currentPath.status == .satisfied
        monitor.pathUpdateHandler = { [weak self] path in
            let owner = self
            let online = path.status == .satisfied
            Task { @MainActor in
                owner?.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "aig.reachability"))
    }

    deinit {
        monitor.cancel()
    }
}
