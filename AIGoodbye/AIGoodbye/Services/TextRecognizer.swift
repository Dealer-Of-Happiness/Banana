//
//  TextRecognizer.swift
//  AIGoodbye
//
//  On-device OCR. Turns scanned pages, photos of documents and image-only
//  PDFs into text the AI can actually read - using Apple's Vision framework,
//  which runs entirely on the device with no network access.
//

import Foundation
import Vision
import UIKit
import PDFKit

enum TextRecognizer {

    /// Pages OCR'd from a single PDF. Each page is a full-resolution render,
    /// so this is capped to keep a 300-page scan from taking all afternoon.
    static let maximumPDFPages = 40

    /// Recognition languages to try, most specific first. Kept short: Vision
    /// gets slower and less accurate the more languages it has to consider.
    static func languages(for appLanguage: AppLanguage) -> [Locale.Language] {
        var codes: [String] = []
        switch appLanguage {
        case .automatic:
            codes = Array(Locale.preferredLanguages.prefix(2))
        case .mandarin:
            codes = ["zh-Hans"]
        case .cantonese:
            codes = ["zh-Hant"]
        default:
            codes = [appLanguage.rawValue]
        }
        codes.append("en-US")
        var seen = Set<String>()
        return codes.prefix(3).compactMap { code in
            let normalized = code.replacingOccurrences(of: "_", with: "-")
            guard seen.insert(normalized).inserted else { return nil }
            return Locale.Language(identifier: normalized)
        }
    }

    // MARK: - Images

    /// Longest edge fed to Vision. Full 12 MP scans are far more pixels than
    /// text recognition needs, and holding several of them is what makes an
    /// app with a multi-gigabyte model resident get killed.
    static let maximumPixels: CGFloat = 2400

    /// Recognize text in one image. Returns "" when there is nothing to read.
    static func text(in image: UIImage, languages: [Locale.Language]) async -> String {
        // Upright first: Vision reads a rotated bitmap as gibberish, and
        // `downscaled` redraws the image so orientation must be settled
        // before that happens.
        let upright = ImageNormalizer.upright(image)
        guard let cgImage = downscaled(upright)?.cgImage ?? upright.cgImage else { return "" }
        return await text(in: cgImage, languages: languages)
    }

    static func text(in cgImage: CGImage, languages: [Locale.Language]) async -> String {
        if let text = try? await recognize(cgImage, languages: languages) {
            return text
        }
        // Vision throws for a language it doesn't support (Greek, among
        // others). Rather than silently returning nothing, read it as
        // English - Latin script still comes through.
        if let fallback = try? await recognize(cgImage, languages: [Locale.Language(identifier: "en-US")]) {
            return fallback
        }
        return ""
    }

