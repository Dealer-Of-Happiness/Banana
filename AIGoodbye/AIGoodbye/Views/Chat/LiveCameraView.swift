//
//  LiveCameraView.swift
//  AIGoodbye
//
//  Live camera mode: point the camera at anything and ask about it.
//  Each question snapshots the current frame and runs it through the
//  on-device vision model. Answers can be spoken aloud. Nothing leaves
//  the device.
//

import SwiftUI
// `@preconcurrency`: `AVCaptureSession` is not `Sendable`, but every touch of
// it here is funnelled through one serial queue (`sessionQueue`), which is
// the guarantee the annotation would be asking for.
@preconcurrency import AVFoundation
import UIKit
import Combine

// MARK: - Camera controller

/// Thread-safe holder for the newest camera frame (written from the capture
/// queue, read from the main actor).
/// Deliberately `nonisolated`: everything here is called from `captureOutput`
/// on the capture queue, and the lock - not an actor - is what makes it safe.
nonisolated final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: (image: UIImage, at: Date)?
    private var lastAccepted = Date.distantPast

    /// One shared Core Image context; building one per frame is expensive.
    private let context = CIContext(options: nil)

    func set(_ image: UIImage) {
        lock.lock(); frame = (image, Date()); lock.unlock()
    }

    /// The newest frame, if it is recent enough to still describe the world.
    ///
    /// Age matters. The capture session takes a moment to restart after the
    /// app returns from the background, and the stored frame is whatever was
    /// in view before the interruption - so without this the app would
    /// confidently describe a room the user has already walked out of, which
    /// for someone navigating by these descriptions is worse than silence.
    func get(maxAge: TimeInterval = 2.0) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        guard let frame, Date().timeIntervalSince(frame.at) <= maxAge else { return nil }
        return frame.image
    }

    func clear() {
        lock.lock(); frame = nil; lastAccepted = .distantPast; lock.unlock()
    }

    /// True at most once every 400 ms.
    ///
    /// A question only ever uses the single latest snapshot, so converting
    /// thirty frames a second would just heat the phone and take the GPU away
    /// from the vision model that is about to want it.
    func shouldAcceptFrame(at now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now.timeIntervalSince(lastAccepted) >= 0.4 else { return false }
        lastAccepted = now
        return true
    }

    func render(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent)
    }
}

