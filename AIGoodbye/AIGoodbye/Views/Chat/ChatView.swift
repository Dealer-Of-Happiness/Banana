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
import VisionKit

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    /// Owned by AppState so drafts and in-flight answers survive the
    /// language-change rebuild of the view tree.
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool

    // Attachment state
    @State private var showingPhotoPicker = false
    @State private var showingCamera = false
    @State private var showingDocumentPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingCameraUnavailableAlert = false
    @State private var showingClearConfirmation = false
    @State private var showingModelPicker = false
    @State private var showingVoiceMode = false
    @State private var showingLiveCamera = false
    @State private var showingTranslate = false
    @State private var showingRecorder = false
    @State private var showingScanner = false
    @State private var showingSceneDescription = false
    /// Whether the transcript is scrolled to the bottom, so a streaming
    /// answer follows along without stealing the scroll from the user.
    @State private var isPinnedToBottom = true
    @State private var showingSetup = false
    /// Shown once, right after the terms, so a new user knows where they
    /// stand before typing anything.
    @AppStorage("hasSeenSetup") private var hasSeenSetup = false

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

                // Confirmation that something was saved to private memory.
                if let notice = viewModel.memoryNotice {
                    HStack(spacing: 10) {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(.blue)
                        Text(notice)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button {
                            withAnimation { viewModel.memoryNotice = nil }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(Text("Dismiss"))
                    }
                    .padding(.horizontal, 10)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                    .task {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        withAnimation { viewModel.memoryNotice = nil }
                    }
                }

                // Storage failure warning: conversations aren't being saved.
                if let storageError = appState.conversationManager.storageError {
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.red)
                        Text(storageError)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
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

                if viewModel.isRecognizingText {
                    HStack(spacing: 8) {
                        if viewModel.scanProgress > 0 {
                            ProgressView(value: viewModel.scanProgress)
                                .frame(width: 90)
                        } else {
                            ProgressView()
                        }
                        Text("Reading the text on this device...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
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
            .fullScreenCover(isPresented: $showingVoiceMode) {
                VoiceModeView(viewModel: viewModel)
                    .environmentObject(appState)
            }
            .fullScreenCover(isPresented: $showingLiveCamera) {
                LiveCameraView()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showingTranslate) {
                TranslateModeView()
                    .environmentObject(appState)
            }
            .fullScreenCover(isPresented: $showingRecorder) {
                RecorderView()
                    .environmentObject(appState)
            }
            .fullScreenCover(isPresented: $showingSceneDescription) {
                SceneDescriptionView()
                    .environmentObject(appState)
            }
            .fullScreenCover(isPresented: $showingScanner) {
                DocumentScannerView(
                    onFinish: { scan in
                        showingScanner = false
                        Task { await viewModel.processScan(scan) }
                    },
                    onCancel: { showingScanner = false }
                )
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showingCamera) {
                // Full screen per Apple guidance for the camera (a sheet
                // letterboxes on iPad).
                CameraView { image in
                    viewModel.pendingImage = image
                    viewModel.pendingImageId = UUID()
                    showingCamera = false
                }
                .ignoresSafeArea()
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
            .sheet(isPresented: $showingSetup) {
                SetupView()
                    .environmentObject(appState)
            }
            // onDismiss matters: swiping the sheet away nils the binding
            // without running "Not Now", which used to leave the message
            // sitting unanswered with no banner and no explanation.
            //
            // Suppressed while voice mode is up: that screen presents this
            // same sheet itself, and two presentations of one binding means
            // UIKit silently drops one and both onDismiss handlers run.
            .sheet(item: showingVoiceMode ? .constant(nil) : $viewModel.consentRequest, onDismiss: {
                viewModel.consentSheetDismissed()
            }) { request in
                ModelDownloadConsentSheet(
                    model: request.model,
                    reason: request.reason,
                    onApprove: {
                        viewModel.approveConsentAndResend()
                    },
                    onCancel: {
                        viewModel.declineConsent()
                    }
                )
                .presentationDetents([.medium, .large])
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
            // Separate from the error alert above: the scan succeeded, it
            // just didn't include everything, and "Couldn't Add Attachment"
            // over a document that was added reads as a failure.
            .alert(
                "Scan finished",
                isPresented: Binding(
                    get: { viewModel.scanNotice != nil },
                    set: { if !$0 { viewModel.scanNotice = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.scanNotice ?? "")
            }
            .alert(
                "Clear this chat?",
                isPresented: $showingClearConfirmation
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
            // A route set before this view existed (cold launch from a
            // widget or Control Center) would never fire onChange.
            applyPendingRoute()
            // First run: say what's needed before the user types, not after.
            if !hasSeenSetup {
                hasSeenSetup = true
                if case .needsSetup = appState.engine.status {
                    showingSetup = true
                } else if appState.engine.appleIntelligence.isAvailable,
                          !AIModel.builtInModels.contains(where: { $0.isDownloaded }) {
                    showingSetup = true
                }
            }
        }
        .onChange(of: appState.currentConversation) { _, newConversation in
            viewModel.loadConversation(newConversation)
        }
        // Widgets, Control Center and Siri can ask for a specific screen.
        .onChange(of: appState.pendingRoute) { _, _ in
            applyPendingRoute()
        }
    }

    private func applyPendingRoute() {
        guard let route = appState.pendingRoute else { return }
        appState.pendingRoute = nil
        switch route {
        case .voice: showingVoiceMode = true
        case .camera: showingLiveCamera = true
        case .translate: showingTranslate = true
        case .newChat:
            appState.createNewConversation()
            isInputFocused = true
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
                    Text(appState.currentConversation?.displayTitle ?? L10n.text("New Chat"))
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
            .accessibilityLabel(Text("Current chat: \(appState.currentConversation?.displayTitle ?? L10n.text("New Chat")). Model: \(appState.engine.selectedModel.name). Tap to change model."))
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
                // Capped reading width: on an iPad in landscape an uncapped
                // bubble is ~200 characters per line, which is unreadable.
                // Every other screen already caps; the chat did not.
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

                            // Regenerate only the LAST answer: regenerating a
                            // middle-of-chat reply would append the new answer
                            // at the bottom, out of context.
                            if message.role == .assistant && !viewModel.isGenerating
                                && message.id == viewModel.messages.last(where: { $0.role == .assistant })?.id {
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
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            // Scrolling up while an answer streams used to be impossible:
            // every token yanked the view back down. Follow the answer only
            // while the user is still at the bottom.
            //
            // Unpin only on a deliberate upward drag. Deriving it from
            // position alone unlatches on any large layout jump - a code
            // block or table appearing - and the answer stops following for
            // no reason the user can see.
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        if value.translation.height > 0 { isPinnedToBottom = false }
                    }
            )
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let bottom = geometry.contentOffset.y + geometry.containerSize.height
                return bottom >= geometry.contentSize.height - 120
            } action: { _, atBottom in
                // Re-pin as soon as the user comes back to the bottom.
                if atBottom { isPinnedToBottom = true }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                // A new message the user just sent always scrolls.
                isPinnedToBottom = true
                withAnimation {
                    proxy.scrollTo(viewModel.messages.last?.id.uuidString, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.streamingText) { _, newValue in
                if newValue != nil, isPinnedToBottom {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.isGenerating) { _, generating in
                if generating {
                    isPinnedToBottom = true
                    withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isPinnedToBottom, viewModel.isGenerating {
                    Button {
                        isPinnedToBottom = true
                        withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(.ultraThinMaterial))
                    }
                    .padding(.trailing, 14)
                    .padding(.bottom, 8)
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
        case .needsSetup:
            // This state was computed and never rendered, so on a device
            // without Apple Intelligence the app looked completely ready and
            // only demanded a 1.8 GB download after the user's first message.
            Button {
                showingSetup = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Set up your AI model to start chatting")
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.blue.opacity(0.1))
            }
            .buttonStyle(.plain)
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
                            .frame(minHeight: 44)
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
                    .frame(minWidth: 44, minHeight: 44)
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

                Text("Ask questions, analyze images, or discuss documents. Everything stays on your device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // These are the app's actual capabilities, not just
                // "attach something". Nine features had been living behind a
                // "+" button labelled "Add photo or document", where nobody
                // would ever find them.
                VStack(spacing: 12) {
                    QuickActionButton(
                        icon: "text.bubble.fill",
                        title: L10n.text("Just Chat"),
                        subtitle: L10n.text("Ask anything")
                    ) {
                        isInputFocused = true
                    }

                    QuickActionButton(
                        icon: "waveform",
                        title: L10n.text("Talk out loud"),
                        subtitle: L10n.text("A hands-free voice conversation")
                    ) {
                        showingVoiceMode = true
                    }

                    QuickActionButton(
                        icon: "waveform.badge.mic",
                        title: L10n.text("Record a meeting"),
                        subtitle: L10n.text("Transcript, summary and action items")
                    ) {
                        showingRecorder = true
                    }

                    QuickActionButton(
                        icon: "character.bubble",
                        title: L10n.text("Translate a conversation"),
                        subtitle: L10n.text("Two-way, out loud, with no internet")
                    ) {
                        showingTranslate = true
                    }

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

                    if DocumentScannerView.isAvailable {
                        Button {
                            showingScanner = true
                        } label: {
                            Label("Scan Document", systemImage: "doc.viewfinder")
                        }
                    }

                    #if !targetEnvironment(simulator)
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showingLiveCamera = true
                        } label: {
                            Label("Live Camera", systemImage: "camera.viewfinder")
                        }

                        Button {
                            showingSceneDescription = true
                        } label: {
                            Label("Describe Surroundings", systemImage: "eye")
                        }
                    }
                    #endif

                    Divider()

                    Button {
                        showingTranslate = true
                    } label: {
                        Label("Translate", systemImage: "character.bubble")
                    }

                    Button {
                        showingRecorder = true
                    } label: {
                        Label("Record", systemImage: "waveform.badge.mic")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                        .foregroundStyle(viewModel.isGenerating ? .gray : .blue)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(viewModel.isGenerating)
                // Not "Add photo or document": this menu is where voice,
                // live camera, Describe Surroundings, translate, record and
                // scan live. A blind user looking for Describe Surroundings
                // has to be able to find it from its name.
                .accessibilityLabel(Text("Tools and attachments"))
                .accessibilityHint(Text("Photos, documents, scanning, live camera, describe surroundings, translate and record"))

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
                } else if canSend {
                    Button {
                        isInputFocused = false
                        Task { await viewModel.sendMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(.blue)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(Text("Send message"))
                } else {
                    // Empty composer: offer hands-free voice conversation.
                    Button {
                        isInputFocused = false
                        showingVoiceMode = true
                    } label: {
                        Image(systemName: "waveform.circle.fill")
                            .font(.title)
                            .foregroundStyle(.blue)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(Text("Start a voice conversation"))
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
        var persistUserMessage: Bool
        var documentId: UUID? = nil
        /// Extra material for THIS generation only (never persisted).
        var transientContext: String? = nil
    }

    @Published var messages: [Message] = []
    @Published var inputText = ""
    @Published var isGenerating = false
    @Published var streamingText: String?
    @Published var pendingImage: UIImage?
    @Published var pendingImageId: UUID?
    @Published var pendingDocumentName: String?
    @Published var pendingDocumentContent: String?
    @Published var pendingDocumentId: UUID?
    @Published var errorBanner: ErrorBanner?
    @Published var consentRequest: ConsentRequest?
    @Published var showingImportError = false
    @Published private(set) var importErrorMessage = ""
    /// Shown briefly when something is added to private memory.
    @Published var memoryNotice: String?
    /// True while Vision is reading a scan or an image-only PDF.
    @Published var isRecognizingText = false
    /// 0...1 through a multi-page scan.
    @Published var scanProgress: Double = 0
    /// A scan that worked but left something out.
    @Published var scanNotice: String?
    /// Set when the consent sheet is closing because the user approved, so
    /// its dismissal isn't mistaken for a decline.
    private var consentApproved = false
    /// Guards against two overlapping Clear Chat runs, the second of which
    /// would delete already-deleted objects.
    private var isClearing = false

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
        // Never carry a pending document into a different conversation.
        if let staleDoc = pendingDocumentId {
            Task { await DocumentIndex.shared.removeDocument(staleDoc) }
            pendingDocumentId = nil
        }
        errorBanner = nil
        consentRequest = nil
        lastRequest = nil
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
        if let cached = imageCache[id] { return cached }
        // Fall back to disk. Without this, dropping the cache on a memory
        // warning left every image bubble in the open chat permanently
        // blank, because the cache is only refilled when a DIFFERENT
        // conversation is loaded.
        guard let image = UIImage(contentsOfFile: ConversationManager.imagePath(for: id).path) else {
            return nil
        }
        imageCache[id] = image
        return image
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

    /// Largest file the importer will open. Only ~4,000 characters are used,
    /// so anything bigger than this is pointless to read into memory.
    private static let maxImportBytes: Int64 = 25 * 1024 * 1024

    func processDocuments(_ urls: [URL]) async {
        guard let url = urls.first else { return }

        // Replacing an unsent attachment: don't strand the old text on disk.
        clearPendingDocument()

        do {
            guard url.startAccessingSecurityScopedResource() else {
                throw DocumentError.accessDenied
            }
            defer { url.stopAccessingSecurityScopedResource() }

            // Size cap: without it a huge file is read fully into memory.
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               Int64(size) > Self.maxImportBytes {
                let limit = ByteCountFormatter.string(fromByteCount: Self.maxImportBytes, countStyle: .file)
                presentImportError(L10n.text("This file is too large to import. The limit is \(limit)."))
                return
            }

            let content: String
            switch url.pathExtension.lowercased() {
            case "pdf":
                content = try await extractTextFromPDF(url)
            default:
                // Read and decode off the main thread.
                content = try await Task.detached(priority: .userInitiated) {
                    try String(contentsOf: url, encoding: .utf8)
                }.value
            }

            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                presentImportError(L10n.text("No readable text was found in \(url.lastPathComponent)."))
                return
            }

            // Store the WHOLE document for retrieval; keep a short preview
            // for summaries. The AI can then answer questions about any part
            // of the document, not just the first page.
            pendingDocumentName = url.lastPathComponent
            pendingDocumentContent = String(trimmed.prefix(4000))
            pendingDocumentId = await DocumentIndex.shared.store(
                name: url.lastPathComponent, fullText: trimmed
            )
        } catch {
            presentImportError(L10n.text("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"))
        }
    }

    /// Handle a file handed over by the share extension (already inside our
    /// own container, so no security-scoped access is needed).
    func processSharedFile(_ url: URL, displayName: String) async {
        clearPendingDocument()

        // Images become an attachment; everything else is read as a document.
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            pendingImage = image
            pendingImageId = UUID()
            return
        }

        do {
            let text: String
            if url.pathExtension.lowercased() == "pdf" {
                text = try await extractTextFromPDF(url)
            } else {
                text = try await Task.detached(priority: .userInitiated) {
                    try String(contentsOf: url, encoding: .utf8)
                }.value
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                presentImportError(L10n.text("No readable text was found in \(displayName)."))
                return
            }
            pendingDocumentName = displayName
            pendingDocumentContent = String(trimmed.prefix(4000))
            pendingDocumentId = await DocumentIndex.shared.store(name: displayName, fullText: trimmed)
        } catch {
            presentImportError(L10n.text("Couldn't read \(displayName): \(error.localizedDescription)"))
        }
    }

    func clearPendingDocument() {
        if let id = pendingDocumentId {
            // Never sent: remove the stored text again.
            Task { await DocumentIndex.shared.removeDocument(id) }
        }
        pendingDocumentName = nil
        pendingDocumentContent = nil
        pendingDocumentId = nil
    }

    private func extractTextFromPDF(_ url: URL) async throws -> String {
        // PDF parsing happens off the main thread.
        let embedded = try await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url) else {
                throw DocumentError.invalidDocument
            }

            var fullText = ""
            let pageCount = min(document.pageCount, 300)
            for pageIndex in 0..<pageCount {
                if let page = document.page(at: pageIndex), let pageText = page.string {
                    fullText += "[Page \(pageIndex + 1)]\n\(pageText)\n\n"
                }
            }
            return fullText
        }.value

        // A scanned PDF is images with no text layer: PDFKit returns nothing
        // useful, so read the pages with on-device OCR instead.
        let meaningful = embedded
            .replacingOccurrences(of: "[Page ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if meaningful.count >= 40 { return embedded }

        isRecognizingText = true
        defer { isRecognizingText = false }
        let languages = TextRecognizer.languages(for: appState?.settings.appLanguage ?? .automatic)
        let recognized = await TextRecognizer.text(inScannedPDF: url, languages: languages)
        return recognized.isEmpty ? embedded : recognized
    }

    // MARK: - Scanning

    /// Read a scan with on-device OCR and attach the text as a document, so
    /// the AI can answer questions about a piece of paper.
    ///
    /// One page is decoded at a time and released before the next, and the
    /// loop yields between pages so the screen keeps drawing its progress.
    /// Nothing is written to disk on the way: these are people's contracts
    /// and medical letters.
    func processScan(_ scan: VNDocumentCameraScan) async {
        let totalScanned = scan.pageCount
        guard totalScanned > 0 else { return }
        clearPendingDocument()

        isRecognizingText = true
        scanProgress = 0
        defer {
            isRecognizingText = false
            scanProgress = 0
        }

        let languages = TextRecognizer.languages(for: appState?.settings.appLanguage ?? .automatic)
        let readable = min(totalScanned, DocumentScannerView.maximumPages)
        var pages: [String] = []
        var failed = 0

        for index in 0..<readable {
            if Task.isCancelled { break }
            let image: UIImage? = autoreleasepool { scan.imageOfPage(at: index) }
            scanProgress = Double(index) / Double(readable)
            guard let image else {
                failed += 1
                continue
            }
            let page = await TextRecognizer.text(in: image, languages: languages)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Numbered by its true position in the scan. Numbering by
            // position in the surviving array meant that losing page 1 quietly
            // relabelled page 2 as "Page 1", and the document then
            // misrepresented itself.
            if page.isEmpty {
                failed += 1
            } else {
                pages.append(readable > 1 ? "\(L10n.text("Page \(index + 1)"))\n\n\(page)" : page)
            }
            scanProgress = Double(index + 1) / Double(readable)
            await Task.yield()
        }

        let trimmed = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            presentImportError(L10n.text("No readable text was found in this scan. Try again with more light, or hold the camera steady."))
            return
        }

        let name = L10n.text("Scan \(Date().formatted(date: .abbreviated, time: .shortened))")
        pendingDocumentName = name
        pendingDocumentContent = String(trimmed.prefix(4000))
        pendingDocumentId = await DocumentIndex.shared.store(name: name, fullText: trimmed)

        // Say what was left out rather than quietly handing over a document
        // with pages missing from it.
        if totalScanned > readable {
            scanNotice = L10n.text("Only the first \(readable) pages were read. Scan the rest separately.")
        } else if failed > 0 {
            scanNotice = L10n.text("\(failed) of \(readable) pages had no readable text and were left out.")
        }
    }

    private func presentImportError(_ message: String) {
        importErrorMessage = message
        showingImportError = true
    }

    enum DocumentError: LocalizedError {
        case accessDenied
        case invalidDocument

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return L10n.text("This file can't be accessed. Try picking it again.")
            case .invalidDocument:
                return L10n.text("This document couldn't be opened.")
            }
        }
    }

    // MARK: - Send

    func sendMessage() async {
        guard !isGenerating else { return }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        let imageId = pendingImageId
        let documentName = pendingDocumentName
        let documentContent = pendingDocumentContent
        let documentId = pendingDocumentId

        guard !text.isEmpty || image != nil || documentName != nil else { return }

        // "Remember that ..." saves to private memory before answering, and
        // always tells the user what was saved.
        captureMemoryIfRequested(text)

        // Clear composer state.
        inputText = ""
        pendingImage = nil
        pendingImageId = nil
        pendingDocumentName = nil
        pendingDocumentContent = nil
        pendingDocumentId = nil
        errorBanner = nil

        // Build model prompt and display text.
        let prompt: String
        let displayMessage: String
        var hiddenContext: String?
        var summarySeed: String?

        if let docName = documentName {
            let question = text.isEmpty ? L10n.text("Please analyze this document and provide a summary.") : text
            prompt = question
            displayMessage = "[\(docName)] \(text.isEmpty ? L10n.text("Analyze this document") : text)"
            // Only the question is persisted; the relevant passages are
            // retrieved fresh for each turn in `perform` so history never
            // fills up with duplicated document text.
            hiddenContext = question
            // Summaries have no keywords to match, so seed the opening of
            // the document as a fallback for this first turn.
            if text.isEmpty, let preview = documentContent {
                summarySeed = "Opening of the document \(docName):\n\n\(preview)"
            }
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
            persistUserMessage: true,
            // Only attach a document id when a document was actually sent.
            documentId: documentName != nil ? documentId : nil,
            transientContext: summarySeed
        )

        await perform(request)
    }

    /// Saves an explicit "remember that ..." request into private memory.
    /// Returns true when something was saved, so the UI can confirm it.
    @discardableResult
    private func captureMemoryIfRequested(_ message: String) -> Bool {
        guard MemoryStore.shared.isEnabled,
              let fact = MemoryStore.requestedFact(in: message) else { return false }
        MemoryStore.shared.add(fact)
        // The system prompt changed, so the live session must be rebuilt.
        appState?.engine.resetSessions()
        // Never store something about the user silently: say what was saved
        // and where to remove it.
        memoryNotice = L10n.text("Saved to memory: \(fact)")
        return true
    }

    /// Voice mode entry point: sends spoken text as a normal chat turn.
    func sendVoicePrompt(_ text: String) async {
        guard !isGenerating else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorBanner = nil
        captureMemoryIfRequested(trimmed)
        let request = PendingRequest(
            prompt: trimmed,
            displayMessage: trimmed,
            hiddenContext: nil,
            image: nil,
            imageId: nil,
            attachmentType: nil,
            persistUserMessage: true
        )
        await perform(request)
    }

    // MARK: - Core request execution

    private func perform(_ request: PendingRequest) async {
        guard let appState else { return }

        // Claim the engine synchronously, before any suspension point. The
        // callers that spawn `Task { await perform(...) }` return to the UI
        // first, so without this a second tap on Send or Regenerate starts a
        // concurrent run that orphans the first one's task.
        guard !isGenerating else { return }
        isGenerating = true

        // Ensure a conversation exists.
        var conversation = appState.currentConversation
        if conversation == nil {
            conversation = appState.conversationManager.createConversation()
            appState.currentConversation = conversation
            currentConversationId = conversation?.id
        }

        // Newly attached document becomes part of the conversation, so every
        // later question can retrieve from it.
        if let docId = request.documentId, request.persistUserMessage, let conv = conversation,
           !conv.attachedDocumentIds.contains(docId) {
            conv.attachedDocumentIds.append(docId)
            appState.conversationManager.updateConversation(conv)
        }

        // Persist and show the user message FIRST - before any await. On a
        // document chat, retrieval takes seconds; doing it first meant the
        // user's message simply vanished for that whole window, Stop did
        // nothing because there was no task yet, and switching conversations
        // mid-retrieval dropped the message into the wrong chat.
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

        // Remember the request for retry/consent flows. Every field is
        // carried over - a retry that quietly dropped the document id or the
        // summary seed would answer a different question.
        var retryable = request
        retryable.persistUserMessage = false
        lastRequest = retryable

        // Route to a backend; may require download consent.
        let routedModel: AIModel
        do {
            routedModel = try appState.engine.route(hasImage: request.image != nil)
        } catch let error as ChatEngine.RouteError {
            isGenerating = false
            handleRouteError(error)
            return
        } catch {
            isGenerating = false
            errorBanner = ErrorBanner(message: error.localizedDescription, canRetry: true)
            return
        }

        streamingText = nil

        // Whether this turn had to fetch the model first, so a cancellation
        // can be explained accurately.
        let wasDownloading = routedModel.backend == .mlx && !routedModel.isDownloaded

        generationTask = Task {
            var finalText = ""
            var failure: String?
            var cancelledDownload = false
            var wasCancelled = false

            do {
                // The document brain: pull the passages relevant to THIS
                // question out of the attached documents. Runs inside the
                // cancellable task, and off the main actor, so Stop works and
                // the UI stays responsive while it searches. Used for this
                // generation only - never written into history, which would
                // crowd out the conversation itself.
                var generationPrompt = request.prompt
                let libraryIds = KnowledgeLibrary.shared.activeDocumentIds
                let searchableIds = Array(Set((conversation?.attachedDocumentIds ?? []) + libraryIds))
                if request.image == nil, !searchableIds.isEmpty {
                    // contextWindow is in tokens; the retrieval budget is in
                    // characters (~3.5 per token). Spend at most ~40% of the
                    // window on passages so the conversation still fits.
                    let windowChars = Double(appState.settings.contextWindow) * 3.5
                    let budget = max(2000, min(Int(windowChars * 0.4), 12000))
                    if let retrieved = await DocumentIndex.shared.context(
                        for: request.prompt, documentIds: searchableIds, budget: budget
                    ) {
                        generationPrompt = "\(retrieved)\n\nUsing the passages above when they're relevant, answer:\n\(request.prompt)"
                    } else if let seed = request.transientContext {
                        generationPrompt = "\(seed)\n\n\(request.prompt)"
                    }
                } else if let seed = request.transientContext {
                    generationPrompt = "\(seed)\n\n\(request.prompt)"
                }
                try Task.checkCancellation()

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
                    prompt: generationPrompt,
                    image: request.image
                )

                for try await snapshot in stream {
                    if Task.isCancelled { break }
                    streamingText = snapshot
                    finalText = snapshot
                }
            } catch is CancellationError {
                // Stop during generation is self-explanatory: the partial
                // answer is on screen. Stop during a multi-gigabyte DOWNLOAD
                // leaves nothing at all - no answer, no error, no chip - so
                // say what happened and offer a way back.
                if wasDownloading && finalText.isEmpty {
                    cancelledDownload = true
                }
                // The session was cut off mid-answer. Its cache now ends in
                // an unterminated assistant turn, and the next question
                // would be appended straight after it - the model then
                // tends to continue the answer it was stopped from giving.
                // Rebuild from the saved history instead.
                wasCancelled = true
            } catch {
                if !Task.isCancelled {
                    failure = error.localizedDescription
                }
            }

            // A vision model borrowed for one image question is released as
            // soon as the answer is done, rather than staying resident.
            appState.engine.releaseBorrowedVisionModel(routedModel)

            // Finalize on the main actor.
            let cleaned = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

            if !cleaned.isEmpty, let conv = conversation {
                let assistantMessage = appState.conversationManager.addMessage(
                    to: conv,
                    role: .assistant,
                    content: cleaned
                )
                // Only show the bubble if this conversation is still the one
                // on screen — the user may have switched chats mid-answer.
                if currentConversationId == conv.id {
                    messages.append(assistantMessage)

                    if appState.settings.hapticFeedbackEnabled {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                }
            }

            if wasCancelled {
                appState.engine.resetSessions()
            }

            if let failure, currentConversationId == conversation?.id {
                errorBanner = ErrorBanner(message: failure, canRetry: true)
                // The session may be mid-turn; rebuild next time.
                appState.engine.resetSessions()
            } else if cancelledDownload, currentConversationId == conversation?.id {
                errorBanner = ErrorBanner(
                    message: L10n.text("Download cancelled, so your message wasn't answered. What was already downloaded is kept - tap Try Again to continue."),
                    canRetry: true
                )
            } else if cleaned.isEmpty, !wasCancelled, currentConversationId == conversation?.id {
                // The stream ended cleanly with nothing in it. Without this
                // the question simply sat there unanswered, with no bubble
                // and no error, which reads as the app having ignored it.
                errorBanner = ErrorBanner(
                    message: L10n.text("No answer was produced. Tap Try Again, or rephrase the question."),
                    canRetry: true
                )
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

    /// "Not Now" on the download sheet: the sent message would otherwise sit
    /// unanswered with no affordance. Offer a retry.
    func declineConsent() {
        consentRequest = nil
        showDeclinedBanner()
    }

    /// The sheet went away by any route - button, swipe, or a system
    /// dismissal. Approving sets `consentApproved` first, so this only fires
    /// for a genuine decline.
    func consentSheetDismissed() {
        guard !consentApproved else {
            consentApproved = false
            return
        }
        showDeclinedBanner()
    }

    private func showDeclinedBanner() {
        guard lastRequest != nil, errorBanner == nil, !isGenerating else { return }
        errorBanner = ErrorBanner(
            message: L10n.text("The model isn't downloaded yet, so your message wasn't answered."),
            canRetry: true
        )
    }

    func approveConsentAndResend() {
        guard let request = consentRequest else { return }
        // Tell `consentSheetDismissed` this was an approval, not a decline.
        consentApproved = true
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

    /// Cancel and WAIT. `cancel()` alone only requests cancellation - the
    /// task's finalizer still runs and will happily re-append the partial
    /// answer to a chat the user just cleared.
    func stopGenerationAndWait() async {
        let task = generationTask
        task?.cancel()
        await task?.value
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
        guard !isClearing, let target = appState?.currentConversation else { return }
        isClearing = true
        let targetId = target.id
        // Wait for any in-flight answer to actually finish unwinding first.
        // Cancelling alone let the finalizer append a partial answer a
        // second after the user watched the chat empty.
        Task { @MainActor in
            await stopGenerationAndWait()
            defer { isClearing = false }
            // The user may have switched chats during that await. Clearing
            // whatever is on screen NOW would delete a different
            // conversation's messages, images and documents.
            guard appState?.currentConversation?.id == targetId else { return }
            performClear(target)
        }
    }

    private func performClear(_ target: Conversation) {
        // Actually delete the saved messages so the chat stays cleared -
        // including the extracted text of any attached documents, which the
        // user reasonably expects to be gone too.
        do {
            let conversation = target
            for message in conversation.messages {
                appState?.conversationManager.deleteMessage(message)
            }
            let docIds = conversation.attachedDocumentIds
            Task {
                for id in docIds { await DocumentIndex.shared.removeDocument(id) }
            }
            // Delete the photo files too. Forgetting them left every image
            // the user ever attached sitting on disk forever, which is not
            // what "clear this chat" means in an app about privacy.
            for imageId in conversation.attachedImageIds {
                try? FileManager.default.removeItem(at: ConversationManager.imagePath(for: imageId))
            }
            conversation.attachedDocumentIds.removeAll()
            conversation.attachedImageIds.removeAll()
            appState?.conversationManager.updateConversation(conversation)
        }
        clearPendingDocument()

        messages.removeAll()
        pendingImage = nil
        pendingImageId = nil
        pendingDocumentName = nil
        pendingDocumentContent = nil
        errorBanner = nil
        imageCache.removeAll()
        // Otherwise "Try Again" - or approving a consent sheet that is still
        // open - regenerates an answer into the chat just emptied.
        lastRequest = nil
        consentRequest = nil
        appState?.engine.resetSessions()
    }

    // MARK: - Memory

    /// Drop the decoded-image cache. Bitmaps are the largest thing this view
    /// model holds and they can all be read back from disk.
    func releaseMemory() {
        let keep = pendingImageId
        imageCache = imageCache.filter { $0.key == keep }
    }

    // MARK: - Image Storage

    private func saveImage(_ image: UIImage, withId id: UUID) {
        guard let data = ImageNormalizer.upright(image).jpegData(compressionQuality: 0.8) else { return }
        // Protected at rest: an attached photo can be a medical result or a
        // document, and should not be readable while the device is locked.
        try? data.write(
            to: ConversationManager.imagePath(for: id),
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
    }

    private func getImagePath(for id: UUID) -> URL? {
        ConversationManager.imagePath(for: id)
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
        .accessibilityLabel(Text(
            (message.role == .user
                // Markdown stripped first, or VoiceOver announces "asterisk
                // asterisk important asterisk asterisk" and reads entire
                // code blocks aloud as character soup.
                ? L10n.text("You said: \(VoiceService.plainSpeech(from: message.content))")
                : L10n.text("Assistant said: \(VoiceService.plainSpeech(from: message.content))"))
            + " " + message.timestamp.formatted(date: .omitted, time: .shortened)
        ))
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
        // Spoken without its Markdown: VoiceOver reading "asterisk asterisk
        // important asterisk asterisk" is the single most reported complaint
        // about AI chat apps from screen reader users.
        .accessibilityLabel(Text("Assistant is responding: \(VoiceService.plainSpeech(from: text))"))
    }
}

// MARK: - Download Consent Sheet

struct ModelDownloadConsentSheet: View {
    let model: AIModel
    let reason: String
    let onApprove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            // Scrollable content so the buttons below stay reachable at
            // large Dynamic Type sizes.
            ScrollView {
                VStack(spacing: 20) {
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
                }
                .padding(.top, 12)
                .frame(maxWidth: 500)
                .frame(maxWidth: .infinity)
            }

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
                    .frame(minHeight: 44)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
            .frame(maxWidth: 500)
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
                // A portrait capture carries `.right`; bake it in now so
                // every downstream consumer sees the picture the user saw.
                onImageCaptured(ImageNormalizer.upright(image))
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
    /// An infinite repeating animation is exactly what Reduce Motion asks
    /// apps not to do.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(.gray)
                        .frame(width: 8, height: 8)
                        .scaleEffect(animating && !reduceMotion ? 1 : 0.5)
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeInOut(duration: 0.6)
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
    let appState = AppState()
    return ChatView(viewModel: appState.chatViewModel)
        .environmentObject(appState)
}
