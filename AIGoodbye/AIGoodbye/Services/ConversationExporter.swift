//
//  ConversationExporter.swift
//  AIGoodbye
//
//  Export a conversation as Markdown or PDF so the user owns their data and
//  can take it anywhere. Generated locally; sharing is the user's choice.
//

import Foundation
import UIKit
import PDFKit

enum ConversationExporter {

    // MARK: - Markdown

    static func markdown(for conversation: Conversation) -> String {
        // In the app's language, like every other date the app shows.
        let created = conversation.createdAt.aigFormatted(date: .abbreviated, time: .shortened)

        var out = "# \(conversation.displayTitle)\n\n"
        out += "_\(created) — \(LegalText.appName)_\n\n"

        for message in conversation.messages.sorted(by: { $0.timestamp < $1.timestamp }) {
            let who = message.role == .user
                ? L10n.text("You")
                : LegalText.appName
            out += "## \(who)\n\n\(exportBody(of: message))\n\n"
        }
        return out
    }

    /// The message text, with a note where a picture was attached (the
    /// export used to show only the question, as if no picture existed).
    private static func exportBody(of message: Message) -> String {
        guard message.attachmentType == .image else { return message.content }
        return "[" + L10n.text("Image attached") + "]\n\n" + message.content
    }

    /// Writes Markdown to a temporary file for the share sheet.
    static func markdownFile(for conversation: Conversation) -> URL? {
        write(markdown(for: conversation), name: safeFileName(conversation.displayTitle) + ".md")
    }

