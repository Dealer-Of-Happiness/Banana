//
//  ImageAnalysisService.swift
//  DOH AI
//
//  Image analysis using Llama 3.2 vision capabilities
//

import Foundation
import UIKit
import Vision
import Combine

actor ImageAnalysisService {

    // MARK: - Analyze Image

    func analyzeImage(_ image: UIImage, prompt: String? = nil) async throws -> ImageAnalysis {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw ImageError.invalidImage
        }

        // Resize for efficient processing
        let resizedImage = resizeImage(image, maxDimension: 1024)
        guard let resizedData = resizedImage.jpegData(compressionQuality: 0.8) else {
            throw ImageError.invalidImage
        }

        // Perform OCR
        let extractedText = try await performOCR(on: image)

        // In production, send to Llama 3.2 vision model for analysis
        // For now, use Vision framework for basic analysis

        let objects = try await detectObjects(in: image)
        let description = generateDescription(objects: objects, text: extractedText)

        return ImageAnalysis(
            description: description,
            extractedText: extractedText,
            detectedObjects: objects,
            imageData: resizedData
        )
    }

    // MARK: - OCR

    private func performOCR(on image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw ImageError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")

                continuation.resume(returning: text)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Object Detection

    private func detectObjects(in image: UIImage) async throws -> [String] {
        guard let cgImage = image.cgImage else {
            throw ImageError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNClassifyImageRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNClassificationObservation] ?? []
                let objects = observations
                    .filter { $0.confidence > 0.3 }
                    .prefix(10)
                    .map { $0.identifier }

                continuation.resume(returning: Array(objects))
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Helpers

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let ratio = min(maxDimension / size.width, maxDimension / size.height)

        if ratio >= 1 { return image }

        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return resized ?? image
    }

    private func generateDescription(objects: [String], text: String) -> String {
        var description = "I can see "

        if !objects.isEmpty {
            let topObjects = objects.prefix(5).joined(separator: ", ")
            description += "what appears to be: \(topObjects). "
        }

        if !text.isEmpty {
            description += "There is text visible in the image. "
        }

        if objects.isEmpty && text.isEmpty {
            description = "I've analyzed the image but couldn't identify specific objects or text."
        }

        return description
    }
}

// MARK: - Image Analysis Result

struct ImageAnalysis {
    let description: String
    let extractedText: String
    let detectedObjects: [String]
    let imageData: Data
}

// MARK: - Errors

enum ImageError: LocalizedError {
    case invalidImage
    case analysisFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Invalid image"
        case .analysisFailed(let reason):
            return "Analysis failed: \(reason)"
        }
    }
}
