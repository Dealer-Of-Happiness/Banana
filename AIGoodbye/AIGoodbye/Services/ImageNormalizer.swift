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
    /// Safe off the main thread: a renderer and a draw, nothing shared.
    /// It is called from the camera's photo callback, which arrives on a
    /// capture queue.
    nonisolated static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// The form in which a picture is kept, shown and sent: upright, scale 1,
    /// and no longer than `maxEdge` pixels on its long side. Every image the
    /// user attaches goes through here - the camera still, the Photos pick,
    /// the share-sheet file - before it becomes `pendingImage`.
    ///
    /// Nothing downstream wants more. The vision models see at most 768 px
    /// (`AIModel.imageProcessingEdge`), the bubble is 250 pt wide and the
    /// JPEG on disk is only ever read back for those two. Keeping a 12 MP
    /// still instead meant ~50 MB per photo in the image cache, a 3-5 MB
    /// file, and a full-size decode for every bubble that scrolled into
    /// view - which, next to a resident multi-gigabyte model, is how a
    /// chat with three photos in it got the app killed.
    ///
    /// One pass: `draw(in:)` applies the orientation while it scales, so an
    /// oriented 12 MP photo costs one decode and one small bitmap, not a
    /// full-size upright copy followed by a second render.
    /// Safe off the main thread, like `upright`; the camera calls it from
    /// its capture queue.
    nonisolated static func attachment(_ image: UIImage, maxEdge: CGFloat = 1536) -> UIImage {
        // `size` is already the upright size: UIKit swaps width and height
        // for the rotated orientations.
        let pixels = CGSize(width: image.size.width * image.scale,
                            height: image.size.height * image.scale)
        let longest = max(pixels.width, pixels.height)
        guard longest > 0 else { return image }
        let needsResize = longest > maxEdge
        // Already upright, 1x and small enough: nothing to redraw.
        guard needsResize || image.scale != 1 || image.imageOrientation != .up else { return image }
        let factor = needsResize ? maxEdge / longest : 1
        let target = CGSize(width: max(1, (pixels.width * factor).rounded()),
                            height: max(1, (pixels.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        // Pixels, not points. The default scale is the screen's, which
        // turned a "1024 px" cap into a 3072 px bitmap on a 3x phone.
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
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
