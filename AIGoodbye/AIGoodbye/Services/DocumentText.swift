//
//  DocumentText.swift
//  AIGoodbye
//
//  Reading a text file the way people actually save them.
//
//  `String(contentsOf:encoding: .utf8)` rejects a Russian .txt from Windows
//  (Windows-1251), a Greek one (Windows-1253), Shift-JIS or GB18030 exports,
//  and UTF-16 with a byte-order mark - which is what Notepad and many tools
//  write. For an app shipping in those languages the import then failed
//  with a raw Foundation error. This tries, in order: the encoding the
//  file declares (BOM), Foundation's detector, and the common legacy code
//  pages, before giving up.
//
//  Rich text and web pages are reduced to their words first. Read as plain
//  text they handed the model `{\rtf1\ansi…` control words or a page of
//  tags and scripts, and the user a "document" nobody could ask about.
//

import Foundation
import UIKit

nonisolated enum DocumentText {

    static func read(_ url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "rtf":
            return try attributedText(url, type: .rtf)
        case "rtfd":
            return try attributedText(url, type: .rtfd)
        case "html", "htm", "xhtml":
            return plainText(fromHTML: try readEncoded(url))
        default:
            return try readEncoded(url)
        }
    }

    // MARK: - Plain text in any common encoding

    private static func readEncoded(_ url: URL) throws -> String {
        var declared = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &declared) {
            return text
        }

        let data = try Data(contentsOf: url)

        var converted: NSString?
        let detected = NSString.stringEncoding(
            for: data,
            encodingOptions: [.allowLossyKey: false],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        if detected != 0, let converted {
            return converted as String
        }

        let fallbacks: [String.Encoding] = [
            .utf16, .windowsCP1251, .windowsCP1253, .windowsCP1252,
            .shiftJIS, .japaneseEUC, .isoLatin1
        ]
        for encoding in fallbacks {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    // MARK: - Rich text

    /// RTF and RTFD (a package: text plus attachments) through the system
    /// reader, which is safe off the main thread for these two types.
    private static func attributedText(_ url: URL, type: NSAttributedString.DocumentType) throws -> String {
        let attributed = try NSAttributedString(
            url: url,
            options: [.documentType: type],
            documentAttributes: nil
        )
        // Embedded pictures surface as object-replacement characters, which
        // mean nothing to a language model.
        return attributed.string.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    // MARK: - HTML

    /// The words of a web page, without WebKit. NSAttributedString's HTML
    /// importer would be the obvious tool, but it must run on the main
    /// thread (elsewhere it waits on the main thread and times out), and
    /// every caller reads documents on a background task so a large file
    /// never freezes the chat.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        // Content that is never displayed.
        text = replacing(#"(?is)<(script|style|head|noscript|template|svg)\b[^>]*>.*?</\1\s*>"#, in: text, with: " ")
        text = replacing(#"(?s)<!--.*?-->"#, in: text, with: " ")
        // Source line breaks mean nothing in HTML; markup decides the layout.
        text = replacing(#"\s+"#, in: text, with: " ")
        text = replacing(#"(?i)<br\s*/?>"#, in: text, with: "\n")
        text = replacing(#"(?i)<li\b[^>]*>"#, in: text, with: "\n• ")
        text = replacing(#"(?i)</(p|div|h[1-6]|tr|ul|ol|table|blockquote|pre|section|article|header|footer|aside|nav|dl|dt|dd|figure|figcaption)\s*>"#, in: text, with: "\n")
        text = replacing(#"(?i)<(p|div|h[1-6]|tr|table|blockquote|pre|section|article|header|footer|hr)\b[^>]*>"#, in: text, with: "\n")
        text = replacing(#"(?i)</t[dh]\s*>"#, in: text, with: "\t")
        // Whatever markup is left carries no text.
        text = replacing(#"<[^>]*>"#, in: text, with: "")
        text = decodeEntities(text)
        // Tidy what the markup left behind: runs of spaces, spaces at line
        // edges, and stacks of empty lines.
        // Tabs are kept: they are what separates table cells.
        text = replacing(#"[ \x{00A0}]+"#, in: text, with: " ")
        text = replacing(#"[ \t]*\n[ \t]*"#, in: text, with: "\n")
        text = replacing(#"\n{3,}"#, in: text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: template)
        )
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "bull": "•",
        "middot": "·", "copy": "©", "reg": "®", "trade": "™", "euro": "€",
        "pound": "£", "yen": "¥", "deg": "°", "times": "×", "shy": ""
    ]

    /// `&amp;`, `&#8217;` and `&#x2019;` back into characters.
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&"),
              let regex = try? NSRegularExpression(
                pattern: #"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});"#
              ) else { return text }
        let result = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: result.length))
        // Back to front, so earlier ranges stay valid as lengths change.
        for match in matches.reversed() {
            let body = result.substring(with: match.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let code = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                    replacement = String(Character(scalar))
                }
            } else if body.hasPrefix("#") {
                if let code = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(code) {
                    replacement = String(Character(scalar))
                }
            } else {
                replacement = namedEntities[body] ?? namedEntities[body.lowercased()]
            }
            if let replacement {
                result.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return result as String
    }
}
