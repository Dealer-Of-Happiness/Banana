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

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    /// Pages read from one scan. Beyond this the OCR pass takes longer than
    /// anyone will wait; the user is told when pages are left out.
    static let maximumPages = 30

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onFinish: (VNDocumentCameraScan) -> Void
        private let onCancel: () -> Void
        /// Guards against the delegate firing twice (cancel after finish).
        private var didReport = false

        init(onFinish: @escaping (VNDocumentCameraScan) -> Void, onCancel: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
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
            onCancel()
        }
    }
}
