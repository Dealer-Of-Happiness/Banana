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

import Foundation

nonisolated enum DocumentText {

    static func read(_ url: URL) throws -> String {
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
}
