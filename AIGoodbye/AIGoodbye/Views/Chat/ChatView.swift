//
//  ChatView.swift
//  AIGoodbye
//
//  Main chat interface.
//
//  v3.0: live streaming responses, Stop button, Markdown rendering,
//  honest error bubbles with Retry, download consent, fixed Clear Chat,
//  fixed document regeneration, and full accessibility labels.
//

import SwiftUI
import Combine
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import PDFKit

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @FocusState private var isInputFocused: Bool

    // Attachment state
    @State private var showingPhotoPicker = false
    @State private var showingCamera = false
    @State private var showingDocumentPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingCameraUnavailableAlert = false
    @State private var showingClearConfirmation = false
    @State private var showingModelPicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if viewModel.messages.isEmpty && viewModel.streamingText == nil {
                    emptyStateView
                } else {
                    messagesScrollView
                }

                // Inline error banner with Retry
                if let error = viewModel.errorBanner {
                    errorBanner(error)
                }

                Divider()

                // Engine status chip (download progress, preparing, etc.)
                engineStatusChip

                if let image = viewModel.pendingImage {
                    attachmentPreview(image: image)
                }

                if let docName = viewModel.pendingDocumentName {
                    documentPreview(name: docName)
                }

                inputArea
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
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
            .sheet(isPresented: $showingCamera) {
                CameraView { image in
                    viewModel.pendingImage = image
                    viewModel.pendingImageId = UUID()
                    showingCamera = false
                }
            }
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPickerView { urls in
                    Task {
                        await viewModel.processDocuments(urls)
                    }
                    showingDocumentPicker = false
                }
            }
            .sheet(isPresented: $showingModelPicker) {
                ModelSelectionView()
                    .environmentObject(appState)
            }
            .sheet(item: $viewModel.consentRequest) { request in
                ModelDownloadConsentSheet(
                    model: request.model,
                    reason: request.reason,
                    onApprove: {
                        viewModel.approveConsentAndResend()
                    },
                    onCancel: {
                        viewModel.consentRequest = nil
                    }
                )
                .presentationDetents([.medium])
            }
            .alert("Camera Unavailable", isPresented: $showingCameraUnavailableAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Camera is not available on this device. Please use Photo Library instead.")
            }
            .alert("Couldn't Add Attachment", isPresented: $viewModel.showingImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.importErrorMessage)
            }
            .confirmationDialog(
                "Clear this chat?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Chat", role: .destructive) {
                    viewModel.clearConversation()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All messages in this conversation will be deleted. This can't be undone.")
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                appState.toggleSideMenu()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("Conversations menu"))
        }

        ToolbarItem(placement: .principal) {
            Button {
                showingModelPicker = true
            } label: {
                VStack(spacing: 1) {
                    Text(appState.currentConversation?.title ?? L10n.text("New Chat"))
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        Text(appState.engine.selectedModel.name)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Current chat: \(appState.currentConversation?.title ?? L10n.text("New Chat")). Model: \(appState.engine.selectedModel.name). Tap to change model."))
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    viewModel.regenerateLastResponse()
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isGenerating)

                Button {
                    showingModelPicker = true
                } label: {
                    Label("Choose Model", systemImage: "cpu")
                }

                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear Chat", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("Chat options"))
        }
    }

    // MARK: - Messages Scroll View

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.messages, id: \.id) { message in
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

                            if message.role == .assistant && !viewModel.isGenerating {
                                Button {
                                    viewModel.regenerateResponse(for: message)
                                } label: {
                                    Label("Regenerate", systemImage: "arrow.clockwise")
                                }
                            }
                        }
                    }

                    // Live streaming bubble
                    if let streaming = viewModel.streamingText {
                        StreamingBubble(text: streaming)
                            .id("streaming")
                    } else if viewModel.isGenerating {
                        TypingIndicator()
                            .id("typing")
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation {
                    proxy.scrollTo(viewModel.messages.last?.id.uuidString, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.streamingText) { _, newValue in
                if newValue != nil {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.isGenerating) { _, generating in
                if generating {
                    withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Engine status chip

    @ViewBuilder
    private var engineStatusChip: some View {
        switch appState.engine.status {
        case .downloading(let progress):
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(maxWidth: 120)
                    Text(downloadStatusText(progress: progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if appState.engine.mlx.isDownloadStalled {
                    Text("Download stalled. Check your internet connection.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGray6))
            .accessibilityElement(children: .combine)
        case .preparing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing \(appState.engine.selectedModel.name)...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGray6))
        default:
            EmptyView()
        }
    }

    /// "Downloading Qwen3 Vision 2B · 213 MB of 1.8 GB" when byte counts are
    /// known, falling back to a simple percentage.
    private func downloadStatusText(progress: Double) -> String {
        let mlx = appState.engine.mlx
        let name = appState.engine.selectedModel.name
        if mlx.totalDownloadBytes > 1, mlx.downloadedBytes > 0 {
            let done = ByteCountFormatter.string(fromByteCount: mlx.downloadedBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: mlx.totalDownloadBytes, countStyle: .file)
            return L10n.text("Downloading \(name) · \(done) of \(total)")
        }
        return L10n.text("Downloading \(name)") + " · \(Int(progress * 100))%"
    }

    // MARK: - Error banner

    private func errorBanner(_ error: ChatViewModel.ErrorBanner) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 6) {
                Text(error.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                if error.canRetry {
                    Button {
                        viewModel.retryLastRequest()
                    } label: {
                        Text("Try Again")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }

            Spacer()

            Button {
                withAnimation { viewModel.errorBanner = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32, minHeight: 32)
            }
            .accessibilityLabel(Text("Dismiss error"))
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    // MARK: - Empty State View

    private var emptyStateView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 60)

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

                    Image(systemName: "eye.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white, .blue)
                        .offset(x: 35, y: -25)
                }
                .accessibilityHidden(true)

                Text("Start a Conversation")
                    .font(.title2.bold())

                Text("Ask questions, analyze images, or discuss documents. Everything stays on your iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    QuickActionButton(
                        icon: "photo.fill",
                        title: L10n.text("Analyze an Image"),
                        subtitle: L10n.text("Add a photo and ask about it")
                    ) {
                        showingPhotoPicker = true
                    }

                    QuickActionButton(
                        icon: "doc.text.fill",
                        title: L10n.text("Read a Document"),
                        subtitle: L10n.text("Upload PDF or text files")
                    ) {
                        showingDocumentPicker = true
                    }

                    QuickActionButton(
                        icon: "text.bubble.fill",
                        title: L10n.text("Just Chat"),
                        subtitle: L10n.text("Ask anything")
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

    // MARK: - Attachment Previews

    private func attachmentPreview(image: UIImage) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue, lineWidth: 2)
                )
                .accessibilityLabel(Text("Attached image"))

            VStack(alignment: .leading, spacing: 2) {
                Text("Image attached")
                    .font(.subheadline.weight(.medium))
                Text("Will be analyzed with your message")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                withAnimation {
                    viewModel.pendingImage = nil
                    viewModel.pendingImageId = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("Remove attached image"))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }

    private func documentPreview(name: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 60, height: 60)

                Image(systemName: documentIcon(for: name))
                    .font(.title)
                    .foregroundStyle(.blue)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.blue, lineWidth: 2)
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("Document attached")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                withAnimation {
                    viewModel.clearPendingDocument()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("Remove attached document"))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }

    private func documentIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.fill"
        case "txt", "md": return "doc.text.fill"
        case "json": return "curlybraces"
        case "swift", "py", "js", "html", "css": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            showingCamera = true
                        } else {
                            showingCameraUnavailableAlert = true
                        }
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
                        .foregroundStyle(viewModel.isGenerating ? .gray : .blue)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(viewModel.isGenerating)
                .accessibilityLabel(Text("Add photo or document"))

                TextField(
                    viewModel.pendingImage != nil
                        ? L10n.text("Ask about this image...")
                        : L10n.text("Message..."),
                    text: $viewModel.inputText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 20))

                if viewModel.isGenerating {
                    // Stop button while generating
                    Button {
                        viewModel.stopGeneration()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title)
                            .foregroundStyle(.red)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(Text("Stop generating"))
                } else {
                    Button {
                        isInputFocused = false
                        Task { await viewModel.sendMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(canSend ? .blue : .gray)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel(Text("Send message"))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var canSend: Bool {
        !viewModel.isGenerating && (
            !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            viewModel.pendingImage != nil ||
            viewModel.pendingDocumentName != nil
        )
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
                    .accessibilityHidden(true)

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
                    .accessibilityHidden(true)
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

    struct ErrorBanner: Equatable {
        let message: String
        let canRetry: Bool
    }

    struct ConsentRequest: Identifiable {
        let id = UUID()
        let model: AIModel
        let reason: String
    }

    struct PendingRequest {
        let prompt: String
        let displayMessage: String
        let hiddenContext: String?
        let image: UIImage?
        let imageId: UUID?
        let attachmentType: AttachmentType?
        let persistUserMessage: Bool
    }

    @Published var messages: [Message] = []
    @Published var inputText = ""
    @Published var isGenerating = false
    @Published var streamingText: String?
    @Published var pendingImage: UIImage?
    @Published var pendingImageId: UUID?
    @Published var pendingDocumentName: String?
    @Published var pendingDocumentContent: String?
    @Published var errorBanner: ErrorBanner?
    @Published var consentRequest: ConsentRequest?
    @Published var showingImportError = false
    @Published private(set) var importErrorMessage = ""

    var appState: AppState?
    private var currentConversationId: UUID?
    private var imageCache: [UUID: UIImage] = [:]
    private var generationTask: Task<Void, Never>?
    private var lastRequest: PendingRequest?

    // MARK: - Conversation loading

    func loadConversation(_ conversation: Conversation?) {
        guard conversation?.id != currentConversationId else { return }

        stopGeneration()
        messages.removeAll()
        pendingImage = nil
        pendingImageId = nil
        pendingDocumentName = nil
        pendingDocumentContent = nil
        errorBanner = nil
        currentConversationId = conversation?.id

        // Sessions rebuild lazily on the next message.
        appState?.engine.resetSessions()

        if let conversation = conversation {
            messages = conversation.messages.sorted { $0.timestamp < $1.timestamp }
            loadCachedImages(for: conversation)
        }
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

    /// History as the model should see it: user/assistant turns only,
    /// with hidden document context substituted in.
    private var historyForModel: [(role: String, content: String)] {
        messages
            .filter { $0.role == .user || $0.role == .assistant }
            .map { ($0.role.rawValue, $0.modelFacingContent) }
    }

    // MARK: - Photo Handling

    func loadSelectedPhoto(_ item: PhotosPickerItem?) async {
        guard let item = item else { return }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                presentImportError(L10n.text("This photo couldn't be loaded. Try a different one."))
                return
            }

            let processedImage = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let image = UIImage(data: data) else { return nil }

                let maxDimension: CGFloat = 1024
                let size = image.size
                if size.width <= maxDimension && size.height <= maxDimension {
                    return image
                }

                let ratio = min(maxDimension / size.width, maxDimension / size.height)
                let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
                let renderer = UIGraphicsImageRenderer(size: newSize)
                return renderer.image { _ in
                    image.draw(in: CGRect(origin: .zero, size: newSize))
                }
            }.value

            if let image = processedImage {
                pendingImage = image
                pendingImageId = UUID()
            } else {
                presentImportError(L10n.text("This photo couldn't be read. Try a different one."))
            }
        } catch {
            presentImportError(L10n.text("Couldn't load the photo: \(error.localizedDescription)"))
        }
    }

    // MARK: - Document Handling

    func processDocuments(_ urls: [URL]) async {
        guard let url = urls.first else { return }

        do {
            guard url.startAccessingSecurityScopedResource() else {
                throw DocumentError.accessDenied
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let content: String
            switch url.pathExtension.lowercased() {
            case "pdf":
                content = try await extractTextFromPDF(url)
            default:
                content = try String(contentsOf: url, encoding: .utf8)
            }

            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                presentImportError(L10n.text("No readable text was found in \(url.lastPathComponent)."))
                return
            }

            pendingDocumentName = url.lastPathComponent
            pendingDocumentContent = String(trimmed.prefix(4000))
        } catch {
            presentImportError(L10n.text("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"))
        }
    }

    func clearPendingDocument() {
        pendingDocumentName = nil
        pendingDocumentContent = nil
    }

    private func extractTextFromPDF(_ url: URL) async throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw DocumentError.invalidDocument
        }

        var fullText = ""
        let pageCount = min(document.pageCount, 20)
        for pageIndex in 0..<pageCount {
            if let page = document.page(at: pageIndex), let pageText = page.string {
                fullText += "[Page \(pageIndex + 1)]\n\(pageText)\n\n"
            }
        }
        return fullText
    }

    private func presentImportError(_ message: String) {
        importErrorMessage = message
        showingImportError = true
    }

    // MARK: - Send

    func sendMessage() async {
        guard !isGenerating else { return }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        let imageId = pendingImageId
        let documentName = pendingDocumentName
        let documentContent = pendingDocumentContent

        guard !text.isEmpty || image != nil || documentName != nil else { return }

        // Clear composer state.
        inputText = ""
        pendingImage = nil
        pendingImageId = nil
        pendingDocumentName = nil
        pendingDocumentContent = nil
        errorBanner = nil

        // Build model prompt and display text.
        let prompt: String
        let displayMessage: String
        var hiddenContext: String?

        if let docName = documentName, let docContent = documentContent {
            let question = text.isEmpty ? L10n.text("Please analyze this document and provide a summary.") : text
            prompt = "I've uploaded a document (\(docName)). Here's its content:\n\n\(docContent)\n\n\(question)"
            displayMessage = "[\(docName)] \(text.isEmpty ? L10n.text("Analyze this document") : text)"
            hiddenContext = prompt
        } else if text.isEmpty && image != nil {
            prompt = L10n.text("What's in this image?")
            displayMessage = prompt
        } else {
            prompt = text
            displayMessage = text
        }

        let request = PendingRequest(
            prompt: prompt,
            displayMessage: displayMessage,
            hiddenContext: hiddenContext,
            image: image,
            imageId: imageId,
            attachmentType: image != nil ? .image : (documentName != nil ? .document : nil),
            persistUserMessage: true
        )

        await perform(request)
    }

    // MARK: - Core request execution

    private func perform(_ request: PendingRequest) async {
        guard let appState else { return }

        // Ensure a conversation exists.
        var conversation = appState.currentConversation
        if conversation == nil {
            conversation = appState.conversationManager.createConversation()
            appState.currentConversation = conversation
            currentConversationId = conversation?.id
        }

        // Persist and show the user message FIRST, so it is never lost when
        // routing needs user action (e.g. download consent).
        if request.persistUserMessage, let conv = conversation {
            let userMessage = appState.conversationManager.addMessage(
                to: conv,
                role: .user,
                content: request.displayMessage,
                attachmentType: request.attachmentType,
                attachmentId: request.imageId,
                hiddenContext: request.hiddenContext
            )
            messages.append(userMessage)

            if let image = request.image, let imageId = request.imageId {
                imageCache[imageId] = image
                saveImage(image, withId: imageId)
                conv.attachedImageIds.append(imageId)
            }
        }

        // Remember the request for retry/consent flows. The user message is
        // persisted by now, so any re-run must not persist it again.
        lastRequest = PendingRequest(
            prompt: request.prompt,
            displayMessage: request.displayMessage,
            hiddenContext: request.hiddenContext,
            image: request.image,
            imageId: request.imageId,
            attachmentType: request.attachmentType,
            persistUserMessage: false
        )

        // Route to a backend; may require download consent.
        let routedModel: AIModel
        do {
            routedModel = try appState.engine.route(hasImage: request.image != nil)
        } catch let error as ChatEngine.RouteError {
            handleRouteError(error)
            return
        } catch {
            errorBanner = ErrorBanner(message: error.localizedDescription, canRetry: true)
            return
        }

        isGenerating = true
        streamingText = nil

        generationTask = Task {
            var finalText = ""
            var failure: String?

            do {
                // Build the session once per conversation; reuse it between turns.
                // History must end after an assistant turn: trailing user turns
                // are pending questions (including the one being asked now) and
                // are delivered via streamResponse instead.
                if !appState.engine.hasSession(for: routedModel) {
                    var history = historyForModel
                    while history.last?.role == MessageRole.user.rawValue {
                        history.removeLast()
                    }
                    try await appState.engine.startConversation(
                        model: routedModel,
                        history: history
                    )
                }

                let stream = appState.engine.respondStream(
                    model: routedModel,
                    prompt: request.prompt,
                    image: request.image
                )

                for try await snapshot in stream {
                    if Task.isCancelled { break }
                    streamingText = snapshot
                    finalText = snapshot
                }
            } catch is CancellationError {
                // User tapped Stop (possibly mid-download); not an error.
            } catch {
                if !Task.isCancelled {
                    failure = error.localizedDescription
                }
            }

            // Finalize on the main actor.
            let cleaned = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

            if !cleaned.isEmpty, let conv = conversation {
                let assistantMessage = appState.conversationManager.addMessage(
                    to: conv,
                    role: .assistant,
                    content: cleaned
                )
                messages.append(assistantMessage)

                if appState.settings.hapticFeedbackEnabled {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }

            if let failure {
                errorBanner = ErrorBanner(message: failure, canRetry: true)
                // The session may be mid-turn; rebuild next time.
                appState.engine.resetSessions()
            }

            streamingText = nil
            isGenerating = false
            generationTask = nil
        }

        await generationTask?.value
    }

    private func handleRouteError(_ error: ChatEngine.RouteError) {
        switch error {
        case .needsDownloadConsent(let model):
            consentRequest = ConsentRequest(
                model: model,
                reason: L10n.text("To chat privately on this device, \(model.name) (\(model.size)) needs to be downloaded once. After that, everything works offline.")
            )
        case .visionNeedsDownloadedModel(let model):
            consentRequest = ConsentRequest(
                model: model,
                reason: L10n.text("Analyzing images needs the \(model.name) vision model (\(model.size)). It downloads once and then works offline.")
            )
        case .nothingAvailable(let reason):
            errorBanner = ErrorBanner(message: reason, canRetry: false)
        }
    }

    // MARK: - Consent

    func approveConsentAndResend() {
        guard let request = consentRequest else { return }
        appState?.engine.approveDownload(for: request.model)
        // If the user was on Apple Intelligence and needed a vision model,
        // keep their engine selection; the router picks the vision model
        // automatically for image messages.
        if appState?.engine.selectedModel.backend != .appleIntelligence {
            appState?.engine.select(request.model)
        } else if request.model.backend == .mlx && lastRequest?.image == nil {
            appState?.engine.select(request.model)
        }
        consentRequest = nil

        if let last = lastRequest {
            // Re-run without duplicating the user message if it was persisted.
            let retry = PendingRequest(
                prompt: last.prompt,
                displayMessage: last.displayMessage,
                hiddenContext: last.hiddenContext,
                image: last.image,
                imageId: last.imageId,
                attachmentType: last.attachmentType,
                persistUserMessage: false
            )
            Task { await perform(retry) }
        }
    }

    // MARK: - Stop / Retry / Regenerate

    func stopGeneration() {
        generationTask?.cancel()
    }

    func retryLastRequest() {
        guard !isGenerating, let last = lastRequest else { return }
        errorBanner = nil
        let retry = PendingRequest(
            prompt: last.prompt,
            displayMessage: last.displayMessage,
            hiddenContext: last.hiddenContext,
            image: last.image,
            imageId: last.imageId,
            attachmentType: last.attachmentType,
            persistUserMessage: false
        )
        Task { await perform(retry) }
    }

    func regenerateLastResponse() {
        guard let lastAssistant = messages.last(where: { $0.role == .assistant }) else { return }
        regenerateResponse(for: lastAssistant)
    }

    func regenerateResponse(for message: Message) {
        guard !isGenerating, message.role == .assistant else { return }
        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else { return }

        // Find the preceding user message; use its model-facing content so
        // document questions regenerate with the document text.
        var sourceUser: Message?
        for i in stride(from: messageIndex - 1, through: 0, by: -1) where messages[i].role == .user {
            sourceUser = messages[i]
            break
        }
        guard let userMessage = sourceUser else { return }

        let image = userMessage.attachmentId.flatMap { imageCache[$0] }

        // Remove the old answer, rebuild the session from the edited history.
        appState?.conversationManager.deleteMessage(message)
        messages.removeAll { $0.id == message.id }
        appState?.engine.resetSessions()

        let retry = PendingRequest(
            prompt: userMessage.modelFacingContent,
            displayMessage: userMessage.content,
            hiddenContext: userMessage.hiddenContext,
            image: image,
            imageId: nil,
            attachmentType: nil,
            persistUserMessage: false
        )
        Task { await perform(retry) }
    }

    // MARK: - Clear

    func clearConversation() {
        stopGeneration()

        // Actually delete the saved messages so the chat stays cleared.
        if let conversation = appState?.currentConversation {
            for message in conversation.messages {
                appState?.conversationManager.deleteMessage(message)
            }
            conversation.attachedImageIds.removeAll()
            appState?.conversationManager.updateConversation(conversation)
        }

        messages.removeAll()
        pendingImage = nil
        pendingImageId = nil
        pendingDocumentName = nil
        pendingDocumentContent = nil
        errorBanner = nil
        imageCache.removeAll()
        appState?.engine.resetSessions()
    }

    // MARK: - Image Storage

    private func saveImage(_ image: UIImage, withId id: UUID) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        guard let path = getImagePath(for: id) else { return }
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
                        .accessibilityLabel(Text("Attached image"))
                }

                if let attachmentType = message.attachmentType, attachmentType != .image {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.fill")
                        Text("Document")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Group {
                    if message.role == .assistant {
                        MarkdownText(content: message.content)
                    } else {
                        Text(message.content)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
                .background(backgroundColor)
                .foregroundStyle(foregroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if message.role != .user { Spacer(minLength: 60) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message.role == .user
            ? L10n.text("You said: \(message.content)")
            : L10n.text("Assistant said: \(message.content)")))
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user: return .blue
        case .assistant: return Color(.systemGray5)
        case .system: return .orange.opacity(0.15)
        }
    }

    private var foregroundColor: Color {
        message.role == .user ? .white : .primary
    }
}

// MARK: - Streaming Bubble

struct StreamingBubble: View {
    let text: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                MarkdownText(content: text)
                    .padding(12)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            Spacer(minLength: 60)
        }
        .accessibilityLabel(Text("Assistant is responding: \(text)"))
    }
}

// MARK: - Download Consent Sheet

struct ModelDownloadConsentSheet: View {
    let model: AIModel
    let reason: String
    let onApprove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            Text("Download \(model.name)?")
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("One-time download of \(model.size)")
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
                Label {
                    Text("Wi-Fi recommended")
                } icon: {
                    Image(systemName: "wifi")
                }
                Label {
                    Text("Works fully offline afterward")
                } icon: {
                    Image(systemName: "airplane")
                }
                Label {
                    Text("You can delete it anytime in Settings")
                } icon: {
                    Image(systemName: "trash")
                }
            }
            .font(.subheadline)
            .padding(.horizontal)

            Spacer()

            VStack(spacing: 10) {
                Button {
                    onApprove()
                } label: {
                    Text("Download")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)

                Button("Not Now", action: onCancel)
                    .font(.subheadline)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
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
                onImageCaptured(image)
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

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
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
        .accessibilityLabel(Text("Assistant is thinking"))
    }
}

#Preview {
    ChatView()
        .environmentObject(AppState())
}
