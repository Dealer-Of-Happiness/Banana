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
    @State private var isCapturing = false
    /// The still being reviewed before it is used.
    @State private var captured: UIImage?
    @State private var captureFailed = false

    var body: some View {
        NavigationStack {
            stage
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
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.retry() } else { camera.stop() }
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
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if captured != nil {
                Button("Retake", systemImage: "arrow.counterclockwise") {
                    captured = nil
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(.ultraThinMaterial, in: Capsule())
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
        .disabled(!camera.isReady || isCapturing)
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
