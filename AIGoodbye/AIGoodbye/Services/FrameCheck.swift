//
//  FrameCheck.swift
//  AIGoodbye
//
//  Whether a camera frame shows anything at all, before a vision model is
//  asked to describe it.
//

import UIKit

nonisolated enum FrameCheck {

    struct Stats: Equatable {
        /// Average brightness, 0 (black) to 1 (white).
        var mean: Double
        /// How much the brightness varies across the picture.
        var deviation: Double
    }

    /// Brightness of the frame, measured on a 32 x 32 grey thumbnail.
    static func stats(of image: UIImage) -> Stats? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let values = pixels.map { Double($0) / 255 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return Stats(mean: mean, deviation: variance.squareRoot())
    }

    /// Too dark or too featureless to describe: a covered lens, a pocket,
    /// a pitch-dark room. A small vision model shown such a frame does not
    /// say it sees nothing - with the lens taped over it described "the
    /// person standing directly in front of you" in a white shirt and blue
    /// jeans, different clothes each time. A plain bright wall is not
    /// flagged: that is something real to describe.
    static func showsNothing(_ stats: Stats) -> Bool {
        stats.mean < 0.06 || (stats.mean < 0.25 && stats.deviation < 0.035)
    }

    static func showsNothing(_ image: UIImage) -> Bool {
        stats(of: image).map(showsNothing) ?? false
    }
}
