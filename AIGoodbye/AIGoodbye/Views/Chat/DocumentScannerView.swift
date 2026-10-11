//
//  DocumentScannerView.swift
//  AIGoodbye
//
//  Apple's document camera: edge detection, perspective correction and
//  multi-page capture. The pages never leave the device - they are read by
//  Vision's on-device OCR and then discarded, keeping only the text.
//

import SwiftUI
import VisionKit
import UIKit

struct DocumentScannerView: UIViewControllerRepresentable {
    /// The scan is handed over whole and read one page at a time by the
    /// caller.
    ///
    /// It used to be decoded, downscaled, re-encoded and written to disk
    /// right here, inside a main-thread delegate callback - thirty pages of
    /// that froze the app for tens of seconds with no indication of progress,
    /// and staged thirty copies of someone's private document in a temporary
    /// directory on the way.
    let onFinish: (VNDocumentCameraScan) -> Void
    let onCancel: () -> Void
    /// The scanner could not run (camera unavailable, in use elsewhere).
    /// Reported separately from a cancel, which is silent by design: the
    /// user tapped Cancel and knows why the cover closed. A failure used to
    /// take the same path, so the cover simply vanished and the user had no
    /// way to tell a broken scanner from their own tap. The caller still
    /// has to close the cover; this only says why. Optional so the older
    /// two-closure call site keeps compiling; without it a failure falls
    /// back to `onCancel`.
    var onFail: ((Error) -> Void)? = nil

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    /// Pages read from one scan. Beyond this the OCR pass takes longer than
    /// anyone will wait; the user is told when pages are left out.
    static let maximumPages = 30

    /// What to tell the user when `onFail` fires.
    static func failureMessage(for error: Error) -> String {
        L10n.text("The scanner couldn't start: \(error.localizedDescription)")
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel, onFail: onFail)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onFinish: (VNDocumentCameraScan) -> Void
        private let onCancel: () -> Void
        private let onFail: ((Error) -> Void)?
        /// Guards against the delegate firing twice (cancel after finish).
        private var didReport = false

        init(onFinish: @escaping (VNDocumentCameraScan) -> Void,
             onCancel: @escaping () -> Void,
             onFail: ((Error) -> Void)?) {
            self.onFinish = onFinish
            self.onCancel = onCancel
            self.onFail = onFail
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            guard !didReport else { return }
            didReport = true
            onFinish(scan)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            guard !didReport else { return }
            didReport = true
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            guard !didReport else { return }
            didReport = true
            if let onFail {
                onFail(error)
            } else {
                onCancel()
            }
        }
    }
}
