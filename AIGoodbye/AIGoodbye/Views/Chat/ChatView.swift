//
//  ChatView.swift
//  AIGoodbye
//
//  Main chat interface with text input
//

import SwiftUI
import Combine
import UIKit

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Show model picker or empty state when no messages
                if viewModel.messages.isEmpty {
                    emptyStateView
                } else {
                    messagesScrollView
                }

                Divider()

                // Input area
                inputArea
            }
            .navigationTitle(appState.currentConversation?.title ?? "New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        appState.toggleSideMenu()
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text("AiGoodbye")
                        .font(.headline)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            viewModel.regenerateLastResponse()
                        } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                        }

                        Button(role: .destructive) {
                            viewModel.clearConversation()
                        } label: {
                            Label("Clear Chat", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear {
            viewModel.appState = appState
            viewModel.loadConversation(appState.currentConversation)
        }
        .onChange(of: appState.currentConversation) { _, newConversation in
            viewModel.loadConversation(newConversation)
        }
    }

    // MARK: - Messages Scroll View

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id.uuidString)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = message.content
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }

                                ShareLink(item: message.content) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }

                                if message.role == .assistant {
                                    Button {
                                        viewModel.regenerateResponse(for: message)
                                    } label: {
                                        Label("Regenerate", systemImage: "arrow.clockwise")
                                    }
                                }
                            }
                    }

                    if viewModel.isGenerating {
                        TypingIndicator()
                            .id("typing")
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation {
                    proxy.scrollTo(viewModel.messages.last?.id.uuidString ?? "typing", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Empty State View

    private var emptyStateView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 100)

                // Logo
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text("Start a Conversation")
                    .font(.title2.bold())

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Text input
                TextField("Message...", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                // Send button
                Button {
                    isInputFocused = false
                    Task { await viewModel.sendMessage() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(viewModel.inputText.isEmpty ? .gray : .blue)
                }
                .disabled(viewModel.inputText.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

}

// MARK: - Chat View Model

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var inputText = ""
    @Published var isGenerating = false

    var appState: AppState?
    private var currentConversationId: UUID?

    func loadConversation(_ conversation: Conversation?) {
        // Clear messages when switching to a new or different conversation
        if conversation?.id != currentConversationId {
            messages.removeAll()
            currentConversationId = conversation?.id

            // Reset LLM conversation state when switching conversations
            appState?.llamaService.resetConversation()

            // Load messages from conversation if it exists
            if let conversation = conversation {
                messages = conversation.messages.sorted { $0.timestamp < $1.timestamp }

                // Restore conversation history to LLM.swift so it remembers context
                let historyForLLM = messages.map { ($0.role.rawValue, $0.content) }
                appState?.llamaService.restoreHistory(historyForLLM)
            }
        }
    }

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""

        // Ensure we have a conversation
        var conversation = appState?.currentConversation
        if conversation == nil {
            conversation = appState?.conversationManager.createConversation()
            appState?.currentConversation = conversation
            currentConversationId = conversation?.id
            // IMPORTANT: Reset LLM history when starting a brand new conversation
            appState?.llamaService.resetConversation()
        }

        // Add user message to conversation
        if let conv = conversation {
            let userMessage = appState?.conversationManager.addMessage(
                to: conv,
                role: .user,
                content: text
            )
            if let msg = userMessage {
                messages.append(msg)
            }
        }

        // Generate response
        isGenerating = true

        do {
            guard let llamaService = appState?.llamaService else { return }

            var responseText = ""

            // v2.x library handles conversation history natively
            for try await chunk in llamaService.generate(prompt: text) {
                responseText = chunk
            }

            // Add response to conversation (no placeholder needed)
            if let conv = conversation, !responseText.isEmpty {
                let assistantMessage = appState?.conversationManager.addMessage(
                    to: conv,
                    role: .assistant,
                    content: responseText
                )
                if let msg = assistantMessage {
                    messages.append(msg)
                }
            }

            // Haptic feedback if enabled
            if appState?.settings.hapticFeedbackEnabled ?? false {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
            }

        } catch {
            if let conv = conversation {
                let errorMessage = appState?.conversationManager.addMessage(
                    to: conv,
                    role: .system,
                    content: "Error: \(error.localizedDescription)"
                )
                if let msg = errorMessage {
                    messages.append(msg)
                }
            }
        }

        isGenerating = false
    }

    func regenerateLastResponse() {
        guard let lastAssistant = messages.last(where: { $0.role == .assistant }) else { return }
        regenerateResponse(for: lastAssistant)
    }

    func regenerateResponse(for message: Message) {
        guard message.role == .assistant else { return }
        guard let conversation = appState?.currentConversation else { return }

        // Find the index of this message
        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else { return }

        // Find the preceding user message to regenerate from
        var userMessageContent: String?
        for i in stride(from: messageIndex - 1, through: 0, by: -1) {
            if messages[i].role == .user {
                userMessageContent = messages[i].content
                break
            }
        }

        guard let promptText = userMessageContent else { return }

        // Remove the assistant message from SwiftData
        appState?.conversationManager.deleteMessage(message)

        // Remove from local messages array
        messages.removeAll { $0.id == message.id }

        // Rebuild LLM history without the deleted message
        let historyForLLM = messages.map { ($0.role.rawValue, $0.content) }
        appState?.llamaService.restoreHistory(historyForLLM)

        // Generate new response
        Task {
            isGenerating = true

            do {
                guard let llamaService = appState?.llamaService else { return }

                var responseText = ""
                for try await chunk in llamaService.generate(prompt: promptText) {
                    responseText = chunk
                }

                // Add new response to conversation
                if !responseText.isEmpty {
                    let assistantMessage = appState?.conversationManager.addMessage(
                        to: conversation,
                        role: .assistant,
                        content: responseText
                    )
                    if let msg = assistantMessage {
                        messages.append(msg)
                    }
                }

                // Haptic feedback
                if appState?.settings.hapticFeedbackEnabled ?? false {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                }

            } catch {
                let errorMessage = appState?.conversationManager.addMessage(
                    to: conversation,
                    role: .system,
                    content: "Error regenerating: \(error.localizedDescription)"
                )
                if let msg = errorMessage {
                    messages.append(msg)
                }
            }

            isGenerating = false
        }
    }

    func clearConversation() {
        messages.removeAll()
        // Reset LLM conversation state when clearing chat
        appState?.llamaService.resetConversation()
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // Attachment indicator
                if let attachmentType = message.attachmentType {
                    HStack(spacing: 4) {
                        Image(systemName: attachmentIcon(for: attachmentType))
                        Text(attachmentType.rawValue.capitalized)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // Message content
                Text(message.content)
                    .padding(12)
                    .background(backgroundColor)
                    .foregroundStyle(foregroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                // Timestamp (shown on tap)
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if message.role != .user { Spacer(minLength: 60) }
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user: return .blue
        case .assistant: return Color(.systemGray5)
        case .system: return .red.opacity(0.2)
        }
    }

    private var foregroundColor: Color {
        message.role == .user ? .white : .primary
    }

    private func attachmentIcon(for type: AttachmentType) -> String {
        switch type {
        case .document: return "doc.fill"
        case .image: return "photo.fill"
        case .voice: return "waveform"
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(.gray)
                        .frame(width: 8, height: 8)
                        .scaleEffect(animating ? 1 : 0.5)
                        .animation(
                            .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(i) * 0.2),
                            value: animating
                        )
                }
            }
            .padding(12)
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer()
        }
        .onAppear { animating = true }
    }
}

// MARK: - Suggestion Button

struct SuggestionButton: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ChatView()
        .environmentObject(AppState())
}
