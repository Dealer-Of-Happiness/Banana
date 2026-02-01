//
//  ChatView.swift
//  AIGoodbye
//
//  Main chat interface with text input and vision capabilities
//

import SwiftUI
import Combine
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import MLX

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @FocusState private var isInputFocused: Bool

    // Attachment state
    @State private var showingAttachmentMenu = false
    @State private var showingPhotoPicker = false
    @State private var showingCamera = false
    @State private var showingDocumentPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?

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

                // Attachment preview (if image selected)
                if let image = viewModel.pendingImage {
                    attachmentPreview(image: image)
                }

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
                    HStack(spacing: 4) {
                        Text("AiGoodbye")
                            .font(.headline)
                        // Vision indicator
                        Image(systemName: "eye.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
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
            // Photo picker sheet
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $selectedPhotoItem,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: selectedPhotoItem) { _, newItem in
                Task {
                    await viewModel.loadSelectedPhoto(newItem)
                    selectedPhotoItem = nil
                }
            }
            // Camera sheet
            .sheet(isPresented: $showingCamera) {
                CameraView { image in
                    viewModel.pendingImage = image
                    showingCamera = false
                }
            }
            // Document picker sheet
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPickerView { urls in
                    Task {
                        await viewModel.processDocuments(urls)
                    }
                    showingDocumentPicker = false
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
        // Clear GPU cache before opening camera/photo picker to prevent memory crash
        .onChange(of: showingCamera) { _, isShowing in
            if isShowing {
                GPU.Memory.clearCache()
            }
        }
        .onChange(of: showingPhotoPicker) { _, isShowing in
            if isShowing {
                GPU.Memory.clearCache()
            }
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "An error occurred")
        }
    }

    // MARK: - Messages Scroll View

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(
                            message: message,
                            image: message.attachmentId.flatMap { viewModel.getImage(for: $0) }
                        )
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
                Spacer(minLength: 80)

                // Logo with vision indicator
                ZStack {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    // Vision badge
                    Image(systemName: "eye.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white, .blue)
                        .offset(x: 35, y: -25)
                }

                Text("Start a Conversation")
                    .font(.title2.bold())

                Text("Ask questions, analyze images, or discuss documents")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // Quick action suggestions
                VStack(spacing: 12) {
                    QuickActionButton(
                        icon: "photo.fill",
                        title: "Analyze an Image",
                        subtitle: "Tap + to add a photo"
                    ) {
                        showingAttachmentMenu = true
                    }

                    QuickActionButton(
                        icon: "doc.text.fill",
                        title: "Read a Document",
                        subtitle: "Upload PDF, Word, or text files"
                    ) {
                        showingDocumentPicker = true
                    }

                    QuickActionButton(
                        icon: "text.bubble.fill",
                        title: "Just Chat",
                        subtitle: "Ask anything"
                    ) {
                        isInputFocused = true
                    }
                }
                .padding(.top, 8)

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Attachment Preview

    private func attachmentPreview(image: UIImage) -> some View {
        HStack(spacing: 12) {
            // Thumbnail
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue, lineWidth: 2)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Image attached")
                    .font(.subheadline.weight(.medium))
                Text("Will be analyzed with your message")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Remove button
            Button {
                withAnimation {
                    viewModel.pendingImage = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Attachment button (+)
                Menu {
                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        showingCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }

                    Button {
                        showingDocumentPicker = true
                    } label: {
                        Label("Document", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                        .foregroundStyle(.blue)
                }

                // Text input
                TextField(viewModel.pendingImage != nil ? "Ask about this image..." : "Message...", text: $viewModel.inputText, axis: .vertical)
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
                        .foregroundStyle(canSend ? .blue : .gray)
                }
                .disabled(!canSend)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    // Can send if there's text OR an image attached
    private var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        viewModel.pendingImage != nil
    }
}

// MARK: - Quick Action Button

struct QuickActionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chat View Model

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var inputText = ""
    @Published var isGenerating = false
    @Published var pendingImage: UIImage?
    @Published var pendingImageId: UUID?
    @Published var errorMessage: String?

    var appState: AppState?
    private var currentConversationId: UUID?

    // Store images by ID for display in message bubbles
    private var imageCache: [UUID: UIImage] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    init() {
        // Listen for memory warnings to clear image cache
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMemoryWarning()
            }
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleMemoryWarning() {
        // Clear image cache to free memory
        let clearedCount = imageCache.count
        imageCache.removeAll()
        pendingImage = nil
        print("[ChatViewModel] Memory warning: Cleared \(clearedCount) cached images")
    }

    func loadConversation(_ conversation: Conversation?) {
        // Clear messages when switching to a new or different conversation
        if conversation?.id != currentConversationId {
            messages.removeAll()
            pendingImage = nil
            pendingImageId = nil
            currentConversationId = conversation?.id

            // Clear image cache to prevent memory accumulation
            imageCache.removeAll()

            // Reset MLX conversation state when switching conversations
            appState?.mlxService.resetConversation()

            // Load messages from conversation if it exists
            if let conversation = conversation {
                messages = conversation.messages.sorted { $0.timestamp < $1.timestamp }

                // Restore conversation history to MLX so it remembers context
                let historyForLLM = messages.map { ($0.role.rawValue, $0.content) }
                appState?.mlxService.restoreHistory(historyForLLM)

                // Load cached images for messages with attachments
                loadCachedImages(for: conversation)
            }
        }
    }

    /// Remove an image from the cache when it's deleted
    func removeImageFromCache(_ imageId: UUID) {
        imageCache.removeValue(forKey: imageId)
    }

    private func loadCachedImages(for conversation: Conversation) {
        for imageId in conversation.attachedImageIds {
            if let imagePath = getImagePath(for: imageId),
               let image = UIImage(contentsOfFile: imagePath.path) {
                imageCache[imageId] = image
            }
        }
    }

    func getImage(for id: UUID) -> UIImage? {
        imageCache[id]
    }

    // MARK: - Photo Handling

    func loadSelectedPhoto(_ item: PhotosPickerItem?) async {
        guard let item = item else { return }

        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                // Resize image immediately to prevent memory issues
                let resizedImage = AppConfig.Image.resizeForMemory(image)
                await MainActor.run {
                    self.pendingImage = resizedImage
                    self.pendingImageId = UUID()
                }
            }
        } catch {
            print("[ChatViewModel] Error loading photo: \(error)")
        }
    }

    // MARK: - Document Handling

    func processDocuments(_ urls: [URL]) async {
        guard let url = urls.first else { return }
        guard let documentService = appState?.documentService else {
            await MainActor.run {
                self.inputText = "Error: Document service not available"
            }
            return
        }

        do {
            // Use DocumentService for proper text extraction (handles PDF, DOCX, TXT, RTF)
            let processedDoc = try await documentService.processDocument(at: url)

            // Limit content to prevent memory issues
            let truncatedContent: String
            if processedDoc.fullText.count > AppConfig.Document.contentLimit {
                truncatedContent = String(processedDoc.fullText.prefix(AppConfig.Document.contentLimit)) + "\n\n[Content truncated for memory efficiency...]"
            } else {
                truncatedContent = processedDoc.fullText
            }

            // Create a message with the document content
            let documentPrompt = """
            I've uploaded a document: \(processedDoc.name)
            Type: \(processedDoc.type.rawValue.uppercased())

            Content:
            \(truncatedContent)

            Please analyze this document and provide a summary.
            """

            await MainActor.run {
                self.inputText = documentPrompt
            }

        } catch {
            print("[ChatViewModel] Error processing document: \(error)")
            await MainActor.run {
                self.inputText = "Error reading document: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Send Message

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage

        // Need either text or image
        guard !text.isEmpty || image != nil else { return }

        // Clear input immediately
        inputText = ""
        let capturedImage = pendingImage
        let capturedImageId = pendingImageId
        pendingImage = nil
        pendingImageId = nil

        // Ensure we have a conversation
        var conversation = appState?.currentConversation
        if conversation == nil {
            conversation = appState?.conversationManager.createConversation()
            appState?.currentConversation = conversation
            currentConversationId = conversation?.id
            appState?.mlxService.resetConversation()
        }

        // Determine the prompt
        let prompt = text.isEmpty ? "What's in this image?" : text

        // Add user message to conversation
        if let conv = conversation {
            let userMessage = appState?.conversationManager.addMessage(
                to: conv,
                role: .user,
                content: prompt,
                attachmentType: capturedImage != nil ? .image : nil,
                attachmentId: capturedImageId
            )
            if let msg = userMessage {
                messages.append(msg)

                // Cache the image if present
                if let image = capturedImage, let imageId = capturedImageId {
                    imageCache[imageId] = image
                    saveImage(image, withId: imageId)

                    // Track in conversation
                    conv.attachedImageIds.append(imageId)
                }
            }
        }

        // Generate response
        isGenerating = true

        do {
            guard let mlxService = appState?.mlxService else {
                errorMessage = "AI service not available. Please restart the app."
                isGenerating = false
                return
            }

            var responseText = ""

            if let image = capturedImage {
                // Vision generation with image
                for try await chunk in mlxService.generateWithVision(prompt: prompt, image: image) {
                    responseText = chunk
                }
            } else {
                // Text-only generation
                for try await chunk in mlxService.generate(prompt: prompt) {
                    responseText = chunk
                }
            }

            // Add response to conversation
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

    // MARK: - Regenerate

    func regenerateLastResponse() {
        guard let lastAssistant = messages.last(where: { $0.role == .assistant }) else { return }
        regenerateResponse(for: lastAssistant)
    }

    func regenerateResponse(for message: Message) {
        guard message.role == .assistant else { return }
        guard let conversation = appState?.currentConversation else {
            errorMessage = "No active conversation. Please start a new chat."
            return
        }

        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else { return }

        // Find the preceding user message
        var userMessageContent: String?
        var userMessageImage: UIImage?
        for i in stride(from: messageIndex - 1, through: 0, by: -1) {
            if messages[i].role == .user {
                userMessageContent = messages[i].content
                if let imageId = messages[i].attachmentId {
                    userMessageImage = imageCache[imageId]
                }
                break
            }
        }

        guard let promptText = userMessageContent else { return }

        // Remove the assistant message
        appState?.conversationManager.deleteMessage(message)
        messages.removeAll { $0.id == message.id }

        // Rebuild history
        let historyForLLM = messages.map { ($0.role.rawValue, $0.content) }
        appState?.mlxService.restoreHistory(historyForLLM)

        // Generate new response
        Task {
            isGenerating = true

            do {
                guard let mlxService = appState?.mlxService else {
                    errorMessage = "AI service not available. Please restart the app."
                    isGenerating = false
                    return
                }

                var responseText = ""

                if let image = userMessageImage {
                    for try await chunk in mlxService.generateWithVision(prompt: promptText, image: image) {
                        responseText = chunk
                    }
                } else {
                    for try await chunk in mlxService.generate(prompt: promptText) {
                        responseText = chunk
                    }
                }

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
        pendingImage = nil
        pendingImageId = nil
        imageCache.removeAll()
        appState?.mlxService.resetConversation()
    }

    // MARK: - Image Storage

    private func saveImage(_ image: UIImage, withId id: UUID) {
        guard let data = image.jpegData(compressionQuality: AppConfig.Image.compressionQuality),
              let path = getImagePath(for: id) else { return }
        try? data.write(to: path)
    }

    private func getImagePath(for id: UUID) -> URL? {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let imagesDir = documentsPath.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        return imagesDir.appendingPathComponent("\(id.uuidString).jpg")
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message
    var image: UIImage? = nil

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // Image attachment (if present)
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 250, maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                        )
                }

                // Attachment indicator (for documents/voice)
                if let attachmentType = message.attachmentType, attachmentType != .image {
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
                    .textSelection(.enabled)

                // Timestamp
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

// MARK: - Camera View

struct CameraView: UIViewControllerRepresentable {
    let onImageCaptured: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImageCaptured: onImageCaptured)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImageCaptured: (UIImage) -> Void

        init(onImageCaptured: @escaping (UIImage) -> Void) {
            self.onImageCaptured = onImageCaptured
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                // Resize image immediately to prevent memory issues
                let resizedImage = AppConfig.Image.resizeForMemory(image)
                onImageCaptured(resizedImage)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - Document Picker View

struct DocumentPickerView: UIViewControllerRepresentable {
    let onDocumentsPicked: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let supportedTypes: [UTType] = [
            .pdf,
            .plainText,
            .json,
            .html,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "swift") ?? .sourceCode,
            UTType(filenameExtension: "py") ?? .sourceCode,
            UTType(filenameExtension: "js") ?? .sourceCode,
            .sourceCode
        ]

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDocumentsPicked: onDocumentsPicked)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDocumentsPicked: ([URL]) -> Void

        init(onDocumentsPicked: @escaping ([URL]) -> Void) {
            self.onDocumentsPicked = onDocumentsPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onDocumentsPicked(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // Do nothing
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
