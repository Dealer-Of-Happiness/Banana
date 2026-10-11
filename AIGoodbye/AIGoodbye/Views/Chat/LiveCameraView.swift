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
    /// Why the viewfinder is black although nothing is wrong with the
    /// camera: another app has it, or this app is sharing the display and
    /// the system paused capture. Nil when running normally.
    @Published private(set) var interruption: String?
    /// Which way the current camera faces. On iPhone Duo there are two
    /// front cameras on two displays, so "front" is a direction the app
    /// asks for, not a fixed piece of hardware.
    @Published private(set) var position: AVCaptureDevice.Position = .back

    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
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
    private var currentInput: AVCaptureDeviceInput?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    /// Keeps the camera's picture upright as the window turns.
    ///
    /// The rotation used to be set once, to portrait, when the session was
    /// built. That was right for a phone that only ever stood upright. A
    /// landscape phone, or an iPhone Duo turned on its side or folded into
    /// a stand, handed the vision model - and the viewfinder - a picture
    /// lying on its side; in Read-text mode the OCR then found no text.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservers: [NSKeyValueObservation] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var photoDelegates: [Int64: PhotoCaptureDelegate] = [:]

    override init() {
        super.init()
        observeInterruptions()
    }

    deinit {
        // Block observers stay registered until removed; dropping the
        // tokens alone leaked a block per camera screen opened.
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

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

    /// The preview layer showing this session, so its picture can be kept
    /// upright along with the frames.
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        if let device = currentInput?.device {
            installRotationCoordinator(for: device)
        }
    }

    /// Switch between the camera facing the user and the one facing away.
    /// Safe to call while running; a no-op when that camera doesn't exist.
    func setPosition(_ wanted: AVCaptureDevice.Position) {
        // One swap at a time. A second tap while the first was still in
        // flight removed an input that was already gone and could leave
        // the session with no camera at all.
        guard isConfigured, !isSwitchingCamera, wanted != position else { return }
        let session = self.session
        let photoOutput = self.photoOutput
        let previous = currentInput
        guard let device = Self.camera(facing: wanted),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        isSwitchingCamera = true
        // Bound to a local constant first: reaching for the capture-list
        // `self` from inside the nested Task is a reference to a captured
        // var from concurrent code.
        let controller = self
        Self.sessionQueue.async {
            session.beginConfiguration()
            if let previous { session.removeInput(previous) }
            if session.canAddInput(input) {
                session.addInput(input)
            } else if let previous, session.canAddInput(previous) {
                session.addInput(previous)
            }
            session.commitConfiguration()
            let installed = session.inputs.contains { $0 === input }
            if installed { Self.configureStills(photoOutput, for: device) }
            Task { @MainActor in
                controller.isSwitchingCamera = false
                guard installed else { return }
                controller.currentInput = input
                controller.position = wanted
                controller.installRotationCoordinator(for: device)
            }
        }
    }

    @Published private(set) var isSwitchingCamera = false

    /// Stills at the camera's full resolution. The session runs at 720p
    /// for the live frames, and without this the photo output inherited
    /// that: "Take Photo" was handing the model a 0.9-megapixel picture
    /// where the old system camera gave it twelve.
    nonisolated private static func configureStills(_ output: AVCapturePhotoOutput, for device: AVCaptureDevice) {
        guard let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }) else { return }
        output.maxPhotoDimensions = largest
    }

    /// The camera facing a direction. Looked up by direction every time,
    /// never cached: on iPhone Duo the camera facing the user depends on
    /// which display the app is on, and that changes as the phone folds.
    nonisolated private static func camera(facing position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
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
        let photoOutput = self.photoOutput
        let delegate = self
        let queue = sampleQueue
        let wantedPosition = position

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

        let configured: AVCaptureDeviceInput? = await Self.onSessionQueue { () -> AVCaptureDeviceInput? in
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            session.sessionPreset = .hd1280x720
            // Don't let the capture session stomp the audio session we use
            // for spoken answers.
            session.automaticallyConfiguresApplicationAudioSession = false
            // Keep capturing while another app shares the display (iPad
            // Split View, the inner display of iPhone Duo). Without this
            // the session is interrupted the moment a second app appears.
            if session.isMultitaskingCameraAccessSupported {
                session.isMultitaskingCameraAccessEnabled = true
            }

            guard let device = Self.camera(facing: wantedPosition),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                return nil
            }
            session.addInput(input)

            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(delegate, queue: queue)
            guard session.canAddOutput(videoOutput) else { return nil }
            session.addOutput(videoOutput)

            // Stills, for the "take a photo" path. Optional: a session that
            // can't add it still works for live questions.
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                Self.configureStills(photoOutput, for: device)
            }
            return input
        }

        guard let input = configured else {
            failed = true
            return
        }
        isConfigured = true
        currentInput = input
        installRotationCoordinator(for: input.device)
        guard !Task.isCancelled, epoch == attempt else { return }

        await Self.onSessionQueue { session.startRunning() }
        guard !Task.isCancelled, epoch == attempt else {
            if epoch == attempt { await Self.onSessionQueue { session.stopRunning() } }
            return
        }
        isReady = true
    }

    /// Follow the window's orientation for the preview, the frames and the
    /// stills, from one source of truth.
    private func installRotationCoordinator(for device: AVCaptureDevice) {
        rotationObservers.removeAll()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyRotation(
            preview: coordinator.videoRotationAngleForHorizonLevelPreview,
            capture: coordinator.videoRotationAngleForHorizonLevelCapture
        )
        weak let controller = self
        rotationObservers.append(coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in controller?.applyRotation(preview: angle, capture: nil) }
        })
        rotationObservers.append(coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            Task { @MainActor in controller?.applyRotation(preview: nil, capture: angle) }
        })
    }

    private func applyRotation(preview: CGFloat?, capture: CGFloat?) {
        if let preview, let connection = previewLayer?.connection,
           connection.isVideoRotationAngleSupported(preview) {
            connection.videoRotationAngle = preview
        }
        guard let capture else { return }
        let videoOutput = self.videoOutput
        let photoOutput = self.photoOutput
        Self.sessionQueue.async {
            for output in [videoOutput as AVCaptureOutput, photoOutput] {
                if let connection = output.connection(with: .video),
                   connection.isVideoRotationAngleSupported(capture) {
                    connection.videoRotationAngle = capture
                }
            }
        }
    }

    /// Say why the viewfinder went dark, and recover when the reason goes
    /// away. Silently, this looked like a camera that had died.
    private func observeInterruptions() {
        let center = NotificationCenter.default
        weak let controller = self
        notificationObservers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: .main
        ) { note in
            // A Notification is not Sendable: read the one value that
            // matters here, on the delivery queue, and only that crosses.
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            Task { @MainActor in controller?.handleInterruption(raw) }
        })
        notificationObservers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: .main
        ) { _ in
            Task { @MainActor in controller?.interruption = nil }
        })
    }

    private func handleInterruption(_ raw: Int?) {
        guard let raw, let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else {
            interruption = L10n.text("The camera was paused.")
            return
        }
        switch reason {
        case .videoDeviceInUseByAnotherClient:
            interruption = L10n.text("Another app is using the camera.")
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            interruption = L10n.text("The camera pauses while another app shares the screen.")
        case .videoDeviceNotAvailableDueToSystemPressure:
            interruption = L10n.text("The camera paused because the device is too hot or busy.")
        case .videoDeviceNotAvailableInBackground, .audioDeviceInUseByAnotherClient:
            interruption = nil
        case .sensitiveContentMitigationActivated:
            interruption = L10n.text("The camera was paused by a system privacy setting.")
        @unknown default:
            interruption = L10n.text("The camera was paused.")
        }
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

    /// A full-resolution still, upright, or nil if the camera isn't ready.
    func capturePhoto() async -> UIImage? {
        guard isReady, !isSwitchingCamera,
              session.outputs.contains(where: { $0 === photoOutput }),
              photoOutput.connection(with: .video) != nil else { return nil }
        let settings = AVCapturePhotoSettings()
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        let photoOutput = self.photoOutput
        weak let controller = self
        let id = settings.uniqueID
        return await withCheckedContinuation { continuation in
            let delegate = PhotoCaptureDelegate { image in
                Task { @MainActor in
                    controller?.photoDelegates[id] = nil
                    continuation.resume(returning: image)
                }
            }
            photoDelegates[id] = delegate
            Self.sessionQueue.async {
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    fileprivate nonisolated var frames: FrameStore { frameStore }
}

/// Receives one still and hands back an upright `UIImage`, exactly once.
///
/// The image arrives in `didFinishProcessingPhoto`, but the callback the
/// framework guarantees for every capture - including ones that never
/// produce a photo - is `didFinishCaptureFor`. Completing there, once,
/// means a failed capture can't leave the caller waiting forever with
/// its shutter disabled.
private nonisolated final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (UIImage?) -> Void
    private let lock = NSLock()
    private var image: UIImage?
    private var completed = false

    init(completion: @escaping @Sendable (UIImage?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let decoded = UIImage(data: data) else { return }
        // Rotation is applied on the connection, so the pixels are already
        // upright for the window; any remaining EXIF orientation is baked
        // in so every consumer sees the picture the user saw.
        let upright = ImageNormalizer.upright(decoded)
        lock.lock(); image = upright; lock.unlock()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let result = error == nil ? image : nil
        lock.unlock()
        completion(result)
    }
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
    @ObservedObject var camera: CameraController

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        // Fit, not fill. Fill cropped a wide frame to a near-square window
        // (an iPhone Duo open, a landscape phone), and the model then
        // answered about things outside the picture the user was looking
        // at. The layer is the view's own backing layer, so it follows every
        // resize by itself; only its rotation needs managing, which the
        // controller does.
        view.previewLayer.videoGravity = .resizeAspect
        camera.attachPreview(view.previewLayer)
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        NavigationStack {
            stage
                .background(Color.black.ignoresSafeArea())
            .navigationTitle("Live Camera")
            .navigationSubtitle("Ask about what you see · 100% on-device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        dismiss()
                    }
                    .accessibilityLabel(Text("Close live camera"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(
                        speakAnswers ? "Mute Answers" : "Speak Answers",
                        systemImage: speakAnswers ? "speaker.wave.2.fill" : "speaker.slash.fill"
                    ) {
                        speakAnswers.toggle()
                        if !speakAnswers { voice.stopSpeaking() }
                    }
                    .accessibilityLabel(Text(speakAnswers ? "Turn off spoken answers" : "Turn on spoken answers"))
                }
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
                // `retry`, not `start`: a camera another app had latched
                // `failed`, and `start` refuses to run while it is set.
                camera.retry()
            } else {
                generationTask?.cancel()
                camera.stop()
                voice.stopSpeaking()
            }
        }
    }

    // MARK: - Pieces

    /// The viewfinder with the answer and question over it - or, on an
    /// iPhone Duo folded half open like a laptop, the viewfinder in the
    /// upper half and the answer and question in the lower half, where
    /// the fold would otherwise run straight through the text.
    @ViewBuilder
    private var stage: some View {
        if #available(iOS 27.1, *) {
            ArrangementView {
                overlayControls
            } secondary: {
                viewfinder
            }
            .arrangementViewStyle(.overlay)
        } else {
            ZStack {
                viewfinder
                overlayControls
            }
        }
    }

    @ViewBuilder
    private var viewfinder: some View {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CameraPreview(camera: camera)
                .ignoresSafeArea()
        }
    }

    private var overlayControls: some View {
        VStack {
            Spacer()
            answerPanel
            inputBar
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var answerPanel: some View {
        if let interruption = camera.interruption {
            Label(interruption, systemImage: "video.slash")
                .font(.subheadline)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
        }
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
            // Shorter when the window is: at 240 pt the answer covered
            // the whole viewfinder on a landscape phone.
            .frame(maxHeight: verticalSizeClass == .compact ? 120 : 240)
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
