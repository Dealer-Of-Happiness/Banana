//
//  AiGoodbyeWidgets.swift
//  AiGoodbyeWidgets
//
//  Home Screen and Lock Screen widgets, plus a Control Center control, that
//  put a private AI one tap away. Widgets never run a model - they deep-link
//  straight into the app.
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline

struct QuickAskEntry: TimelineEntry {
    let date: Date
}

struct QuickAskProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickAskEntry {
        QuickAskEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickAskEntry) -> Void) {
        completion(QuickAskEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickAskEntry>) -> Void) {
        // Static content: refresh rarely to use no battery.
        completion(Timeline(entries: [QuickAskEntry(date: Date())], policy: .never))
    }
}

// MARK: - Home Screen widget

struct QuickAskWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: QuickAskEntry

    private var chatURL: URL { URL(string: "aigoodbye://new")! }
    private var voiceURL: URL { URL(string: "aigoodbye://voice")! }
    private var cameraURL: URL { URL(string: "aigoodbye://camera")! }

    var body: some View {
        switch family {
        case .systemSmall:
            small
        case .accessoryCircular:
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title2)
                .widgetURL(chatURL)
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                VStack(alignment: .leading) {
                    Text("AiGoodbye")
                        .font(.headline)
                    Text("Private AI, offline")
                        .font(.caption)
                }
            }
            .widgetURL(chatURL)
        default:
            medium
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            Spacer()
            Text("Ask privately")
                .font(.headline)
            Text("100% on device")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(chatURL)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AiGoodbye")
                    .font(.headline)
                Text("Private AI that works offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                shortcut(symbol: "bubble.left.fill", label: "Chat", url: chatURL)
                shortcut(symbol: "waveform", label: "Voice", url: voiceURL)
                shortcut(symbol: "camera.viewfinder", label: "Camera", url: cameraURL)
            }
        }
        .padding(.vertical, 4)
        // Tapping anywhere outside the three shortcuts still opens the app.
        .widgetURL(chatURL)
    }

    private func shortcut(symbol: String, label: LocalizedStringKey, url: URL) -> some View {
        Link(destination: url) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.blue.opacity(0.15)))
                Text(label)
                    .font(.caption2)
            }
        }
    }
}

struct QuickAskWidget: Widget {
    let kind = "AiGoodbyeQuickAsk"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickAskProvider()) { entry in
            QuickAskWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AiGoodbye")
        .description("Start a private conversation, instantly.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Control Center

struct VoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "AiGoodbyeVoiceControl") {
            ControlWidgetButton(action: OpenVoiceModeIntent()) {
                Label("Talk to AiGoodbye", systemImage: "waveform")
            }
        }
        .displayName("Talk to AiGoodbye")
        .description("Start a private voice conversation.")
    }
}

/// Opens the app straight into voice mode.
struct OpenVoiceModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to AiGoodbye"
    static let openAppWhenRun = true
    static let description = IntentDescription("Opens AiGoodbye and starts a voice conversation.")

    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetLaunchBridge.requestVoiceMode()
        return .result()
    }
}

// MARK: - Bundle

@main
struct AiGoodbyeWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickAskWidget()
        VoiceControl()
    }
}