@MainActor
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published private(set) var isReady = false
    @Published private(set) var failed = false

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "aig.camera.frames")
    /// Serializes start and stop against each other. Two detached tasks
    /// racing meant a fast background/foreground bounce could leave the
    /// session stopped while `isReady` was true - a black viewfinder and a
    /// snapshot that is nil forever.
    private static let sessionQueue = DispatchQueue(label: "aig.camera.session")
    private let frameStore = FrameStore()
    private var configureTask: Task<Void, Never>?
    /// Identifies the current start attempt. Bumped by every `stop()` and
    /// every `retry()`, so a superseded attempt can neither clear the live
    /// task nor stop a session a newer attempt has already started.
    private var epoch = 0
    /// Inputs/outputs are wired once; restarts only need startRunning().
    private var isConfigured = false

    func start() {
        guard configureTask == nil, !isReady, !failed else { return }
        epoch += 1
        let attempt = epoch
        configureTask = Task { [weak self] in
            await self?.configureAndRun(attempt: attempt)
            await MainActor.run {
                // Identity-checked: clearing unconditionally let a cancelled
                // attempt nil out a live one, after which a third `start()`
                // ran the configuration block a second time, `canAddOutput`
                // returned false, and the camera was dead until the screen
                // was reopened.
                guard let self, self.epoch == attempt else { return }
                self.configureTask = nil
            }
        }
    }

    /// Try again after a failure.
    ///
    /// `failed` used to be a one-way latch, so "the camera is busy" - another
    /// app, Control Center, a transient device error - left the screen dead
    /// permanently no matter what the user did.
    func retry() {
        guard !isReady else { return }
        configureTask?.cancel()
        configureTask = nil
        epoch += 1
        failed = false
        start()
    }

    private func configureAndRun(attempt: Int) async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        // The user may have closed the screen while the permission alert or
        // configuration was pending: never light up the camera afterwards,
        // and never latch `failed` on a turn nobody is waiting for.
        guard !Task.isCancelled, epoch == attempt else { return }
        guard granted else {
            failed = true
            return
        }

        let session = self.session
        let videoOutput = self.videoOutput
        let delegate = self
        let queue = sampleQueue

        // Returning from the background: inputs/outputs are already wired,
        // so just start the session again - reattaching the delegate, which
        // `stop()` detaches to break the output's strong hold on us.
        if isConfigured {
            videoOutput.setSampleBufferDelegate(delegate, queue: queue)
            await Self.onSessionQueue { session.startRunning() }
            // Epoch-checked, not just cancellation-checked: a stop cannot
            // interrupt `startRunning`, so without this a superseded attempt
            // resumed afterwards and stopped the session a newer attempt had
            // already started - a black viewfinder with `isReady` true.
            guard !Task.isCancelled, epoch == attempt else {
                if epoch == attempt { await Self.onSessionQueue { session.stopRunning() } }
                return
            }
            isReady = true
            return
        }

        let ok = await Self.onSessionQueue { () -> Bool in
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            session.sessionPreset = .hd1280x720
            // Don't let the capture session stomp the audio session we use
            // for spoken answers.
            session.automaticallyConfiguresApplicationAudioSession = false

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                return false
            }
            session.addInput(input)

            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(delegate, queue: queue)
            guard session.canAddOutput(videoOutput) else { return false }
            session.addOutput(videoOutput)

            if let connection = videoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90 // portrait
            }
            return true
        }

        guard ok else {
            failed = true
            return
        }
        isConfigured = true
        guard !Task.isCancelled, epoch == attempt else { return }

        await Self.onSessionQueue { session.startRunning() }
        guard !Task.isCancelled, epoch == attempt else {
            if epoch == attempt { await Self.onSessionQueue { session.stopRunning() } }
            return
        }
        isReady = true
    }

    /// Run `work` on the shared session queue, so starts and stops can never
    /// overtake one another.
    ///
    /// `AVCaptureSession` is not `Sendable`, but every use of it in this file
    /// goes through this one queue, which is exactly the guarantee `Sendable`
    /// would be asking for.
    private static func onSessionQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            sessionQueue.async { continuation.resume(returning: work()) }
        }
    }

    func stop() {
        configureTask?.cancel()
        configureTask = nil
        epoch += 1
        isReady = false
        // `AVCaptureVideoDataOutput` holds its delegate strongly, and the
        // delegate is this object, which owns the output: a cycle that
        // `deinit` can never break because `deinit` never runs. Detaching
        // here is the only place it can be broken, so every open of Live
        // Camera or Describe Surroundings no longer leaks a controller, a
        // capture session, a device input and a Core Image context.
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        // The last frame must go with the session. Keeping it meant the next
        // presentation described whatever was in view when this one closed.
        frameStore.clear()
        let session = self.session
        Self.sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    /// The most recent camera frame as an image, downscaled for the model.
    func snapshot() -> UIImage? {
        frameStore.get()
    }

    fileprivate nonisolated var frames: FrameStore { frameStore }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let store = frames
        guard store.shouldAcceptFrame() else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // Downscale to ~768 on the long edge for the vision encoder.
        let scale = 768 / max(ciImage.extent.width, ciImage.extent.height)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = store.render(scaled) else { return }
        store.set(UIImage(cgImage: cgImage))
    }
}

// MARK: - Preview layer

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - Live camera view

