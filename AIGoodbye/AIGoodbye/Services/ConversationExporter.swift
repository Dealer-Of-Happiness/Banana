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
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var out = "# \(conversation.displayTitle)\n\n"
        out += "_\(formatter.string(from: conversation.createdAt)) — \(LegalText.appName)_\n\n"

        for message in conversation.messages.sorted(by: { $0.timestamp < $1.timestamp }) {
            let who = message.role == .user
                ? L10n.text("You")
                : LegalText.appName
            out += "## \(who)\n\n\(message.content)\n\n"
        }
        return out
    }

    /// Writes Markdown to a temporary file for the share sheet.
    static func markdownFile(for conversation: Conversation) -> URL? {
        write(markdown(for: conversation), name: safeFileName(conversation.displayTitle) + ".md")
    }

    private static func write(_ text: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Recordings

    static func markdown(for recording: Recording) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var out = "# \(recording.title)\n\n"
        out += "_\(formatter.string(from: recording.createdAt)) — "
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
        var blocks: [(String?, String)] = []
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        blocks.append((nil, "\(formatter.string(from: recording.createdAt)) — \(durationText(recording.duration))"))
        if let summary = recording.summary, !summary.isEmpty {
            blocks.append((nil, summary))
        }
        blocks.append((L10n.text("Transcript"), recording.transcript))
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
        var blocks: [(String?, String)] = []
        for message in conversation.messages.sorted(by: { $0.timestamp < $1.timestamp }) {
            let who = message.role == .user ? L10n.text("You") : LegalText.appName
            blocks.append((who, message.content))
        }
        return pdfFile(title: conversation.displayTitle, blocks: blocks,
                       fileName: safeFileName(conversation.displayTitle) + ".pdf")
    }

    private static func pdfFile(title: String, blocks: [(String?, String)], fileName: String) -> URL? {
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
            if let heading = block.0 {
                append(heading, font: roleFont, spacingAfter: 2)
            }
            append(block.1, font: bodyFont, spacingAfter: 14)
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

    // MARK: - Helpers

    private static func safeFileName(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Conversation" : String(cleaned.prefix(60))
    }
}