    private static func recognize(_ cgImage: CGImage, languages: [Locale.Language]) async throws -> String {
        // Structure first. `RecognizeDocumentsRequest` returns paragraphs in
        // reading order and decomposes tables into cells, so a two-column
        // page or an invoice comes out readable instead of interleaved.
        // `RecognizeTextRequest` returns a bag of lines, which is why the
        // plain-OCR version of this scrambled multi-column documents.
        if let structured = try? await recognizeDocument(cgImage, languages: languages),
           !structured.isEmpty {
            return structured
        }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        let observations = try await request.perform(on: cgImage)
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// Reading-ordered text plus any tables rendered as Markdown.
    private static func recognizeDocument(
        _ cgImage: CGImage, languages: [Locale.Language]
    ) async throws -> String {
        var request = RecognizeDocumentsRequest()
        var textOptions = request.textRecognitionOptions
        textOptions.recognitionLanguages = languages
        request.textRecognitionOptions = textOptions

        let observations = try await request.perform(on: cgImage)
        var parts: [String] = []

        for observation in observations {
            let container = observation.document

            let transcript = container.text.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty { parts.append(transcript) }

            for table in container.tables {
                if let markdown = markdown(for: table) { parts.append(markdown) }
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// A table as a Markdown table, so it survives copy-paste and the model
    /// can read the rows as rows.
    private static func markdown(for table: DocumentObservation.Container.Table) -> String? {
        let rows = table.rows
        guard !rows.isEmpty else { return nil }

        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            let cells = row.map {
                $0.content.text.transcript
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
                    .trimmingCharacters(in: .whitespaces)
            }
            guard !cells.isEmpty else { continue }
            lines.append("| " + cells.joined(separator: " | ") + " |")
            if index == 0 {
                lines.append("|" + String(repeating: " --- |", count: cells.count))
            }
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }

    /// Recognize text across several scanned pages, in order.
    static func text(in images: [UIImage], languages: [Locale.Language]) async -> String {
        var pages: [String] = []
        for (index, image) in images.enumerated() {
            if Task.isCancelled { break }
            // The downscaled copy is released before the next page is read;
            // holding 40 full-resolution scans at once would be fatal next
            // to a resident multi-gigabyte model.
            // Made upright first. `downscaled` returns the image untouched
            // when it is already small enough, and `.cgImage` then discards
            // the orientation flag - which hands Vision a portrait photo
            // rotated ninety degrees and reads back gibberish.
            let scaled: CGImage? = autoreleasepool {
                downscaled(ImageNormalizer.upright(image))?.cgImage
            }
            guard let scaled else { continue }
            let page = await text(in: scaled, languages: languages)
            guard !page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            pages.append(images.count > 1 ? "\(L10n.text("Page \(index + 1)"))\n\n\(page)" : page)
        }
        return pages.joined(separator: "\n\n")
    }

    /// Scale an image down so its longest edge is at most `maximumPixels`.
    static func downscaled(_ image: UIImage) -> UIImage? {
        let size = CGSize(width: image.size.width * image.scale,
                          height: image.size.height * image.scale)
        let longest = max(size.width, size.height)
        guard longest > maximumPixels, longest > 0 else { return image }
        let factor = maximumPixels / longest
        let target = CGSize(width: (size.width * factor).rounded(),
                            height: (size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: - Fast impressions

    /// A coarse answer in well under a second, using Vision's classifier
    /// rather than a language model.
    ///
    /// Blind users consistently rate these tools down for latency: waiting
    /// several seconds in silence for a full description is the difference
    /// between a tool people walk around with and one they turn off. This
    /// gives them something true immediately, and the model's richer
    /// description follows.
    static func quickImpression(of image: UIImage) async -> String? {
        guard let cgImage = ImageNormalizer.upright(image).cgImage else { return nil }

        let request = ClassifyImageRequest()
        guard let observations = try? await request.perform(on: cgImage) else { return nil }

        let labels = observations
            .filter { $0.confidence > 0.25 }
            .prefix(2)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        guard !labels.isEmpty else { return nil }

        return labels.joined(separator: ", ")
    }

    // MARK: - PDFs

    /// OCR a PDF whose pages carry no text layer (a scan or a photographed
    /// document). Renders each page and reads it.
    static func text(inScannedPDF url: URL, languages: [Locale.Language]) async -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        let pageCount = min(document.pageCount, maximumPDFPages)
        var pages: [String] = []

        for index in 0..<pageCount {
            if Task.isCancelled { break }
            // Render inside a pool so each page's bitmap is freed before the
            // next one is drawn.
            let rendered: CGImage? = autoreleasepool {
                guard let page = document.page(at: index) else { return nil }
                return render(page: page)?.cgImage
            }
            guard let rendered else { continue }
            let text = await text(in: rendered, languages: languages)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            pages.append("\(L10n.text("Page \(index + 1)"))\n\n\(text)")
        }
        return pages.joined(separator: "\n\n")
    }

    /// Render a PDF page at roughly 2x so small print is legible to Vision,
    /// while capping the pixel count so a huge page can't exhaust memory.
    private static func render(page: PDFPage) -> UIImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        let maximumDimension: CGFloat = 3000
        let scale = min(2.0, maximumDimension / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
    }
}
