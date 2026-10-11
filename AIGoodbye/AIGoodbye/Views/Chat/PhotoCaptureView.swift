//
//  PhotoCaptureView.swift
//  AIGoodbye
//
//  Take a photo to ask about. Built on the same capture controller as Live
//  Camera rather than `UIImagePickerController`, which is portrait-only on
//  iPhone and knows nothing of iPhone Duo: it cannot follow the window as
//  the device turns or folds, and it cannot choose the camera facing the
//  user when there are two front cameras on two displays.
//

import SwiftUI
import AVFoundation

struct PhotoCaptureView: View {
    let onImageCaptured: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var camera = CameraController()
    /// The camera must not come back on behind the Face ID lock screen
    /// when the biometric prompt is cancelled; see LiveCameraView.
    @ObservedObject private var lock = AppLock.shared
    @State private var isCapturing = false
    /// The still being reviewed before it is used.
    @State private var captured: UIImage?
    @State private var captureFailed = false

    var body: some View {
        NavigationStack {
            stage
                // Dark throughout, like the navigation bar. The materials
                // and labels below otherwise followed the device's light
                // scheme: a light grey pill under white text over a bright
                // scene, well under 3:1.
                .environment(\.colorScheme, .dark)
                .background(Color.black.ignoresSafeArea())
            .navigationTitle("Take Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        dismiss()
                    }
                    .accessibilityLabel(Text("Cancel taking a photo"))
                }
                if captured == nil {
                    ToolbarItem(placement: .primaryAction) {
                        // By direction, not by a fixed camera: on iPhone Duo
                        // "the camera facing me" is a different piece of
                        // hardware depending on which display is in use.
                        Button("Flip Camera", systemImage: "arrow.triangle.2.circlepath.camera") {
                            camera.setPosition(camera.position == .back ? .front : .back)
                        }
                        .disabled(!camera.isReady || camera.isSwitchingCamera)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Use Photo", systemImage: "checkmark") {
                            if let captured { onImageCaptured(captured) }
                        }
                    }
                }
            }
            .alert("Couldn't take the photo", isPresented: $captureFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please try again.")
            }
        }
        .onAppear {
            // Under the lock screen (a deep link while locked) the lock
            // observer below starts the camera once it clears.
            if !lock.isLocked { camera.start() }
        }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                guard !lock.isLocked else { return }
                camera.resume()
            case .inactive:
                // Control Center, a banner, a system alert: the viewfinder
                // is still on screen, so the camera stays on. Stopping it
                // here meant a black viewfinder for a second on every swipe.
                break
            case .background:
                camera.stop()
            @unknown default:
                break
            }
        }
        .onChange(of: lock.isLocked) { _, locked in
            guard !locked, scenePhase != .background else { return }
            camera.resume()
        }
    }

    /// The picture with the shutter over it - or, on an iPhone Duo folded
    /// half open, the picture in one half and the shutter in the other.
    @ViewBuilder
    private var stage: some View {
        if #available(iOS 27.1, *) {
            ArrangementView {
                controls
            } secondary: {
                picture
            }
            .arrangementViewStyle(.overlay)
        } else {
            ZStack {
                picture
                controls
            }
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let captured {
            Image(uiImage: captured)
                .resizable()
                .scaledToFit()
                .ignoresSafeArea()
                .accessibilityLabel(Text("The photo you just took"))
        } else if camera.failed {
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
                .accessibilityHidden(true)
        }
    }

    /// The shutter along the bottom edge, or the trailing edge when the
    /// window is short, where a bottom row would cover the picture.
    @ViewBuilder
    private var controls: some View {
        let compact = verticalSizeClass == .compact
        let stack = Group {
            if let interruption = camera.interruption {
                Label(interruption, systemImage: "video.slash")
                    .font(.footnote)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if captured != nil {
                Button {
                    captured = nil
                } label: {
                    // Size and shape INSIDE the label: a button's hit area
                    // is its label, so a frame on the Button only moved
                    // the pixels and left the target the height of a line
                    // of text.
                    Label("Retake", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(.ultraThinMaterial, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                shutter
            }
        }

        if compact {
            HStack {
                Spacer()
                VStack(spacing: 16) { stack }
                    .padding(.trailing, 20)
            }
        } else {
            VStack {
                Spacer()
                VStack(spacing: 16) { stack }
                    .padding(.bottom, 24)
            }
        }
    }

    private var shutter: some View {
        Button {
            takePhoto()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                Circle()
                    .fill(.white)
                    .frame(width: 60, height: 60)
                if isCapturing {
                    ProgressView()
                        .tint(.black)
                }
            }
        }
        .buttonStyle(.plain)
        // Off during a flip too: `capturePhoto` returns nil while the
        // cameras swap, which came back as "Couldn't take the photo" for a
        // tap that simply landed half a second early.
        .disabled(!camera.isReady || isCapturing || camera.isSwitchingCamera)
        .accessibilityLabel(Text("Take photo"))
    }

    private func takePhoto() {
        guard !isCapturing else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            if let image = await camera.capturePhoto() {
                captured = image
            } else {
                captureFailed = true
            }
        }
    }
}
