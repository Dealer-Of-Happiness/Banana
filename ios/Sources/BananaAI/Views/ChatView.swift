//
//  ChatView.swift
//  BananaAI
//
//  Interactive chat interface with the local AI
//

import SwiftUI

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Chat messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
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
                            proxy.scrollTo(viewModel.messages.last?.id ?? "typing", anchor: .bottom)
                        }
                    }
                }

                Divider()

                // Input area
                HStack(spacing: 12) {
                    TextField("Ask anything...", text: $viewModel.inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($isInputFocused)
                        .onSubmit {
                            Task { await sendMessage() }
                        }

                    Button {
                        Task { await sendMessage() }
                    } label: {
                        Image(systemName: viewModel.isGenerating ? "stop.fill" : "arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(viewModel.inputText.isEmpty ? .gray : .yellow)
                    }
                    .disabled(viewModel.inputText.isEmpty && !viewModel.isGenerating)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Chat")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack {
                        Circle()
                            .fill(appState.settings.useInternet ? .green : .yellow)
                            .frame(width: 8, height: 8)
                        Text(appState.settings.useInternet ? "Online" : "Offline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.clearChat()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .onAppear {
            viewModel.aiEngine = appState.aiEngine
        }
    }

    private func sendMessage() async {
        guard !viewModel.inputText.isEmpty else { return }
        isInputFocused = false
        await viewModel.sendMessage()
    }
}

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText = ""
    @Published var isGenerating = false

    var aiEngine: LocalAIEngine?

    func sendMessage() async {
        let userMessage = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userMessage.isEmpty, let engine = aiEngine else { return }

        inputText = ""
        messages.append(ChatMessage(role: .user, content: userMessage))
        isGenerating = true

        do {
            var responseText = ""
            let assistantMessage = ChatMessage(role: .assistant, content: "")
            messages.append(assistantMessage)

            // Stream response from local AI
            for try await chunk in engine.generate(prompt: userMessage, history: messages.dropLast()) {
                responseText += chunk
                if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                    messages[index].content = responseText
                }
            }

        } catch {
            messages.append(ChatMessage(role: .system, content: "Error: \(error.localizedDescription)"))
        }

        isGenerating = false
    }

    func clearChat() {
        messages.removeAll()
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    var content: String
    let timestamp = Date()

    enum MessageRole {
        case user, assistant, system
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(12)
                    .background(backgroundColor)
                    .foregroundStyle(foregroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if message.role == .assistant {
                    Text("Local AI")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
}

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

#Preview {
    ChatView()
        .environmentObject(AppState())
}
