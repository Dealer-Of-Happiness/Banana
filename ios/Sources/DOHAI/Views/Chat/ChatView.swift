//
//  ChatView.swift
//  DOH AI
//
//  Main chat interface with voice and text input
//

import SwiftUI
import PhotosUI

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @FocusState private var isInputFocused: Bool
    @State private var showVoiceInput = false
    @State private var showAttachmentOptions = false
    @State private var showDocumentPicker = false
    @State private var showImagePicker = false
    @State private var showCamera = false
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Chat messages
                messagesScrollView

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
            .sheet(isPresented: $showVoiceInput) {
                VoiceInputView(viewModel: viewModel)
            }
            .sheet(isPresented: $showDocumentPicker) {
                DocumentPickerView { urls in
                    Task {
                        await viewModel.processDocuments(urls)
                    }
                }
            }
            .photosPicker(
                isPresented: $showImagePicker,
                selection: $selectedPhoto,
                matching: .images
            )
            .onChange(of: selectedPhoto) { _, newValue in
                if let item = newValue {
                    Task {
                        await viewModel.processPhoto(item)
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraView { image in
                    Task {
                        await viewModel.analyzeImage(image)
                    }
                }
            }
        }
        .onAppear {
            viewModel.appState = appState
        }
    }

    // MARK: - Messages Scroll View

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
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
                    proxy.scrollTo(viewModel.messages.last?.id ?? "typing", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 8) {
            // Attachment preview
            if !viewModel.attachments.isEmpty {
                attachmentPreview
            }

            HStack(spacing: 12) {
                // Attachment button
                Button {
                    showAttachmentOptions = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .confirmationDialog("Add Attachment", isPresented: $showAttachmentOptions) {
                    Button {
                        showDocumentPicker = true
                    } label: {
                        Label("Document", systemImage: "doc.fill")
                    }

                    Button {
                        showImagePicker = true
                    } label: {
                        Label("Photo Library", systemImage: "photo.fill")
                    }

                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera.fill")
                    }

                    Button("Cancel", role: .cancel) {}
                }

                // Text input
                TextField("Message...", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                // Voice/Send button
                if viewModel.inputText.isEmpty {
                    Button {
                        showVoiceInput = true
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                } else {
                    Button {
                        isInputFocused = false
                        Task { await viewModel.sendMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(.blue)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    // MARK: - Attachment Preview

    private var attachmentPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(viewModel.attachments, id: \.self) { attachment in
                    AttachmentChip(
                        name: attachment,
                        onRemove: {
                            viewModel.removeAttachment(attachment)
                        }
                    )
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Chat View Model

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var inputText = ""
    @Published var isGenerating = false
    @Published var attachments: [String] = []

    var appState: AppState?

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""

        // Add user message
        let userMessage = Message(role: .user, content: text)
        messages.append(userMessage)

        // Generate response
        isGenerating = true

        do {
            guard let llamaService = appState?.llamaService else { return }

            var responseText = ""
            let assistantMessage = Message(role: .assistant, content: "")
            messages.append(assistantMessage)

            for try await chunk in llamaService.generate(
                prompt: text,
                history: messages.dropLast(2).map { ($0.role.rawValue, $0.content) }
            ) {
                responseText += chunk
                if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                    messages[index].content = responseText
                }
            }

            // Haptic feedback if enabled
            if appState?.settings.hapticFeedbackEnabled ?? false {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
            }

        } catch {
            let errorMessage = Message(role: .system, content: "Error: \(error.localizedDescription)")
            messages.append(errorMessage)
        }

        isGenerating = false
        attachments.removeAll()
    }

    func sendVoiceMessage(_ text: String) async {
        inputText = text
        await sendMessage()
    }

    func processDocuments(_ urls: [URL]) async {
        for url in urls {
            attachments.append(url.lastPathComponent)
            // Process document through document service
        }
    }

    func processPhoto(_ item: PhotosPickerItem) async {
        if let data = try? await item.loadTransferable(type: Data.self) {
            attachments.append("Photo")
            // Process image
        }
    }

    func analyzeImage(_ image: UIImage) async {
        attachments.append("Camera Photo")
        // Analyze with vision model
    }

    func removeAttachment(_ name: String) {
        attachments.removeAll { $0 == name }
    }

    func regenerateLastResponse() {
        guard let lastAssistant = messages.last(where: { $0.role == .assistant }) else { return }
        regenerateResponse(for: lastAssistant)
    }

    func regenerateResponse(for message: Message) {
        // Find and regenerate
    }

    func clearConversation() {
        messages.removeAll()
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

                // Voice indicator
                if message.isVoiceMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                        Text("Voice message")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

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

// MARK: - Attachment Chip

struct AttachmentChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "paperclip")
                .font(.caption)

            Text(name)
                .font(.caption)
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemGray5))
        .clipShape(Capsule())
    }
}

// MARK: - Supporting Views

struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf, .plainText, .text, .rtf])
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

struct CameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: dismiss)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let dismiss: DismissAction

        init(onCapture: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

#Preview {
    ChatView()
        .environmentObject(AppState())
}