struct LiveCameraView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @StateObject private var camera = CameraController()
    @StateObject private var voice = VoiceService()
    @Environment(\.scenePhase) private var scenePhase

    @State private var question = ""
    @State private var answer: String?
    @State private var isAnswering = false
    @State private var notice: String?
    @State private var speakAnswers = true
    @State private var spokenOffset = 0
    @State private var generationTask: Task<Void, Never>?
    @FocusState private var questionFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.failed {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.7))
                    Text("The camera isn't available. Check camera permission in the Settings app.")
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
            }

            VStack {
                topBar
                Spacer()
                answerPanel
                inputBar
            }
        }
        .onAppear {
            camera.start()
            voice.setSpeechLanguage(appState.settings.appLanguage)
        }
        .onDisappear {
            generationTask?.cancel()
            camera.stop()
            voice.shutdown()
        }
        .onChange(of: scenePhase) { _, phase in
            // Never keep the camera or speaker running in the background -
            // and bring the viewfinder back when the user returns (onAppear
            // does not fire again while the cover stays presented).
            if phase == .active {
                camera.start()
            } else {
                generationTask?.cancel()
                camera.stop()
                voice.stopSpeaking()
            }
        }
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Live Camera")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Ask about what you see · 100% on-device")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()

            Button {
                speakAnswers.toggle()
                if !speakAnswers { voice.stopSpeaking() }
            } label: {
                Image(systemName: speakAnswers ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text(speakAnswers ? "Turn off spoken answers" : "Turn on spoken answers"))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("Close live camera"))
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var answerPanel: some View {
        if let notice {
            Text(notice)
                .font(.subheadline)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
        }
        if let answer, !answer.isEmpty {
            ScrollView {
                MarkdownText(content: answer)
                    .padding(12)
            }
            .frame(maxHeight: 240)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .defaultScrollAnchor(.bottom)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(L10n.text("Ask about what you see..."), text: $question)
                .textFieldStyle(.plain)
                .focused($questionFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .submitLabel(.send)
                .onSubmit { ask() }

            if isAnswering {
                Button {
                    generationTask?.cancel()
                    voice.stopSpeaking()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                        .foregroundStyle(.red)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(Text("Stop generating"))
            } else {
                Button {
                    ask()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(question.isEmpty ? .gray : .blue)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(question.isEmpty)
                .accessibilityLabel(Text("Ask about the current view"))
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    // MARK: - Ask flow

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnswering else { return }
        guard let frame = camera.snapshot() else {
            notice = L10n.text("No camera image yet. Give the camera a moment and try again.")
            return
        }

        question = ""
        questionFocused = false
        notice = nil
        answer = ""
        spokenOffset = 0
        voice.stopSpeaking()
        isAnswering = true

        let engine = appState.engine
        generationTask = Task {
            defer { isAnswering = false }
            do {
                let model = try engine.route(hasImage: true, requiresDownloaded: true)
                // Camera Q&A must never leak into (or erase) the chat
                // session - and must not be torn down by a summary or
                // translation running elsewhere, so it claims the engine
                // like every other one-shot mode.
                guard engine.claimUtility() else {
                    notice = L10n.text("The AI is busy with another task. Try again in a moment.")
                    return
                }
                defer { engine.releaseUtility() }
                try await engine.startCleanSession(model: model)

                var final = ""
                let stream = engine.respondStream(model: model, prompt: text, image: frame)
                for try await snapshot in stream {
                    if Task.isCancelled { break }
                    final = snapshot
                    answer = snapshot
                    speakNewSentences(in: snapshot)
                }
                if speakAnswers && !Task.isCancelled { speakRemainder(of: final) }
            } catch let error as ChatEngine.RouteError {
                notice = routeNotice(for: error)
            } catch is CancellationError {
                // stopped by user
            } catch {
                if !Task.isCancelled {
                    notice = error.localizedDescription
                }
            }
        }
    }

    private func routeNotice(for error: ChatEngine.RouteError) -> String {
        switch error {
        case .needsDownloadConsent(let model), .visionNeedsDownloadedModel(let model):
            return L10n.text("Live camera needs the \(model.name) vision model. Download it from the chat screen first.")
        case .nothingAvailable(let reason):
            return reason
        }
    }

    private func speakNewSentences(in text: String) {
        let start = text.index(text.startIndex, offsetBy: min(spokenOffset, text.count))
        guard let range = SpeechChunker.speakableSlice(of: text, from: start) else { return }
        let slice = String(text[range])
        // The offset advances even while muted. Returning early left it
        // behind, so unmuting halfway through an answer replayed the whole
        // thing from the first word.
        spokenOffset += slice.count
        guard speakAnswers else { return }
        voice.speak(slice)
    }

    private func speakRemainder(of text: String) {
        let start = text.index(text.startIndex, offsetBy: min(spokenOffset, text.count))
        let remainder = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        spokenOffset = text.count
        if !remainder.isEmpty { voice.speak(remainder) }
    }
}
