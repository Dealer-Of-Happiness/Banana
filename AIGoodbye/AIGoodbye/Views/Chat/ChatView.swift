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
import QuickLook
import StoreKit
import Network

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    /// Owned by AppState so drafts and in-flight answers survive the
    /// language-change rebuild of the view tree.
    @ObservedObject var viewModel: ChatViewModel
    /// The persona is part of the chat's identity (subtitle, overflow menu);
    /// observed here so a change made in Settings shows up without a reload.
    @ObservedObject private var personaStore = PersonaStore.shared
    @FocusState private var isInputFocused: Bool
    /// Moves VoiceOver onto the newest answer when it completes. "Answer
    /// complete" alone left the user sitting on the composer, swiping back
    /// through Send and the attachments menu to find the reply.
    @AccessibilityFocusState private var focusedMessage: UUID?

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
    @State private var showingRenameAlert = false
    @State private var renameText = ""
    /// A Markdown or PDF export waiting for the share sheet.
    @State private var exportURL: URL?
    @State private var exportFailed = false
    /// A message opened in the selectable-text sheet (VoiceOver's Share
    /// action uses the same share sheet as the export).
    @State private var selectableText: SelectableText?
    @State private var shareText: SelectableText?
    /// An attached image opened full screen.
    @State private var previewURL: URL?
    /// Whether the transcript is scrolled to the bottom, so a streaming
    /// answer follows along without stealing the scroll from the user.
    @State private var isPinnedToBottom = true
    /// Whether the transcript is taller than its viewport (a drag on a
    /// short chat is a rubber-band, not a request to stop following).
    @State private var isScrollable = false

    /// Store screenshots want the question at the top of the chat, not the
    /// end of the answer (AIG_DEMO_TOP=1). Debug builds only; always false
    /// in the app people install.
    private var demoOpensAtTop: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["AIG_DEMO_TOP"] == "1"
        #else
        return false
        #endif
    }
    @State private var showingSetup = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    /// Drawer or sidebar, decided by `MainView` for this window.
    @Environment(\.conversationListStyle) private var listStyle
    /// Shown once, right after the terms, so a new user knows where they
    /// stand before typing anything.
    @AppStorage("hasSeenSetup") private var hasSeenSetup = false

    /// A full-screen feature is up. Nothing from the chat (a review prompt,
    /// focus moves) should interrupt the recorder or a voice conversation.
    private var coveringFeatureIsUp: Bool {
        showingVoiceMode || showingRecorder || showingLiveCamera
            || showingSceneDescription || showingScanner || showingCamera || showingSetup
    }

    /// The consent copy has four bullets App Review and privacy-minded users
    /// actually read. At accessibility sizes, and on a landscape phone, the
    /// medium detent showed two lines and hid the rest with no scroll hint.
    /// Larger text too: on an iPhone SE at the largest standard size the
    /// last sentence sat under the Download button.
    private var consentDetents: Set<PresentationDetent> {
        dynamicTypeSize > .large || verticalSizeClass == .compact
            ? [.large]
            : [.medium, .large]
    }

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
                    // Keyed to the text: a second fact saved within six
                    // seconds otherwise inherited the first one's timer.
                    .task(id: notice) {
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
            .background { keyboardShortcutButtons }
            .navigationTitle(chatTitle)
            // The model is the one thing worth knowing about a chat at a
            // glance; it used to live in a custom title view, which the
            // iPhone Duo vertical bar cannot show at all. A persona chosen
            // last week silently turns today's recipe question into a
            // translation, so it is named here too.
            .navigationSubtitle(chatSubtitle)
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
                    onCancel: { showingScanner = false },
                    onFail: { error in
                        showingScanner = false
                        viewModel.presentImportError(DocumentScannerView.failureMessage(for: error))
                    }
                )
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showingCamera) {
                // Full screen per Apple guidance for the camera (a sheet
                // letterboxes on iPad).
                PhotoCaptureView { image in
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
            .sheet(isPresented: $showingSetup) {
                SetupView()
                    .environmentObject(appState)
            }
            .sheet(item: $exportURL) { url in
                ShareSheet(items: [url])
            }
            .sheet(item: $shareText) { item in
                ShareSheet(items: [item.text])
            }
            .sheet(item: $selectableText) { item in
                SelectableTextSheet(text: item.text)
            }
            // Quick Look (QLPreviewController, presented by the system):
            // zoom, share and markup come with it, and a photographed form
            // or label is read full size.
            .quickLookPreview($previewURL)
            .onChange(of: previewURL) { old, new in
                // The composer's copy was only for this preview.
                if new == nil, let old, old.lastPathComponent.hasPrefix(Self.composerPreviewPrefix) {
                    try? FileManager.default.removeItem(at: old)
                }
            }
            .alert("Couldn't export this chat", isPresented: $exportFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please try again.")
            }
            .sheet(isPresented: $showingRenameAlert, onDismiss: { renameText = "" }) {
                TextEntrySheet(
                    title: "Rename Chat",
                    message: "Enter a new name for this chat",
                    placeholder: "Chat name",
                    actionTitle: "Rename",
                    initialText: renameText
                ) { name in
                    if let conversation = appState.currentConversation {
                        appState.conversationManager.renameConversation(conversation, to: name)
                        appState.objectWillChange.send()
                    }
                }
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
                .presentationDetents(consentDetents)
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
        // The composer keeps its focus between messages. When the drawer
        // opens over the chat, this screen is disabled; a disabled view that
        // still held focus swallowed the taps of the drawer's own alerts
        // (Create in New Folder did nothing). Let go of it here.
        .onChange(of: appState.showSideMenu) { _, isOpen in
            if isOpen, listStyle == .drawer { isInputFocused = false }
        }
        // An answer finished in THIS chat (not a chat being loaded, whose
        // message count also jumps): move VoiceOver onto it, and consider
        // asking for a rating now that the user has something to rate.
        .onChange(of: viewModel.lastCompletedAnswerId) { _, id in
            // Voice mode answers through this same chat; its own screen is
            // in front and keeps VoiceOver.
            guard let id, !coveringFeatureIsUp else { return }
            // Only with VoiceOver on. Without it nothing ever takes the
            // focus, so the request stayed pinned to the bubble - and once
            // the drawer covered the chat, the drawer's own alerts (New
            // Folder, Rename) stopped responding to taps.
            if UIAccessibility.isVoiceOverRunning {
                focusedMessage = id
            }
            maybeRequestReview()
        }
        // A downloaded model must not keep generating from the background
        // (see `pauseForBackground`). `.inactive` is left alone: Control
        // Center and the Face ID prompt pass through it.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: viewModel.pauseForBackground()
            case .active: viewModel.resumeFromBackground()
            default: break
            }
        }
    }

    private func applyPendingRoute() {
        guard let route = appState.pendingRoute else { return }
        appState.pendingRoute = nil
        switch route {
        case .voice: showingVoiceMode = true
        case .camera: showingLiveCamera = true
        case .translate: showingTranslate = true
        case .describe: showingSceneDescription = true
        case .recorder: showingRecorder = true
        case .newChat:
            appState.createNewConversation()
            isInputFocused = true
        }
    }

    /// Asks for a rating only after a completed answer, never on top of an
    /// error, and never while the recorder, voice mode or onboarding is up:
    /// the system prompt would land on the wrong screen.
    private func maybeRequestReview() {
        guard hasSeenSetup, !coveringFeatureIsUp, viewModel.errorBanner == nil,
              viewModel.lastAnswerFinishedNormally else { return }
        guard ReviewPrompter.shouldAskAfterAnswer() else { return }
        ReviewPrompter.markAsked()
        requestReview()
    }

    // MARK: - Toolbar

    private var chatTitle: String {
        appState.currentConversation?.displayTitle ?? L10n.text("New Chat")
    }

    /// The default persona is implied; any other one is named next to the
    /// model, because it changes every answer.
    private var chatSubtitle: String {
        let model = appState.engine.selectedModel.name
        guard let persona = personaStore.selected, !isDefaultPersona(persona) else { return model }
        return L10n.text("\(model) · \(persona.name)")
    }

    private func isDefaultPersona(_ persona: Persona) -> Bool {
        persona.isBuiltIn && persona.instructions.isEmpty
    }

    /// Picker selection for the persona submenu. The store uses nil for the
    /// plain assistant; the picker needs a concrete id, so the built-in
    /// "General Assistant" stands in for nil both ways.
    private var personaSelection: Binding<UUID?> {
        Binding(
            get: {
                personaStore.selectedId ?? personaStore.all.first(where: isDefaultPersona)?.id
            },
            set: { newId in
                let chosen = personaStore.all.first { $0.id == newId }
                personaStore.selectedId = chosen.map(isDefaultPersona) == true ? nil : newId
                // The system prompt changed; sessions rebuild on the next turn.
                appState.engine.resetSessions()
            }
        )
    }

    /// Every item has an icon and a title. On iPhone Duo the system lays
    /// these out vertically beside the display when the device is closed,
    /// and only items with a symbol make it into that bar; an item that is
    /// a custom view simply disappears. Titles feed the overflow menu.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Conversations", systemImage: "line.3.horizontal") {
                appState.toggleSideMenu(twoPane: listStyle == .sidebar)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .accessibilityLabel(Text("Conversations menu"))
        }

        if #available(iOS 27, *) {
            // Kept out of the overflow menu: switching models is the one
            // thing people do from this bar. (When the bar is too narrow
            // for the title the system hides the title rather than fold
            // items away, so priority is not what keeps the title on
            // screen; `MainView` leaves the chat wide enough instead.)
            ToolbarItem(placement: .primaryAction) {
                Button("Choose Model", systemImage: "cpu") {
                    showingModelPicker = true
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            .visibilityPriority(.high)

            // The system's own overflow menu, so people find everything in
            // one place when space is tight, rather than an app-specific
            // ellipsis beside the system's.
            ToolbarOverflowMenu {
                chatMenuItems(includeModelPicker: false)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Chat Options", systemImage: "ellipsis.circle") {
                    chatMenuItems(includeModelPicker: true)
                }
                .accessibilityLabel(Text("Chat options"))
            }
        }
    }

    /// Hardware-keyboard shortcuts for commands that otherwise sit inside a
    /// menu. On iPadOS a shortcut on a button in a closed `Menu` does not
    /// fire, so these are zero-size buttons that are always in the view
    /// tree; their titles are what the Command-key overlay lists. (Send,
    /// Stop, Conversations and the iOS 27 Choose Model button carry theirs.)
    @ViewBuilder
    private var keyboardShortcutButtons: some View {
        // Each button is hidden from accessibility on its own: hiding only
        // the container left them visible to VoiceOver (and UI tests) as
        // invisible duplicates of the real Stop and Regenerate controls.
        ZStack {
            Button("Regenerate") {
                viewModel.regenerateLastResponse()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(viewModel.isGenerating || viewModel.messages.isEmpty)
            .accessibilityHidden(true)

            if #available(iOS 27, *) {
                EmptyView()
            } else {
                Button("Choose Model") {
                    showingModelPicker = true
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .accessibilityHidden(true)
            }

            // Escape is on the Stop button itself; Command-period is the
            // other "stop" every Mac and iPad user knows.
            if viewModel.isGenerating {
                Button("Stop") {
                    viewModel.stopGeneration()
                }
                .keyboardShortcut(".", modifiers: .command)
                .accessibilityHidden(true)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One list for both overflow menus (iOS 27's system menu and the
    /// pre-27 ellipsis), so they can never drift apart.
    @ViewBuilder
    private func chatMenuItems(includeModelPicker: Bool) -> some View {
        // Keyboard shortcuts for these two live in `keyboardShortcutButtons`:
        // inside a closed menu they never fire.
        Button("Regenerate", systemImage: "arrow.clockwise") {
            viewModel.regenerateLastResponse()
        }
        .disabled(viewModel.isGenerating)

        if includeModelPicker {
            Button("Choose Model", systemImage: "cpu") {
                showingModelPicker = true
            }
        }

        // A submenu with checkmarks: the persona applies to every answer,
        // and it used to be visible only three taps deep in Settings.
        Menu("Persona", systemImage: "person.crop.circle") {
            Picker("Persona", selection: personaSelection) {
                ForEach(personaStore.all) { persona in
                    Label(persona.name, systemImage: persona.symbol)
                        .tag(Optional(persona.id))
                }
            }
            .pickerStyle(.inline)
        }

        Button("Rename", systemImage: "pencil") {
            renameText = appState.currentConversation?.displayTitle ?? ""
            showingRenameAlert = true
        }
        .disabled(appState.currentConversation == nil)

        Divider()

        Button("Export as Markdown", systemImage: "doc.text") {
            guard let conversation = appState.currentConversation else { return }
            if let url = ConversationExporter.markdownFile(for: conversation) {
                exportURL = url
            } else {
                exportFailed = true
            }
        }
        .disabled(viewModel.messages.isEmpty)

        Button("Export as PDF", systemImage: "doc.richtext") {
            guard let conversation = appState.currentConversation else { return }
            if let url = ConversationExporter.pdfFile(for: conversation) {
                exportURL = url
            } else {
                exportFailed = true
            }
        }
        .disabled(viewModel.messages.isEmpty)

        // For the "paste it into Notes" case, where a file is one step too many.
        Button("Copy Conversation", systemImage: "doc.on.doc") {
            guard let conversation = appState.currentConversation else { return }
            UIPasteboard.general.string = ConversationExporter.markdown(for: conversation)
            viewModel.confirmCopy()
        }
        .disabled(viewModel.messages.isEmpty)

        Divider()

        Button("Clear Chat", systemImage: "trash", role: .destructive) {
            showingClearConfirmation = true
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
                    let lastMessageId = viewModel.messages.last?.id
                    ForEach(viewModel.messages, id: \.id) { message in
                        // Only an answer that ends the chat: with an
                        // unanswered question after it, the new answer
                        // would land under the wrong question.
                        let canRegenerate = message.role == .assistant && !viewModel.isGenerating
                            && message.id == lastMessageId
                        let attachedImageId = message.attachmentType == .image ? message.attachmentId : nil

                        MessageBubble(
                            message: message,
                            image: message.attachmentId.flatMap { viewModel.getImage(for: $0) },
                            onTapImage: imagePreviewAction(for: attachedImageId)
                        )
                        .id(message.id.uuidString)
                        .accessibilityFocused($focusedMessage, equals: message.id)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = visibleText(of: message)
                                viewModel.confirmCopy()
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }

                            // iOS text selection is all-or-nothing on a
                            // bubble; a sentence or a number out of a long
                            // answer needs a real text view.
                            Button {
                                selectableText = SelectableText(text: selectableContent(of: message))
                            } label: {
                                Label("Select Text", systemImage: "text.cursor")
                            }

                            ShareLink(item: visibleText(of: message)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }

                            // Regenerate only the LAST answer: regenerating a
                            // middle-of-chat reply would append the new answer
                            // at the bottom, out of context.
                            if canRegenerate {
                                Button {
                                    viewModel.regenerateResponse(for: message)
                                } label: {
                                    Label("Regenerate", systemImage: "arrow.clockwise")
                                }
                            }
                        }
                        // The bubble is one combined element, so its context
                        // menu is reachable only by knowing to double-tap and
                        // hold. The same actions, as VoiceOver actions. A
                        // builder, not a conditional modifier, so the bubble
                        // keeps its identity when Regenerate comes and goes.
                        .accessibilityActions {
                            Button("Copy") {
                                UIPasteboard.general.string = visibleText(of: message)
                                viewModel.confirmCopy()
                            }
                            Button("Share") {
                                shareText = SelectableText(text: visibleText(of: message))
                            }
                            Button("Select Text") {
                                selectableText = SelectableText(text: selectableContent(of: message))
                            }
                            if canRegenerate {
                                Button("Regenerate") {
                                    viewModel.regenerateResponse(for: message)
                                }
                            }
                            if let open = imagePreviewAction(for: attachedImageId) {
                                Button("View full screen", action: open)
                            }
                        }
                    }

                    // Live streaming bubble
                    if let streaming = viewModel.streamingText {
                        StreamingBubble(text: streaming)
                            .id("streaming")
                    } else if viewModel.isGenerating {
                        // While the model is still being fetched or loaded
                        // the chip explains the wait; the indicator's own
                        // "reading the conversation" copy would be wrong.
                        TypingIndicator(modelIsLoading: engineIsLoadingModel)
                            .id("typing")
                    }
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            // Dragging the transcript pulls the keyboard down with it, as in
            // Messages; before this there was no gesture to get it out of
            // the way once Send stopped dismissing it.
            .scrollDismissesKeyboard(.interactively)
            // A firm edge under the title bar. With the soft default, an
            // answer scrolled under the bar stayed readable through it, so
            // at large text sizes the chat name, the model and even the
            // status bar clock sat on top of the answer's lines (an iPhone
            // SE with Larger Text, reported by a tester).
            .scrollEdgeEffectStyle(.hard, for: .top)
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
                        // Only when there is somewhere to scroll: a
                        // rubber-band pull on a short chat unpinned with
                        // no way back until content grew.
                        if value.translation.height > 0, isScrollable { isPinnedToBottom = false }
                    }
            )
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height > geometry.containerSize.height
            } action: { _, scrollable in
                isScrollable = scrollable
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let bottom = geometry.contentOffset.y + geometry.containerSize.height
                return bottom >= geometry.contentSize.height - 120
            } action: { _, atBottom in
                // Re-pin as soon as the user comes back to the bottom.
                if atBottom { isPinnedToBottom = true }
            }
            // Open at the newest message. The count-based scroll below never
            // fired on a cold launch or when coming back from an empty New
            // Chat: the scroll view was created in the same update the
            // messages arrived, so there was no change to observe.
            .defaultScrollAnchor(demoOpensAtTop ? .top : .bottom)
            .onChange(of: appState.currentConversation?.id, initial: true) { _, _ in
                isPinnedToBottom = true
                guard !demoOpensAtTop else { return }
                proxy.scrollTo(viewModel.messages.last?.id.uuidString, anchor: .bottom)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                // A message the user just sent always scrolls; the answer
                // being appended must not yank back a reader who scrolled
                // up to re-read something while it streamed.
                guard viewModel.messages.last?.role == .user || isPinnedToBottom else { return }
                isPinnedToBottom = true
                withAnimation {
                    proxy.scrollTo(viewModel.messages.last?.id.uuidString, anchor: .bottom)
                }
            }
            .onChange(of: isInputFocused) { _, focused in
                // The keyboard shrinks the scroll view but keeps its offset,
                // hiding the newest messages behind the composer.
                guard focused, isPinnedToBottom else { return }
                DispatchQueue.main.async {
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

    /// The engine is still fetching or loading weights for this answer.
    private var engineIsLoadingModel: Bool {
        appState.engine.mlx.isDownloading || appState.engine.mlx.isPreparingModel
    }

    // MARK: - Message actions

    /// What the bubble shows: a document question without its "[file] "
    /// prefix. Copy and Share hand over this, not the stored form.
    private func visibleText(of message: Message) -> String {
        MessageBubble.displayParts(
            of: message.content, isDocument: message.attachmentType == .document
        ).text
    }

    /// For the Select Text sheet: an answer without its Markdown markers, so
    /// a selected sentence pastes as the sentence.
    private func selectableContent(of message: Message) -> String {
        message.role == .assistant
            ? MarkdownText.plainText(message.content)
            : visibleText(of: message)
    }

    private static let composerPreviewPrefix = "composer-preview-"

    /// The photo waiting in the composer, full screen. It has no file yet
    /// (attachments are written when sent), and Quick Look needs one: a
    /// protected temporary copy, removed when the preview closes. A fresh
    /// name each time, because Quick Look caches by URL.
    private func previewPendingImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.composerPreviewPrefix + UUID().uuidString + ".jpg")
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            previewURL = url
        } catch {
            // Nothing to show; the attachment itself is unaffected.
        }
    }

    /// Opens an attached photo full screen from its saved JPEG. The file is
    /// only checked on tap, not on every redraw of the transcript.
    private func imagePreviewAction(for imageId: UUID?) -> (() -> Void)? {
        guard let imageId else { return nil }
        let url = ConversationManager.imagePath(for: imageId)
        return {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            previewURL = url
        }
    }

    // MARK: - Engine status chip

    @ViewBuilder
    private var engineStatusChip: some View {
        if let paused = viewModel.pausedDownload, !appState.engine.mlx.isDownloading {
            pausedDownloadChip(paused)
        } else {
            activeEngineStatusChip
        }
    }

    /// A download paused from the chip. The partial files are kept, so
    /// Resume continues rather than starting over.
    private func pausedDownloadChip(_ model: AIModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.text("\(model.name) · \(L10n.text("Paused"))"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                viewModel.resumeDownload()
            } label: {
                Label("Resume", systemImage: "play.circle")
                    .font(.caption.weight(.medium))
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
    }

    @ViewBuilder
    private var activeEngineStatusChip: some View {
        switch appState.engine.status {
        case .downloading(let progress):
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    // Three steady lines: the model's name (it does not change
                    // while the bytes tick), the bar, and the figures on one
                    // line that shrinks rather than wraps. Name, bar and
                    // figures used to share one line; with large text the
                    // figures re-wrapped on every update and the whole chip
                    // jumped up and down for the length of the download.
                    Text(L10n.text("Downloading \(loadingModelName)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: progress)
                    Text(downloadDetailText(progress: progress))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    // Orange on the icon only: orange caption text on gray is
                    // about 2:1, unreadable for the people who most need it.
                    if appState.engine.mlx.isWaitingForWiFi {
                        // Parked, not stalled: the Wi-Fi-only setting is doing
                        // its job on cellular, and the system waits silently.
                        Label {
                            Text("Waiting for Wi-Fi. Connect to Wi-Fi, or turn off \"Download over Wi-Fi only\" in Settings.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "wifi.slash")
                                .foregroundStyle(.orange)
                        }
                        .font(.caption2)
                    } else if appState.engine.mlx.isDownloadStalled {
                        Label {
                            Text("Download stalled. Check your internet connection.")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity)
                // One element with its own label: `.combine` kept only the
                // model's name once the bar sat between it and the figures,
                // so VoiceOver never heard how far the download had got.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(downloadAccessibilityLabel(progress: progress)))
                .accessibilityAddTraits(.updatesFrequently)

                // The only way to stop a transfer used to be the composer's
                // red Stop, which reads as "stop generating". Outside the
                // combined element so VoiceOver reaches it.
                Button {
                    viewModel.pauseDownload()
                } label: {
                    Image(systemName: "pause.circle")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(Text("Pause"))
            }
            .padding(.horizontal)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGray6))
        case .preparing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing \(loadingModelName)...")
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

    /// The model being fetched or loaded right now - not necessarily the
    /// selected one (an image question on Apple Intelligence borrows a
    /// vision model, and the chip used to say "Preparing Apple Intelligence").
    private var loadingModelName: String {
        appState.engine.mlx.loadingModelName ?? appState.engine.selectedModel.name
    }

    /// The chip as VoiceOver reads it: name, figures and any warning, with
    /// commas where the screen shows separate lines and a middle dot.
    private func downloadAccessibilityLabel(progress: Double) -> String {
        var parts = [L10n.text("Downloading \(loadingModelName)")]
        parts.append(contentsOf: downloadDetailParts(progress: progress))
        if appState.engine.mlx.isWaitingForWiFi {
            parts.append(L10n.text("Waiting for Wi-Fi. Connect to Wi-Fi, or turn off \"Download over Wi-Fi only\" in Settings."))
        } else if appState.engine.mlx.isDownloadStalled {
            parts.append(L10n.text("Download stalled. Check your internet connection."))
        }
        return parts.joined(separator: ", ")
    }

    private func downloadDetailText(progress: Double) -> String {
        downloadDetailParts(progress: progress).joined(separator: " · ")
    }

    /// "213 MB of 1.8 GB", "about 4 min left" when byte counts are known,
    /// falling back to a simple percentage. The model's name is on the line
    /// above.
    private func downloadDetailParts(progress: Double) -> [String] {
        let mlx = appState.engine.mlx
        var parts: [String] = []
        if mlx.totalDownloadBytes > 1, mlx.downloadedBytes > 0 {
            let done = ByteCountFormatter.string(fromByteCount: mlx.downloadedBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: mlx.totalDownloadBytes, countStyle: .file)
            parts.append(L10n.text("\(done) of \(total)"))
        } else {
            // Locale-aware: "45 %" in French, "%45" in Turkish.
            parts.append(progress.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
        }
        // "213 MB of 1.8 GB" says nothing about whether to wait or walk away.
        if let eta = remainingTimeText {
            parts.append(L10n.text("about \(eta) left"))
        }
        return parts
    }

    /// "4 min" / "40 sec" from the download's measured speed; nil until the
    /// service has enough data for an honest estimate.
    private var remainingTimeText: String? {
        guard let seconds = appState.engine.mlx.estimatedSecondsRemaining,
              seconds.isFinite, seconds > 0 else { return nil }
        let whole = Int64(seconds.rounded())
        // Minutes are precise enough past one; seconds tick distractingly.
        let duration: Duration
        let units: Set<Duration.UnitsFormatStyle.Unit>
        if whole >= 60 {
            duration = .seconds(max(60, (whole + 30) / 60 * 60))
            units = [.hours, .minutes]
        } else {
            duration = .seconds(max(1, whole))
            units = [.seconds]
        }
        return duration.formatted(.units(allowed: units, width: .abbreviated).locale(L10n.locale))
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
                // A landscape phone has about 350 pt to work with; the
                // generous top space of the portrait layout would push the
                // quick actions out of view.
                Spacer(minLength: verticalSizeClass == .compact ? 12 : 60)

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

                // The smallest models answer with the same confidence whether
                // they are right or not (a tester was told the German flag is
                // white, red and green). Say so where a chat begins, not in a
                // terms screen nobody reads.
                if appState.engine.selectedModel.prefersCompactPrompt {
                    Label {
                        Text("Small models like \(appState.engine.selectedModel.name) often get facts wrong. Check anything important.")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                    .accessibilityElement(children: .combine)
                }

                // These are the app's actual capabilities, not just
                // "attach something". Nine features had been living behind a
                // "+" button labelled "Add photo or document", where nobody
                // would ever find them.
                //
                // An adaptive grid: one column on a phone, two on a wide
                // window. On an iPhone Duo folded like a book, two columns
                // put the gutter on the hinge rather than every row across it.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
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

                    // The feature blind and low-vision users come for; it
                    // was reachable only through the plus menu. Same
                    // availability rule as that menu.
                    #if !targetEnvironment(simulator)
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        QuickActionButton(
                            icon: "eye",
                            title: L10n.text("Describe Surroundings"),
                            subtitle: L10n.text("Describes what the camera is pointed at right now")
                        ) {
                            showingSceneDescription = true
                        }
                    }
                    #endif

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
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        // As for the transcript: nothing readable under the title bar.
        .scrollEdgeEffectStyle(.hard, for: .top)
    }

    // MARK: - Attachment Previews

    private func attachmentPreview(image: UIImage) -> some View {
        HStack(spacing: 12) {
            Button {
                previewPendingImage(image)
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.blue, lineWidth: 2)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Attached image"))
            .accessibilityHint(Text("Double-tap to view full screen"))

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
        documentSymbol(for: filename)
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

                    // A screenshot copied in Safari or Messages, without a
                    // detour through Photos. `hasImages` does not read the
                    // pasteboard, so the system paste notice appears only on
                    // tap, where it is expected.
                    if UIPasteboard.general.hasImages {
                        Button {
                            Task { await viewModel.pasteImage() }
                        } label: {
                            Label("Paste Image", systemImage: "doc.on.clipboard")
                        }
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
                    composerPlaceholder,
                    text: $viewModel.inputText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                // Two lines when the window is short: a five-line composer
                // over the keyboard on a landscape phone leaves no room to
                // read the answer being typed about.
                .lineLimit(verticalSizeClass == .compact ? 1...2 : 1...5)
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
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel(Text("Stop generating"))
                } else if canSend {
                    Button {
                        // Focus is left alone: the next message usually
                        // follows the answer, as in Messages. A drag on the
                        // transcript puts the keyboard away.
                        Task { await viewModel.sendMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(.blue)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    // Return inserts a newline in a multi-line field, so a
                    // hardware keyboard had no way to send at all.
                    .keyboardShortcut(.return, modifiers: .command)
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
            // Same reading width as the transcript, so the composer sits
            // under the bubbles rather than stretching across a wide display.
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(.bar)
    }

    /// Says what Send will do with what is attached.
    private var composerPlaceholder: String {
        if viewModel.pendingImage != nil { return L10n.text("Ask about this image...") }
        if viewModel.pendingDocumentName != nil { return L10n.text("Ask about this document...") }
        return L10n.text("Message...")
    }

    private var canSend: Bool {
        !viewModel.isGenerating && (
            !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            viewModel.pendingImage != nil ||
            viewModel.pendingDocumentName != nil
        )
    }
}

// MARK: - Review prompt

/// When to ask for an App Store rating: after a completed answer, once at
/// least five answers have completed on at least two different days, and
/// only once per app version. A paid app with no nag lives on ratings, and
/// until now only unhappy users found the rating page. Counters stay in
/// UserDefaults on the device.
enum ReviewPrompter {
    private static let answersKey = "review.completedAnswers"
    private static let daysKey = "review.answerDays"
    private static let askedVersionKey = "review.askedVersion"

    static func noteCompletedAnswer() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: answersKey) + 1, forKey: answersKey)
        let today = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        var days = defaults.array(forKey: daysKey) as? [Int] ?? []
        if !days.contains(today) {
            days.append(today)
            // Only "at least two" is ever asked; a week is plenty.
            defaults.set(Array(days.suffix(7)), forKey: daysKey)
        }
    }

    static func shouldAskAfterAnswer() -> Bool {
        let defaults = UserDefaults.standard
        guard let version = currentVersion, defaults.string(forKey: askedVersionKey) != version else {
            return false
        }
        let days = defaults.array(forKey: daysKey) as? [Int] ?? []
        return defaults.integer(forKey: answersKey) >= 5 && days.count >= 2
    }

    static func markAsked() {
        UserDefaults.standard.set(currentVersion, forKey: askedVersionKey)
    }

    private static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

// MARK: - Quick Action Button

struct QuickActionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    /// Grows with the `.title2` icon: a fixed 40 pt column clipped the
    /// symbol at accessibility sizes.
    @ScaledMetric(relativeTo: .title2) private var iconWidth: CGFloat = 40

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: iconWidth)
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
        /// The answer this request regenerates. It stays saved - and comes
        /// back on screen after a failure, a Stop before the first token or a
        /// declined download - until a non-empty replacement exists.
        var replacingMessageId: UUID? = nil
    }

    /// What each chat has learned about the people in it (see `PeopleGuard`).
    /// In memory only: after a relaunch a chat starts fresh, and the probe
    /// asks again.
    private var peopleStates: [UUID: PeopleState] = [:]
    /// The key for a chat that has no conversation yet.
    private static let unsavedChatKey = UUID()

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
    /// Shown briefly when something is added to private memory (or could
    /// not be, because memory is off). Spoken too: the notice appears above
    /// the composer, far from VoiceOver's focus.
    @Published var memoryNotice: String? {
        didSet {
            if let memoryNotice, memoryNotice != oldValue { Self.announce(memoryNotice) }
        }
    }
    /// The answer that just finished in the chat on screen - not one loaded
    /// with a chat, whose arrival also grows `messages`. The view moves
    /// VoiceOver to it and considers asking for a rating.
    @Published private(set) var lastCompletedAnswerId: UUID?
    /// Whether that answer ran to the end (not stopped, not a partial).
    private(set) var lastAnswerFinishedNormally = false
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
    /// Identifies the run that owns `isGenerating`, `streamingText` and
    /// `generationTask` (see `perform`).
    private var generationToken: UUID?
    private var lastRequest: PendingRequest?

    // MARK: - Conversation loading

    func loadConversation(_ conversation: Conversation?) {
        guard conversation?.id != currentConversationId else {
            // First appearance (and a cold launch that stays on "New Chat"):
            // nothing switched, but the draft saved for this chat still has
            // to come back.
            adoptDraftIfNeeded()
            return
        }

        // The half-written message belongs to the chat it was typed in.
        // Carried along, it was sent to whichever chat was opened next.
        saveDraft()

        stopGeneration()
        // Released here, not left to the cancelled task's finalizer: that
        // can be seconds away when it is parked in retrieval or a model
        // load, and meanwhile the new chat showed the old one's partial
        // answer, its typing dots and a Stop button, and ignored Send.
        // The token keeps that finalizer away from this chat's state.
        streamingText = nil
        isGenerating = false
        generationTask = nil
        generationToken = nil
        messages.removeAll()
        // Bitmaps from every chat visited used to accumulate here until a
        // memory warning. `getImage` refills from disk on demand.
        imageCache.removeAll()
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
        modelWaitTask?.cancel()
        modelWaitTask = nil
        currentConversationId = conversation?.id
        restoreDraft()

        // Sessions rebuild lazily on the next message.
        appState?.engine.resetSessions()

        if let conversation = conversation {
            messages = conversation.messages.sorted { $0.timestamp < $1.timestamp }
            loadCachedImages(for: conversation)
        }
    }

    // MARK: - Drafts

    /// Longest draft kept. A pasted article is not a draft worth persisting.
    private static let draftLimit = 4000
    /// True once `inputText` holds the draft of `currentConversationId`, so
    /// an empty composer is never written over a draft that was not loaded.
    private var draftAdopted = false

    /// `"draft.<conversation id>"`, or `"draft.new"` before a chat exists.
    /// Shared with ConversationManager, which removes it with the chat.
    nonisolated static func draftKey(for conversationId: UUID?) -> String {
        conversationId.map { "draft.\($0.uuidString)" } ?? "draft.new"
    }

    /// Writes the composer to the open chat's draft (or clears it when
    /// empty). Called on a switch and when the app goes to the background.
    func saveDraft() {
        guard draftAdopted else { return }
        // A chat deleted while open: its key was removed with it, and
        // writing here would bring it back as an orphan.
        if let id = currentConversationId,
           appState?.conversationManager.conversations.contains(where: { $0.id == id }) != true {
            return
        }
        let key = Self.draftKey(for: currentConversationId)
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(String(inputText.prefix(Self.draftLimit)), forKey: key)
        }
    }

    private func restoreDraft() {
        draftAdopted = true
        inputText = UserDefaults.standard.string(forKey: Self.draftKey(for: currentConversationId)) ?? ""
    }

    private func adoptDraftIfNeeded() {
        guard !draftAdopted else { return }
        draftAdopted = true
        // Text placed here before the first load (a share) wins over a draft.
        guard inputText.isEmpty else { return }
        inputText = UserDefaults.standard.string(forKey: Self.draftKey(for: currentConversationId)) ?? ""
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

            // One normalizer for every way a picture enters the app. The
            // old inline resize used the screen's scale, so "1024" was a
            // 3072-pixel bitmap on a 3x phone - nine times the pixels the
            // model ever sees, cached, drawn and written to disk as such.
            let processedImage = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let image = UIImage(data: data) else { return nil }
                return ImageNormalizer.attachment(image)
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

    /// The image on the pasteboard, through the same normalizer as a
    /// picked photo.
    func pasteImage() async {
        guard let pasted = UIPasteboard.general.image else {
            presentImportError(L10n.text("This photo couldn't be read. Try a different one."))
            return
        }
        let processed = await Task.detached(priority: .userInitiated) {
            ImageNormalizer.attachment(pasted)
        }.value
        pendingImage = processed
        pendingImageId = UUID()
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
                    try DocumentText.read(url)
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
            pendingDocumentId = try await DocumentIndex.shared.store(
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

        // The share sheet offers the app for any file. The same cap as the
        // picker: this used to read a shared video whole, on the main actor.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(size) > Self.maxImportBytes {
            let limit = ByteCountFormatter.string(fromByteCount: Self.maxImportBytes, countStyle: .file)
            presentImportError(L10n.text("This file is too large to import. The limit is \(limit)."))
            return
        }

        // Images become an attachment; everything else is read as a document.
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) {
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
                return ImageNormalizer.attachment(image)
            }.value
            if let image {
                pendingImage = image
                pendingImageId = UUID()
            } else {
                presentImportError(L10n.text("This photo couldn't be read. Try a different one."))
            }
            return
        }

        do {
            let text: String
            if url.pathExtension.lowercased() == "pdf" {
                text = try await extractTextFromPDF(url)
            } else {
                text = try await Task.detached(priority: .userInitiated) {
                    try DocumentText.read(url)
                }.value
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                presentImportError(L10n.text("No readable text was found in \(displayName)."))
                return
            }
            pendingDocumentName = displayName
            pendingDocumentContent = String(trimmed.prefix(4000))
            pendingDocumentId = try await DocumentIndex.shared.store(name: displayName, fullText: trimmed)
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

    /// Text of a PDF: its text layer, or on-device OCR when it has none
    /// (a scan). Shared with the Knowledge Library importer.
    func extractTextFromPDF(_ url: URL) async throws -> String {
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

        // In the app's language, not the device's.
        let name = L10n.text("Scan \(Date().aigFormatted(date: .abbreviated, time: .shortened))")
        pendingDocumentName = name
        pendingDocumentContent = String(trimmed.prefix(4000))
        do {
            pendingDocumentId = try await DocumentIndex.shared.store(name: name, fullText: trimmed)
        } catch {
            pendingDocumentName = nil
            pendingDocumentContent = nil
            presentImportError(L10n.text("Couldn't save the scan: \(error.localizedDescription)"))
            return
        }

        // Say what was left out rather than quietly handing over a document
        // with pages missing from it.
        if totalScanned > readable {
            scanNotice = L10n.text("Only the first \(readable) pages were read. Scan the rest separately.")
        } else if failed == 1 {
            scanNotice = L10n.text("One page had no readable text and was left out.")
        } else if failed > 0 {
            scanNotice = L10n.text("\(failed) of \(readable) pages had no readable text and were left out.")
        }
    }

    func presentImportError(_ message: String) {
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

        // Clear composer state, and the saved draft with it.
        inputText = ""
        UserDefaults.standard.removeObject(forKey: Self.draftKey(for: currentConversationId))
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
        guard let fact = MemoryStore.requestedFact(in: message) else { return false }
        guard MemoryStore.shared.isEnabled else {
            // "Remember that..." with memory off used to do nothing at all,
            // while the model cheerfully answered that it would remember.
            memoryNotice = L10n.text("Memory is off, so this wasn't saved. Turn it on in Settings.")
            return false
        }
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
        // This run's identity. Switching chats releases the composer at once
        // (see `loadConversation`); the cancelled run then finishes on its
        // own time and must not touch the state of the chat now on screen.
        let token = UUID()
        generationToken = token

        // Ensure a conversation exists.
        var conversation = appState.currentConversation
        if conversation == nil {
            conversation = appState.conversationManager.createConversation()
            appState.currentConversation = conversation
            currentConversationId = conversation?.id
        }

        // Regenerate: take the old answer off screen (and out of the history
        // the session is rebuilt from) but leave it saved. Deleting it up
        // front lost a good answer whenever the new one never came - a
        // failure, Stop before the first token, or "Not Now" on a download.
        let replaced: ReplacedAnswer?
        if let id = request.replacingMessageId, let index = messages.firstIndex(where: { $0.id == id }) {
            replaced = ReplacedAnswer(id: id, message: messages[index], index: index)
            messages.remove(at: index)
        } else {
            replaced = nil
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
                // Saved now, not with the answer: a crash while the model
                // loads left the append unsaved, and the launch sweep then
                // deleted the photo as an orphan.
                appState.conversationManager.updateConversation(conv)
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
            generationToken = nil
            // The old answer is shown again while the consent sheet is up;
            // approving re-runs this request, which hides it once more.
            restore(replaced, in: conversation?.id)
            handleRouteError(error)
            return
        } catch {
            isGenerating = false
            generationToken = nil
            restore(replaced, in: conversation?.id)
            errorBanner = ErrorBanner(message: error.localizedDescription, canRetry: true)
            return
        }

        streamingText = nil

        // Whether this turn had to fetch the model first, so a cancellation
        // can be explained accurately.
        let wasDownloading = routedModel.backend == .mlx && !routedModel.isDownloaded

        // The conversation's identity, captured before the task: the model
        // object itself may be deleted (swipe-to-delete, Clear All) while
        // the answer is in flight, and touching a deleted SwiftData model
        // traps.
        let conversationId = conversation?.id

        let task = Task {
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
                    // Budgeted against the window the ROUTED backend has, in
                    // weighted characters (~3 per token). Apple Intelligence
                    // works in 4096 tokens for instructions, transcript and
                    // answer together; sizing passages to the Settings
                    // context window (8K-32K) blew that every second turn.
                    let windowTokens = routedModel.backend == .appleIntelligence
                        ? AppleIntelligenceService.contextWindowTokens
                        : MLXService.effectiveContextWindow(for: routedModel, requested: appState.settings.contextWindow)
                    let budgetTokens = max(300, windowTokens / 4)
                    let budget = min(budgetTokens * 3, 12000)
                    if let retrieved = await DocumentIndex.shared.context(
                        for: request.prompt, documentIds: searchableIds,
                        libraryIds: Set(libraryIds), budget: budget
                    ) {
                        generationPrompt = "\(retrieved)\n\nUsing the passages above when they're relevant, answer:\n\(request.prompt)"
                    } else if let seed = request.transientContext {
                        generationPrompt = "\(seed)\n\n\(request.prompt)"
                    }
                } else if let seed = request.transientContext {
                    generationPrompt = "\(seed)\n\n\(request.prompt)"
                }
                try Task.checkCancellation()

                // One transparent retry when Apple Intelligence's transcript
                // outgrows its window: rebuild the session from trimmed
                // history and ask again, instead of blaming the length of
                // the conversation and making the user tap Try Again (which
                // did exactly this).
                var attempts = 0
                while true {
                    attempts += 1
                    // Build the session once per conversation; reuse it
                    // between turns. History must end after an assistant
                    // turn: trailing user turns are pending questions
                    // (including the one being asked now) and are delivered
                    // via streamResponse instead.
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

                    // Questions about people, on the smallest models: who
                    // the message is about and whether the model knows them,
                    // asked on the side first; some answers the app gives
                    // itself (see `PeopleGuard`).
                    let appLanguage = appState.settings.appLanguage
                    var people = PeopleGuard.Outcome()
                    if routedModel.prefersCompactPrompt {
                        let key = conversationId ?? Self.unsavedChatKey
                        var state = peopleStates[key] ?? PeopleState()
                        let mlx = appState.engine.mlx
                        people = await PeopleGuard.resolve(
                            question: request.prompt,
                            hasImage: request.image != nil,
                            appLanguage: appLanguage,
                            fallbackLanguage: AppLanguage(rawValue: L10n.deviceLanguageCode ?? "en") ?? .english,
                            rememberedFacts: MemoryStore.shared.isEnabled ? MemoryStore.shared.facts.map(\.text) : [],
                            state: &state,
                            probe: { prompt, maxTokens in await mlx.probe(prompt, maxTokens: maxTokens) }
                        )
                        peopleStates[key] = state
                        try Task.checkCancellation()
                    }
                    if let fixed = people.fixed {
                        finalText = fixed
                        if generationToken == token { streamingText = fixed }
                        // The model never saw this exchange; the next turn
                        // rebuilds its session from the saved chat, which has it.
                        appState.engine.mlx.dropSession()
                        break
                    }

                    // The answer language and, for a question about it,
                    // the date and time - taken now, after any download or
                    // load: a question asked at 10:41 and answered after a
                    // 30-minute download must still get the time right.
                    let stream = appState.engine.respondStream(
                        model: routedModel,
                        prompt: TurnContext.wrap(
                            generationPrompt,
                            question: request.prompt,
                            appLanguage: appLanguage,
                            personKnown: people.personKnown,
                            introducedName: people.introducedName,
                            noNamedPerson: people.noNamedPerson,
                            hasImage: request.image != nil
                        ),
                        image: request.image
                    )

                    do {
                        // Every snapshot is kept, but the bubble is redrawn at
                        // most every 80 ms: each redraw re-parses the Markdown
                        // of the growing paragraph, and at 30+ tokens a second
                        // that work, not the model, was what made scrolling and
                        // typing stutter on older phones.
                        let clock = ContinuousClock()
                        var lastShown: ContinuousClock.Instant?
                        for try await snapshot in stream {
                            if Task.isCancelled { break }
                            finalText = snapshot
                            let now = clock.now
                            if lastShown.map({ now - $0 >= .milliseconds(80) }) ?? true,
                               generationToken == token {
                                streamingText = snapshot
                                lastShown = now
                            }
                        }
                        // Final flush, so the last tokens are never skipped.
                        if generationToken == token, !finalText.isEmpty {
                            streamingText = finalText
                        }
                        break
                    } catch AppleIntelligenceError.contextExceeded where attempts == 1 && finalText.isEmpty {
                        appState.engine.resetSessions()
                        continue
                    }
                }
                // The stream ends quietly on cancellation (it never throws
                // CancellationError), so the catch below would not know.
                // Without this the session kept the truncated answer and
                // the next one continued it, and Stop before the first
                // token showed a false "No answer was produced".
                if Task.isCancelled { wasCancelled = true }
            } catch is CancellationError {
                // Stop during generation is self-explanatory: the partial
                // answer is on screen. Stop during a multi-gigabyte DOWNLOAD
                // leaves nothing at all - no answer, no error, no chip - so
                // say what happened and offer a way back (or, when the
                // download is in fact still running, that it will be answered;
                // see `explainStoppedDownload`).
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

            // Still exists? Deleting the open chat (or Clear All) while it
            // answers removes the model from the store; writing into it
            // afterwards traps, and even reading `conv.id` is unsafe.
            let conversationAlive = conversationId.map { id in
                appState.conversationManager.conversations.contains { $0.id == id }
            } ?? false
            let onScreen = conversationId != nil && currentConversationId == conversationId

            if !cleaned.isEmpty, conversationAlive, let conv = conversation {
                // The replacement exists, so the answer it replaces can go.
                if let replaced {
                    appState.conversationManager.deleteMessage(replaced.message)
                    if onScreen { messages.removeAll { $0.id == replaced.id } }
                }
                let assistantMessage = appState.conversationManager.addMessage(
                    to: conv,
                    role: .assistant,
                    content: cleaned
                )
                if !wasCancelled {
                    ReviewPrompter.noteCompletedAnswer()
                }
                // Only show the bubble if this conversation is still the one
                // on screen — the user may have switched chats mid-answer.
                if onScreen {
                    messages.append(assistantMessage)

                    if appState.settings.hapticFeedbackEnabled {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                    // Kept alongside the focus move: it is what a user whose
                    // focus is elsewhere (a sheet, another app) hears.
                    Self.announce(L10n.text("Answer complete"))
                    lastAnswerFinishedNormally = !wasCancelled
                    lastCompletedAnswerId = assistantMessage.id
                }
            } else if conversationAlive {
                // Nothing replaced it: the previous answer is still saved, so
                // put it back where it was.
                restore(replaced, in: conversationId)
            }

            // A newer run owns the engine session and the composer now; it
            // already started from a fresh session. Nor is an outcome
            // banner this run's to show: switching chats dropped its
            // `lastRequest`, so its Try Again would do nothing.
            let isCurrentRun = generationToken == token
            let showsOutcome = onScreen && isCurrentRun
            if wasCancelled, isCurrentRun {
                appState.engine.resetSessions()
            }

            if let failure, showsOutcome {
                errorBanner = ErrorBanner(message: failure, canRetry: true)
                Self.announce(failure)
                // The session may be mid-turn; rebuild next time.
                appState.engine.resetSessions()
            } else if cancelledDownload, showsOutcome {
                explainStoppedDownload(of: routedModel, conversationId: conversationId)
            } else if cleaned.isEmpty, !wasCancelled, showsOutcome {
                // The stream ended cleanly with nothing in it. Without this
                // the question simply sat there unanswered, with no bubble
                // and no error, which reads as the app having ignored it.
                errorBanner = ErrorBanner(
                    message: L10n.text("No answer was produced. Tap Try Again, or rephrase the question."),
                    canRetry: true
                )
                Self.announce(L10n.text("No answer was produced. Tap Try Again, or rephrase the question."))
                appState.engine.resetSessions()
            }

            if isCurrentRun {
                streamingText = nil
                isGenerating = false
                generationTask = nil
                generationToken = nil
            }
        }
        generationTask = task
        await task.value
    }

    /// An answer being regenerated: hidden while the new one is produced,
    /// deleted only once that one is saved. The id is kept separately so it
    /// can be compared without touching the model object.
    private struct ReplacedAnswer {
        let id: UUID
        let message: Message
        let index: Int
    }

    /// Puts a regenerate target back on screen where it was, provided its
    /// chat is still the one showing and it isn't already there (a reload
    /// from the store while it was hidden brings it back by itself).
    private func restore(_ replaced: ReplacedAnswer?, in conversationId: UUID?) {
        guard let replaced, conversationId != nil, currentConversationId == conversationId,
              !messages.contains(where: { $0.id == replaced.id }) else { return }
        messages.insert(replaced.message, at: min(replaced.index, messages.count))
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
        guard let last = lastRequest, errorBanner == nil, !isGenerating else { return }
        // A declined Regenerate leaves the previous answer in place; "your
        // message wasn't answered" would be untrue.
        guard last.replacingMessageId == nil else { return }
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
            // Already marked not to persist the user message again, and it
            // carries every field (document id, summary seed, the answer a
            // Regenerate replaces).
            Task { await perform(last) }
        }
    }

    // MARK: - Stop / Retry / Regenerate

    func stopGeneration() {
        generationTask?.cancel()
    }

    /// The app is leaving the foreground. A downloaded model keeps issuing
    /// GPU work from the background, which iOS refuses and MLX turns into
    /// an uncaught exception - the app simply disappeared. Apple
    /// Intelligence answers run in a system process and are left alone.
    ///
    /// Only GPU work is stopped. A pure download needs no Metal, and the
    /// background URL session exists so a multi-gigabyte model keeps coming
    /// while the phone is locked; cancelling on `isBusy` killed it on every
    /// lock and the user came back to "Download cancelled".
    func pauseForBackground() {
        // The app may never come back to the foreground; keep the draft.
        saveDraft()
        guard isGenerating, let appState, appState.engine.mlx.isUsingGPU else { return }
        generationTask?.cancel()
        backgroundStoppedAnswer = true
    }

    /// A download paused from the chip (`pauseDownload`); Resume continues it.
    @Published private(set) var pausedDownload: AIModel?
    /// Waits for a model still downloading after this chat's turn stopped,
    /// then asks the question (`answerWhenModelLoads`).
    private var modelWaitTask: Task<Void, Never>?

    /// Stops the transfer the chip shows. What was downloaded is kept, so
    /// `resumeDownload` continues from there. A turn waiting on it stops
    /// quietly (`explainStoppedDownload`): the paused chip says what happened.
    func pauseDownload() {
        guard let mlx = appState?.engine.mlx, mlx.isDownloading, let id = mlx.loadingModelId,
              let model = AIModel.model(withId: id) else { return }
        pausedDownload = model
        mlx.cancelLoad(of: id)
    }

    func resumeDownload() {
        guard let model = pausedDownload, let appState else { return }
        pausedDownload = nil
        // A question left waiting for this model is answered once it loads.
        if lastRequest != nil, messages.last?.role == .user {
            answerWhenModelLoads(model, conversationId: currentConversationId)
        }
        let engine = appState.engine
        Task { [weak self] in
            do {
                try await engine.prepare(model)
            } catch is CancellationError {
                // Paused again, or the model was removed meanwhile.
            } catch {
                self?.errorBanner = ErrorBanner(message: error.localizedDescription, canRetry: false)
            }
        }
    }

    /// The turn waiting on `model`'s download was stopped. Whether the
    /// download stopped with it is only known a moment later: the loader
    /// cancels the transfer from its own main-actor hop, and only when no
    /// other screen (Setup) is still waiting for it. Saying "Download
    /// cancelled" while the chip kept counting up was simply untrue.
    private func explainStoppedDownload(of model: AIModel, conversationId: UUID?) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, let appState = self.appState,
                  self.currentConversationId == conversationId,
                  !self.isGenerating, self.errorBanner == nil else { return }
            // Paused from the chip, which says so; Resume answers it.
            if self.pausedDownload?.id == model.id { return }
            let mlx = appState.engine.mlx
            if mlx.loadingModelId == model.id || mlx.loadedModelId == model.id {
                self.answerWhenModelLoads(model, conversationId: conversationId)
            } else {
                self.errorBanner = Self.downloadCancelledBanner
            }
        }
    }

    private static var downloadCancelledBanner: ErrorBanner {
        ErrorBanner(
            message: L10n.text("Download cancelled, so your message wasn't answered. What was already downloaded is kept - tap Try Again to continue."),
            canRetry: true
        )
    }

    private static var waitingForDownloadBanner: ErrorBanner {
        ErrorBanner(
            message: L10n.text("Downloading in the background. Your message will be answered when it finishes."),
            canRetry: false
        )
    }

    /// Keeps `lastRequest` and asks it as soon as `model` is loaded, in the
    /// same chat. If the download ends without loading (failed, or cancelled
    /// from Settings), falls back to the retryable "Download cancelled".
    private func answerWhenModelLoads(_ model: AIModel, conversationId: UUID?) {
        guard lastRequest != nil else { return }
        errorBanner = Self.waitingForDownloadBanner
        modelWaitTask?.cancel()
        modelWaitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, let mlx = self.appState?.engine.mlx else { return }
                // Another chat is open now: its composer is not this
                // question's place, and `loadConversation` dropped it.
                guard self.currentConversationId == conversationId else { return }
                if mlx.loadedModelId == model.id {
                    self.modelWaitTask = nil
                    if self.errorBanner == Self.waitingForDownloadBanner { self.errorBanner = nil }
                    if let last = self.lastRequest, !self.isGenerating {
                        await self.perform(last)
                    }
                    return
                }
                if mlx.loadingModelId != model.id, self.pausedDownload?.id != model.id {
                    self.modelWaitTask = nil
                    if self.errorBanner == Self.waitingForDownloadBanner {
                        self.errorBanner = Self.downloadCancelledBanner
                    }
                    return
                }
            }
        }
    }

    /// Set when `pauseForBackground` cut an answer short, so the user is
    /// told why on return instead of finding a half answer with no reason.
    private var backgroundStoppedAnswer = false

    func resumeFromBackground() {
        guard backgroundStoppedAnswer else { return }
        backgroundStoppedAnswer = false
        if errorBanner == nil, lastRequest != nil {
            errorBanner = ErrorBanner(
                message: L10n.text("The answer was stopped because the app went to the background. Tap Try Again to continue."),
                canRetry: true
            )
        }
    }

    /// Copy used to change nothing on screen, so people tapped again and
    /// VoiceOver users heard nothing at all.
    func confirmCopy() {
        if appState?.settings.hapticFeedbackEnabled ?? true {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        Self.announce(L10n.text("Copied"))
    }

    /// VoiceOver users get no other signal that an answer or an error has
    /// arrived: the Send button quietly turns back from Stop, a bubble is
    /// appended below the focus, and a banner is inserted above the composer.
    static func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        AccessibilityNotification.Announcement(text).post()
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
        Task { await perform(last) }
    }

    /// The one way to re-ask a question already in the chat. Fields only the
    /// original send knew - the document id and the summary seed for a
    /// "summarize this" with no keywords to retrieve on - are taken from
    /// `lastRequest` when it was this same question; hand-built copies in
    /// three places used to drop them.
    private func reaskRequest(for userMessage: Message, replacing answerId: UUID?) -> PendingRequest {
        var request = PendingRequest(
            prompt: userMessage.modelFacingContent,
            displayMessage: userMessage.content,
            hiddenContext: userMessage.hiddenContext,
            // From disk if the cache was dropped by a memory warning;
            // otherwise the picture quietly vanished from the question.
            image: userMessage.attachmentId.flatMap { getImage(for: $0) },
            imageId: nil,
            attachmentType: nil,
            persistUserMessage: false
        )
        if let last = lastRequest, last.displayMessage == userMessage.content {
            request.documentId = last.documentId
            request.transientContext = last.transientContext
        }
        request.replacingMessageId = answerId
        return request
    }

    func regenerateLastResponse() {
        guard !isGenerating else { return }
        // A trailing question with no answer (an error, or Stop before the
        // first token) is what the user wants retried. Regenerating the
        // previous answer instead destroyed a good one and appended the
        // result under the wrong question.
        if let last = messages.last, last.role == .user {
            errorBanner = nil
            appState?.engine.resetSessions()
            let retry = reaskRequest(for: last, replacing: nil)
            Task { await perform(retry) }
            return
        }
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

        // The old answer is NOT deleted here: `perform` hides it and deletes
        // it only once a non-empty replacement has been saved. The session
        // is rebuilt from the history without it.
        errorBanner = nil
        appState?.engine.resetSessions()
        let retry = reaskRequest(for: userMessage, replacing: message.id)
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
            // One save for all of them: a save per message froze the app
            // for seconds on a long chat.
            appState?.conversationManager.deleteMessages(Array(conversation.messages))
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
        // open, or a download finishing - answers into the chat just emptied.
        lastRequest = nil
        consentRequest = nil
        modelWaitTask?.cancel()
        modelWaitTask = nil
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
        // The folder is created on demand: "Clear All Conversations" used to
        // remove it, after which every photo attached until the next launch
        // was silently never written and vanished on relaunch.
        let path = ConversationManager.imagePath(for: id)
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Protected at rest: an attached photo can be a medical result or a
        // document, and should not be readable while the device is locked.
        do {
            try data.write(to: path, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            presentImportError(L10n.text("Couldn't save the photo: \(error.localizedDescription)"))
        }
    }

    private func getImagePath(for id: UUID) -> URL? {
        ConversationManager.imagePath(for: id)
    }
}

// MARK: - Message Bubble

/// SF Symbol for an attached file, by extension.
private func documentSymbol(for filename: String) -> String {
    let ext = (filename as NSString).pathExtension.lowercased()
    switch ext {
    case "pdf": return "doc.fill"
    case "txt", "md": return "doc.text.fill"
    case "json": return "curlybraces"
    case "swift", "py", "js", "html", "css": return "chevron.left.forwardslash.chevron.right"
    default: return "doc.fill"
    }
}

struct MessageBubble: View {
    let message: Message
    var image: UIImage? = nil
    /// Opens the attached image full screen; nil when there is none.
    var onTapImage: (() -> Void)? = nil
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// A document question is stored as "[file name] question" - older chats
    /// and the exports depend on that - and shown as a chip naming the file
    /// above the question alone, instead of a chip reading just "Document"
    /// and the brackets in the bubble.
    nonisolated static func displayParts(of content: String, isDocument: Bool) -> (documentName: String?, text: String) {
        guard isDocument, content.hasPrefix("["), let close = content.range(of: "] ") else {
            return (nil, content)
        }
        let name = String(content[content.index(after: content.startIndex)..<close.lowerBound])
        guard !name.isEmpty else { return (nil, content) }
        return (name, String(content[close.upperBound...]))
    }

    var body: some View {
        let parts = Self.displayParts(of: message.content, isDocument: message.attachmentType == .document)

        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if let image = image {
                    attachedImage(image)
                }

                if message.attachmentType == .document {
                    HStack(spacing: 4) {
                        Image(systemName: documentSymbol(for: parts.documentName ?? ""))
                        if let name = parts.documentName {
                            Text(verbatim: name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("Document")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Group {
                    if message.role == .assistant {
                        MarkdownText(content: message.content)
                    } else {
                        Text(parts.text)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
                .background(backgroundColor)
                .foregroundStyle(foregroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(message.timestamp.aigFormatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if message.role != .user { Spacer(minLength: 60) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(spokenLabel(text: parts.text)))
    }

    @ViewBuilder
    private func attachedImage(_ image: UIImage) -> some View {
        let picture = Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 250, maxHeight: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
            )
        if let onTapImage {
            // A photo of a form or a label has to be readable again later;
            // 250 x 200 is not that.
            Button(action: onTapImage) {
                picture
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Attached image"))
            .accessibilityHint(Text("Double-tap to view full screen"))
        } else {
            picture
                .accessibilityLabel(Text("Attached image"))
        }
    }

    /// What VoiceOver reads for the whole bubble. The Markdown is stripped
    /// only when VoiceOver is actually on: that is six string passes per line,
    /// and the transcript re-evaluates bubbles while an answer streams.
    /// Stripped, because "asterisk asterisk important asterisk asterisk" and
    /// code blocks read as character soup were the top complaint.
    private func spokenLabel(text: String) -> String {
        let spoken = voiceOverEnabled ? VoiceService.plainSpeech(from: text) : text
        var label = message.role == .user
            ? L10n.text("You said: \(spoken)")
            : L10n.text("Assistant said: \(spoken)")
        // The attachment is part of what was said; the combined element
        // otherwise hides it.
        if image != nil || message.attachmentType == .image {
            label += L10n.text(", with image")
        } else if message.attachmentType == .document {
            label += L10n.text(", with document")
        }
        return label + " " + message.timestamp.aigFormatted(date: .omitted, time: .shortened)
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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

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
        // about AI chat apps from screen reader users. Stripped only while
        // VoiceOver runs - this label is rebuilt on every streamed update.
        .accessibilityLabel(Text("Assistant is responding: \(spokenText)"))
    }

    private var spokenText: String {
        voiceOverEnabled ? VoiceService.plainSpeech(from: text) : text
    }
}

// MARK: - Select Text

/// Text handed to the Select Text sheet or the share sheet.
struct SelectableText: Identifiable {
    let id = UUID()
    let text: String
}

/// A message in a real text view, with selection handles, so one sentence,
/// one bullet or one number can be copied out of a long answer.
struct SelectableTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(Text("Select Text"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
        }
    }
}

private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view.alwaysBounceVertical = true
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}

// MARK: - Download Consent Sheet

struct ModelDownloadConsentSheet: View {
    let model: AIModel
    let reason: String
    let onApprove: () -> Void
    let onCancel: () -> Void

    /// Live, like Setup's: "Wi-Fi recommended" told a cellular user nothing,
    /// and they learned the download was parked only after agreeing to it.
    @State private var isOnWiFi = true
    @State private var monitor: NWPathMonitor?
    /// Free space for important use, read when the sheet opens.
    @State private var freeBytes: Int64?
    /// What the download still needs, with the same headroom as the
    /// loader's own preflight - which otherwise refuses only after consent.
    @State private var neededBytes: Int64 = 0
    /// Same key as `SettingsManager.wifiOnlyDownloads`.
    @AppStorage("wifi_only_downloads") private var wifiOnlyDownloads = true

    private var lacksSpace: Bool {
        guard let freeBytes else { return false }
        return freeBytes < neededBytes
    }

    var body: some View {
        VStack(spacing: 0) {
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
                        if isOnWiFi {
                            Label {
                                Text("Wi-Fi recommended")
                            } icon: {
                                Image(systemName: "wifi")
                            }
                        } else {
                            // Colour on the icon only: orange caption text
                            // fails contrast in light mode.
                            Label {
                                if wifiOnlyDownloads {
                                    Text("You're not on Wi-Fi. This is a large download - it will wait until you are, unless you turn that off in Settings.")
                                } else {
                                    Text("You're not on Wi-Fi. This large download will use mobile data.")
                                }
                            } icon: {
                                Image(systemName: "wifi.slash")
                                    .foregroundStyle(.orange)
                            }
                            .fixedSize(horizontal: false, vertical: true)
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
                        if let freeBytes {
                            Label {
                                Text(L10n.text("\(Self.formatted(freeBytes)) free on this iPhone"))
                            } icon: {
                                Image(systemName: "internaldrive")
                            }
                            if lacksSpace {
                                Label {
                                    Text(L10n.text("Free up about \(Self.formatted(neededBytes - freeBytes)) first."))
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(.subheadline)
                    .padding(.horizontal)
                }
                .padding(.top, 24)
                .frame(maxWidth: 500)
                .frame(maxWidth: .infinity)
            }
            // No rubber-band when everything fits, so a scroll that does
            // happen (accessibility sizes) reads as "there is more".
            .scrollBounceBehavior(.basedOnSize)

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
                // Agreeing to a download that the loader then refuses for
                // lack of space only produced a failure banner.
                .disabled(lacksSpace)

                Button(action: onCancel) {
                    // The frame lives inside the label: applied to the
                    // button it only moves layout, not the tappable area.
                    Text("Not Now")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
            .frame(maxWidth: 500)
        }
        // The system's grabber, not a drawn one: this sheet is a bottom
        // sheet on a phone, but a centered form on a wide window and a
        // full-height one in landscape, where a painted capsule would lie.
        .presentationDragIndicator(.visible)
        .onAppear {
            measureSpace()
            startWatchingNetwork()
        }
        .onDisappear {
            monitor?.cancel()
            monitor = nil
        }
    }

    private static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }

    private func measureSpace() {
        // A resumed download needs only what is still missing.
        let have = model.backend == .mlx ? ModelManager.shared.downloadedSizeBytes(for: model) : 0
        neededBytes = max(model.sizeBytes - have, 0) + 300_000_000
        freeBytes = try? URL.documentsDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// Same pattern as SetupView's.
    private func startWatchingNetwork() {
        // onAppear can fire more than once; a second monitor would leak the
        // first along with its queue and callback.
        monitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in
                isOnWiFi = !path.isExpensive && path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "aig.consent.network"))
        self.monitor = monitor
        // Seed from the current path, with the same test as the handler, so
        // "no network at all" doesn't render as "on Wi-Fi".
        let path = monitor.currentPath
        isOnWiFi = !path.isExpensive && path.status == .satisfied
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
    /// The model is still being downloaded or loaded; the status chip
    /// explains that wait, so no "reading the conversation" caption.
    var modelIsLoading = false

    @State private var animating = false
    /// 0 at first, 1 after 4 s, 2 after 15 s without a first token.
    @State private var waitStage = 0
    /// An infinite repeating animation is exactly what Reduce Motion asks
    /// apps not to do.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Rebuilding a session for a long chat on a 2B vision model takes tens
    /// of seconds before the first token, and three dots alone for that long
    /// read as a hang.
    private var caption: LocalizedStringKey? {
        guard !modelIsLoading else { return nil }
        switch waitStage {
        case 1: return "Reading the conversation..."
        case 2: return "Long conversations take a while to start"
        default: return nil
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
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

                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
        .onAppear { animating = true }
        // Restarted when loading ends: the wait that matters is the one
        // after the model is ready.
        .task(id: modelIsLoading) {
            waitStage = 0
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            waitStage = 1
            try? await Task.sleep(for: .seconds(11))
            guard !Task.isCancelled else { return }
            waitStage = 2
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.map { Text($0) } ?? Text("Assistant is thinking"))
    }
}

#Preview {
    let appState = AppState()
    return ChatView(viewModel: appState.chatViewModel)
        .environmentObject(appState)
}