    private static func write(_ text: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        // Previous exports with the same name are replaced, not accumulated.
        try? FileManager.default.removeItem(at: url)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Recordings

    static func markdown(for recording: Recording) -> String {
        var out = "# \(recording.title)\n\n"
        out += "_\(recording.createdAt.aigFormatted(date: .abbreviated, time: .shortened)) — "
        out += "\(durationText(recording.duration)) — \(LegalText.appName)_\n\n"
        if let summary = recording.summary, !summary.isEmpty {
            out += summary + "\n\n"
        }
        out += "## " + L10n.text("Transcript") + "\n\n" + recording.transcript + "\n"
        return out
    }

    static func markdownFile(for recording: Recording) -> URL? {
        write(markdown(for: recording), name: safeFileName(recording.title) + ".md")
    }

    static func pdfFile(for recording: Recording) -> URL? {
        var blocks: [PDFBlock] = []
        let created = recording.createdAt.aigFormatted(date: .abbreviated, time: .shortened)
        blocks.append(PDFBlock(heading: nil, body: "\(created) — \(durationText(recording.duration))"))
        if let summary = recording.summary, !summary.isEmpty {
            // Written by the model, in Markdown like a chat answer.
            blocks.append(PDFBlock(heading: nil, body: summary, isMarkdown: true))
        }
        blocks.append(PDFBlock(heading: L10n.text("Transcript"), body: recording.transcript))
        return pdfFile(title: recording.title, blocks: blocks,
                       fileName: safeFileName(recording.title) + ".pdf")
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - PDF

    /// Renders with Core Text so a single very long message flows across as
    /// many pages as it needs instead of being clipped.
    static func pdfFile(for conversation: Conversation) -> URL? {
        var blocks: [PDFBlock] = []
        for message in conversation.messages.sorted(by: { $0.timestamp < $1.timestamp }) {
            let who = message.role == .user ? L10n.text("You") : LegalText.appName
            blocks.append(PDFBlock(heading: who, body: exportBody(of: message), isMarkdown: true))
        }
        return pdfFile(title: conversation.displayTitle, blocks: blocks,
                       fileName: safeFileName(conversation.displayTitle) + ".pdf")
    }

    /// One section of a PDF: an optional small heading and its text.
    private struct PDFBlock {
        let heading: String?
        let body: String
        /// Rendered as formatted text rather than printed as source.
        var isMarkdown = false
    }

    private static func pdfFile(title: String, blocks: [PDFBlock], fileName: String) -> URL? {
        let pageSize = CGSize(width: 595, height: 842)   // A4 at 72dpi
        let margin: CGFloat = 48
        let contentWidth = pageSize.width - margin * 2

        let titleFont = UIFont.systemFont(ofSize: 20, weight: .bold)
        let roleFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
        let bodyFont = UIFont.systemFont(ofSize: 12)

        // One attributed string for the whole document, then let Core Text
        // paginate it.
        let document = NSMutableAttributedString()
        func append(_ text: String, font: UIFont, spacingAfter: CGFloat) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = spacingAfter
            paragraph.lineBreakMode = .byWordWrapping
            document.append(NSAttributedString(
                string: text + "\n",
                attributes: [.font: font, .paragraphStyle: paragraph]
            ))
        }

        append(title, font: titleFont, spacingAfter: 16)
        for block in blocks {
            if let heading = block.heading {
                append(heading, font: roleFont, spacingAfter: 2)
            }
            if block.isMarkdown {
                document.append(renderedMarkdown(block.body, font: bodyFont, spacingAfter: 14))
            } else {
                append(block.body, font: bodyFont, spacingAfter: 14)
            }
        }

        let name = fileName
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        let textRect = CGRect(x: margin, y: margin, width: contentWidth,
                              height: pageSize.height - margin * 2)

        do {
            try renderer.writePDF(to: url) { context in
                let framesetter = CTFramesetterCreateWithAttributedString(document)
                var range = CFRange(location: 0, length: 0)
                let total = document.length
                var guardCounter = 0

                repeat {
                    context.beginPage()
                    let cgContext = context.cgContext
                    // Core Text draws bottom-up; flip into UIKit coordinates.
                    cgContext.textMatrix = .identity
                    cgContext.translateBy(x: 0, y: pageSize.height)
                    cgContext.scaleBy(x: 1, y: -1)

                    let path = CGPath(rect: CGRect(
                        x: textRect.minX,
                        y: pageSize.height - textRect.maxY,
                        width: textRect.width,
                        height: textRect.height
                    ), transform: nil)

                    let frame = CTFramesetterCreateFrame(
                        framesetter, CFRange(location: range.location, length: 0), path, nil
                    )
                    CTFrameDraw(frame, cgContext)

                    let visible = CTFrameGetVisibleStringRange(frame)
                    // No forward progress would loop forever; bail out.
                    if visible.length <= 0 { break }
                    range.location += visible.length
                    guardCounter += 1
                } while range.location < total && guardCounter < 500
            }
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Markdown for the PDF

    private static let headingPrefix = #/^(#{1,6})\s+/#
    private static let bulletPrefix = #/^[-*+]\s+/#

    /// A body as it reads in the app rather than as Markdown source: headings
    /// bold (14 pt for a top-level one, 13 pt below), **bold** and *italic*
    /// applied, `code` and fenced blocks monospaced, list markers as bullets.
    /// The "share this answer with my landlord" PDF used to print `## Summary`
    /// and `**Key terms**` literally. Anything that doesn't parse is kept as
    /// plain text. Ends with a newline, like the plain blocks.
    private static func renderedMarkdown(_ text: String, font: UIFont, spacingAfter: CGFloat) -> NSAttributedString {
        let mono = UIFont.monospacedSystemFont(ofSize: max(font.pointSize - 1, 9), weight: .regular)
        let result = NSMutableAttributedString()
        var inCode = false

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                result.append(NSAttributedString(string: rawLine + "\n", attributes: [.font: mono]))
                continue
            }
            if let match = trimmed.prefixMatch(of: headingPrefix) {
                let level = match.output.1.count
                let headingFont = UIFont.systemFont(ofSize: level == 1 ? 14 : 13, weight: .bold)
                let heading = String(trimmed[match.range.upperBound...])
                result.append(inlineMarkdown(heading + "\n", font: headingFont, mono: mono))
            } else if let match = trimmed.prefixMatch(of: bulletPrefix) {
                let item = "•  " + String(trimmed[match.range.upperBound...])
                result.append(inlineMarkdown(item + "\n", font: font, mono: mono))
            } else {
                result.append(inlineMarkdown(rawLine + "\n", font: font, mono: mono))
            }
        }

        // Tight lines inside a message, the usual gap after it.
        let full = NSRange(location: 0, length: result.length)
        let lineStyle = NSMutableParagraphStyle()
        lineStyle.paragraphSpacing = 4
        lineStyle.lineBreakMode = .byWordWrapping
        result.addAttribute(.paragraphStyle, value: lineStyle, range: full)
        if result.length > 0 {
            let last = (result.string as NSString).paragraphRange(for: NSRange(location: result.length - 1, length: 0))
            let endStyle = NSMutableParagraphStyle()
            endStyle.paragraphSpacing = spacingAfter
            endStyle.lineBreakMode = .byWordWrapping
            result.addAttribute(.paragraphStyle, value: endStyle, range: last)
        }
        return result
    }

    /// Bold, italic, code and links within one line.
    private static func inlineMarkdown(_ line: String, font: UIFont, mono: UIFont) -> NSAttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard let parsed = try? AttributedString(markdown: line, options: options) else {
            return NSAttributedString(string: line, attributes: [.font: font])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = mono
                } else {
                    var traits = font.fontDescriptor.symbolicTraits
                    if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                    if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                    if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                        runFont = UIFont(descriptor: descriptor, size: font.pointSize)
                    }
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont]
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }

    // MARK: - Helpers

    private static func safeFileName(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Conversation" : String(cleaned.prefix(60))
    }
}
