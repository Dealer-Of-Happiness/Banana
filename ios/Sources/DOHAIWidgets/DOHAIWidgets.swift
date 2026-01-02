//
//  DOHAIWidgets.swift
//  AI goodbye Widgets
//
//  Home screen widgets for quick access
//

import WidgetKit
import SwiftUI

// MARK: - Widget Bundle

@main
struct DOHAIWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickVoiceWidget()
        QuickTextWidget()
    }
}

// MARK: - Quick Voice Widget

struct QuickVoiceWidget: Widget {
    let kind: String = "QuickVoiceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VoiceWidgetProvider()) { entry in
            VoiceWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick Voice")
        .description("Tap to start a voice conversation")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct VoiceWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoiceWidgetEntry {
        VoiceWidgetEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (VoiceWidgetEntry) -> Void) {
        completion(VoiceWidgetEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceWidgetEntry>) -> Void) {
        let entry = VoiceWidgetEntry(date: Date())
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

struct VoiceWidgetEntry: TimelineEntry {
    let date: Date
}

struct VoiceWidgetView: View {
    var entry: VoiceWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Link(destination: URL(string: "dohai://voice")!) {
            VStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: family == .systemSmall ? 40 : 50))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if family == .systemMedium {
                    Text("Tap to speak")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("AI goodbye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Quick Text Widget

struct QuickTextWidget: Widget {
    let kind: String = "QuickTextWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TextWidgetProvider()) { entry in
            TextWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick Chat")
        .description("Quick access to AI goodbye chat")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TextWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TextWidgetEntry {
        TextWidgetEntry(date: Date(), lastChat: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (TextWidgetEntry) -> Void) {
        completion(TextWidgetEntry(date: Date(), lastChat: "How can I help you today?"))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TextWidgetEntry>) -> Void) {
        // Load last chat from shared container
        let lastChat = UserDefaults(suiteName: "group.com.aigoodbye")?.string(forKey: "lastAIResponse")

        let entry = TextWidgetEntry(date: Date(), lastChat: lastChat)
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3600)))
        completion(timeline)
    }
}

struct TextWidgetEntry: TimelineEntry {
    let date: Date
    let lastChat: String?
}

struct TextWidgetView: View {
    var entry: TextWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Link(destination: URL(string: "dohai://chat")!) {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(.blue)
                    Text("AI goodbye")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "arrow.up.right.circle.fill")
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Last response or placeholder
                if let lastChat = entry.lastChat {
                    Text(lastChat)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(family == .systemLarge ? 6 : 3)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "message.fill")
                            .font(.title2)
                            .foregroundStyle(.blue.opacity(0.5))

                        Text("Tap to start chatting")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Spacer()

                // Quick actions for large widget
                if family == .systemLarge {
                    HStack(spacing: 12) {
                        QuickActionButton(icon: "mic.fill", label: "Voice", url: "dohai://voice")
                        QuickActionButton(icon: "doc.fill", label: "Document", url: "dohai://document")
                        QuickActionButton(icon: "camera.fill", label: "Photo", url: "dohai://camera")
                    }
                }
            }
            .padding()
        }
    }
}

struct QuickActionButton: View {
    let icon: String
    let label: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .foregroundStyle(.blue)
    }
}

// MARK: - Previews

#Preview("Voice Small", as: .systemSmall) {
    QuickVoiceWidget()
} timeline: {
    VoiceWidgetEntry(date: Date())
}

#Preview("Voice Medium", as: .systemMedium) {
    QuickVoiceWidget()
} timeline: {
    VoiceWidgetEntry(date: Date())
}

#Preview("Text Medium", as: .systemMedium) {
    QuickTextWidget()
} timeline: {
    TextWidgetEntry(date: Date(), lastChat: "The capital of France is Paris.")
}

#Preview("Text Large", as: .systemLarge) {
    QuickTextWidget()
} timeline: {
    TextWidgetEntry(date: Date(), lastChat: "The capital of France is Paris. It's known for the Eiffel Tower and rich cultural heritage.")
}
