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
import AVFoundation
import UIKit
import Combine

// MARK: - Camera controller

/// Thread-safe holder for the newest camera frame (written from the capture
/// queue, read from the main actor).
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: UIImage?

    func set(_ image: UIImage) {
        lock.lock(); frame = image; lock.unlock()
    }

    func get() -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return frame
    }
}

@MainActor
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published private(set) var isReady = false
    @Published private(set) var failed = false

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "aig.camera.frames")
    private let frameStore = FrameStore()
    private var configureTask: Task<Void, Never>?
    /// Inputs/outputs are wired once; restarts only need startRunning().
    private var isConfigured = false

    func start() {
        guard configureTask == nil, !isReady, !failed else { return }
        configureTask = Task { [weak self] in
            await self?.configureAndRun()
            await MainActor.run { self?.configureTask = nil }
        }
    }

    private func configureAndRun() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
            failed = true
            return
        }
        // The user may have closed the screen while the permission alert or
        // configuration was pending: never light up the camera afterwards.
        guard !Task.isCancelled else { return }

        let session = self.session
        let videoOutput = self.videoOutput
        let delegate = self
        let queue = sampleQueue

        // Returning from the background: inputs/outputs are already wired,
        // so just start the session again.
        if isConfigured {
            await Task.detached { session.startRunning() }.value
            guard !Task.isCancelled else {
                await Task.detached { session.stopRunning() }.value
                return
            }
            isReady = true
            return
        }

        let ok = await Task.detached { () -> Bool in
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
        }.value

        guard ok else {
            failed = true
            return
        }
        isConfigured = true
        guard !Task.isCancelled else { return }

        await Task.detached { session.startRunning() }.value
        guard !Task.isCancelled else {
            await Task.detached { session.stopRunning() }.value
            return
        }
        isReady = true
    }

    func stop() {
        configureTask?.cancel()
        configureTask = nil
        isReady = false
        let session = self.session
        Task.detached {
            if session.isRunning { session.stopRunning() }
        }
    }

    /// The most recent camera frame as an image, downscaled for the model.
    func snapshot() -> UIImage? {
        frameStore.get()
    }

    fileprivate nonisolated var frames: FrameStore { frameStore }
}

/// One shared Core Image context (creating one per frame is expensive).
private nonisolated(unsafe) let sharedCIContext = CIContext(options: nil)
/// Last time a frame was converted, so we don't render 30 images a second
/// while the vision model wants the GPU (and the battery).
private nonisolated(unsafe) var lastFrameConversion = Date.distantPast
private let frameConversionLock = NSLock()

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Only one frame every 400 ms is ever needed: a question uses the
        // single latest snapshot.
        frameConversionLock.lock()
        let now = Date()
        let due = now.timeIntervalSince(lastFrameConversion) >= 0.4
        if due { lastFrameConversion = now }
        frameConversionLock.unlock()
        guard due else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // Downscale to ~768 on the long edge for the vision encoder.
        let scale = 768 / max(ciImage.extent.width, ciImage.extent.height)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = sharedCIContext.createCGImage(scaled, from: scaled.extent) else { return }
        frames.set(UIImage(cgImage: cgImage))
    }
}

// MARK: - Preview layer

private struct CameraPreview: UIViewRepresentable {
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
                let model = try engine.route(hasImage: true)
                // Camera Q&A must never leak into (or erase) the chat
                // session - clean up on EVERY exit path, including errors.
                defer { engine.resetSessions() }
                try await engine.startConversation(model: model, history: [])

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
        guard speakAnswers else { return }
        let start = text.index(text.startIndex, offsetBy: min(spokenOffset, text.count))
        guard let range = SpeechChunker.speakableSlice(of: text, from: start) else { return }
        let slice = String(text[range])
        spokenOffset += slice.count
        voice.speak(slice)
    }

    private func speakRemainder(of text: String) {
        let start = text.index(text.startIndex, offsetBy: min(spokenOffset, text.count))
        let remainder = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        spokenOffset = text.count
        if !remainder.isEmpty { voice.speak(remainder) }
    }
}
