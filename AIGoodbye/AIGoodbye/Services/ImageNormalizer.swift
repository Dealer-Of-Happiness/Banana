//
//  ImageNormalizer.swift
//  AIGoodbye
//
//  Every image that reaches a model, Vision, or the disk goes through here
//  first.
//
//  `UIImage.cgImage` is the raw sensor bitmap and throws away
//  `imageOrientation`. A photo taken in portrait on an iPhone carries
//  `.right`, so handing its `cgImage` straight to a vision model feeds the
//  model a picture rotated 90 degrees - while SwiftUI renders the same
//  UIImage upright on screen, so the user sees a correct photo and an
//  inexplicably confused answer.
//

import UIKit
import CoreImage

enum ImageNormalizer {

    /// A `UIImage` whose pixels are already in the orientation people see,
    /// so `.cgImage` is safe to use downstream. Returns the original when it
    /// is already upright.
    static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// A `CIImage` in the orientation people see, without re-rendering the
    /// bitmap - Core Image applies the transform lazily, so this is the cheap
    /// path for the model.
    static func orientedCIImage(from image: UIImage) -> CIImage? {
        if let ciImage = image.ciImage {
            return ciImage.oriented(cgOrientation(image.imageOrientation))
        }
        guard let cgImage = image.cgImage else { return nil }
        return CIImage(cgImage: cgImage).oriented(cgOrientation(image.imageOrientation))
    }

    /// The Core Graphics orientation matching a UIKit one. Vision and Core
    /// Image both speak this dialect; UIKit speaks its own.
    static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
