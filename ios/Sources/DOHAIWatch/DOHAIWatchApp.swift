//
//  DOHAIWatchApp.swift
//  AI goodbye Watch
//
//  Apple Watch companion app
//

import SwiftUI
import WatchKit

@main
struct DOHAIWatchApp: App {
    @StateObject private var appState = WatchAppState()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(appState)
        }
    }
}

// MARK: - Watch App State

@MainActor
class WatchAppState: ObservableObject {
    @Published var isConnected = false
    @Published var isProcessing = false
    @Published var currentResponse = ""
    @Published var recentChats: [WatchChatItem] = []

    init() {
        // Load recent chats from local storage
        loadRecentChats()
    }

    func loadRecentChats() {
        // Load from UserDefaults or shared container
        recentChats = [
            WatchChatItem(query: "Weather today?", response: "It's sunny and 72°F"),
            WatchChatItem(query: "Next meeting?", response: "Team sync at 2:00 PM"),
        ]
    }

    func sendQuery(_ query: String) async {
        isProcessing = true

        // In production, communicate with iPhone or process locally if Watch has capability
        // For now, simulate response
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        currentResponse = "I received: \(query). In a full implementation, this would be processed by the AI."
        recentChats.insert(WatchChatItem(query: query, response: currentResponse), at: 0)

        // Haptic feedback
        WKInterfaceDevice.current().play(.success)

        isProcessing = false
    }
}

struct WatchChatItem: Identifiable {
    let id = UUID()
    let query: String
    let response: String
    let timestamp = Date()
}

// MARK: - Watch Content View

struct WatchContentView: View {
    @EnvironmentObject var appState: WatchAppState

    var body: some View {
        NavigationStack {
            List {
                // Voice input section
                Section {
                    NavigationLink {
                        WatchVoiceView()
                    } label: {
                        Label("Voice Chat", systemImage: "mic.fill")
                            .foregroundStyle(.blue)
                    }
                }

                // Recent chats
                if !appState.recentChats.isEmpty {
                    Section("Recent") {
                        ForEach(appState.recentChats.prefix(5)) { chat in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chat.query)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                Text(chat.response)
                                    .font(.caption)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("AI goodbye")
        }
    }
}

// MARK: - Watch Voice View

struct WatchVoiceView: View {
    @EnvironmentObject var appState: WatchAppState
    @State private var isListening = false
    @State private var transcribedText = ""

    var body: some View {
        VStack(spacing: 16) {
            if appState.isProcessing {
                ProgressView()
                    .progressViewStyle(.circular)
                Text("Processing...")
                    .font(.caption)
            } else if !appState.currentResponse.isEmpty {
                ScrollView {
                    Text(appState.currentResponse)
                        .font(.body)
                }

                Button("New Question") {
                    appState.currentResponse = ""
                    transcribedText = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            } else {
                Spacer()

                Button {
                    if isListening {
                        stopListening()
                    } else {
                        startListening()
                    }
                } label: {
                    Image(systemName: isListening ? "stop.fill" : "mic.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(isListening ? .red : .blue)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Text(isListening ? "Listening..." : "Tap to speak")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !transcribedText.isEmpty {
                    Text(transcribedText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }
        }
        .padding()
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func startListening() {
        isListening = true
        // Start voice recognition
        WKInterfaceDevice.current().play(.start)

        // Simulate voice recognition
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            transcribedText = "Sample transcribed text"
            stopListening()
        }
    }

    private func stopListening() {
        isListening = false
        WKInterfaceDevice.current().play(.stop)

        if !transcribedText.isEmpty {
            Task {
                await appState.sendQuery(transcribedText)
            }
        }
    }
}

// MARK: - Complications

import ClockKit

class ComplicationController: NSObject, CLKComplicationDataSource {

    func getCurrentTimelineEntry(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationTimelineEntry?) -> Void
    ) {
        let template = createTemplate(for: complication)
        if let template = template {
            let entry = CLKComplicationTimelineEntry(
                date: Date(),
                complicationTemplate: template
            )
            handler(entry)
        } else {
            handler(nil)
        }
    }

    func getLocalizableSampleTemplate(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationTemplate?) -> Void
    ) {
        handler(createTemplate(for: complication))
    }

    private func createTemplate(for complication: CLKComplication) -> CLKComplicationTemplate? {
        switch complication.family {
        case .circularSmall:
            return CLKComplicationTemplateCircularSmallSimpleImage(
                imageProvider: CLKImageProvider(onePieceImage: UIImage(systemName: "brain.head.profile")!)
            )

        case .modularSmall:
            return CLKComplicationTemplateModularSmallSimpleImage(
                imageProvider: CLKImageProvider(onePieceImage: UIImage(systemName: "brain.head.profile")!)
            )

        case .graphicCircular:
            return CLKComplicationTemplateGraphicCircularImage(
                imageProvider: CLKFullColorImageProvider(fullColorImage: UIImage(systemName: "brain.head.profile")!)
            )

        case .graphicCorner:
            return CLKComplicationTemplateGraphicCornerTextImage(
                textProvider: CLKTextProvider(format: "AI goodbye"),
                imageProvider: CLKFullColorImageProvider(fullColorImage: UIImage(systemName: "brain.head.profile")!)
            )

        default:
            return nil
        }
    }
}

// MARK: - Previews

#Preview {
    WatchContentView()
        .environmentObject(WatchAppState())
}
