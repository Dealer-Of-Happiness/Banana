//
//  MarkdownText.swift
//  AIGoodbye
//
//  Lightweight Markdown renderer for chat bubbles. Handles the formatting
//  small models actually produce: bold, italic, inline code, links, bullet
//  and numbered lists, headers, and fenced code blocks. Self-contained,
//  no third-party dependencies.
//

import SwiftUI

struct MarkdownText: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(inlineAttributed(text))
                        .textSelection(.enabled)
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
                }
            }
        }
    }

    // MARK: - Block parsing

    private enum Block {
        case text(String)
        case code(String, language: String?)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var currentText: [String] = []
        var currentCode: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushText() {
            let text = currentText.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(.text(text)) }
            currentText = []
        }

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    result.append(.code(currentCode.joined(separator: "\n"), language: codeLanguage))
                    currentCode = []
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushText()
                    let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = lang.isEmpty ? nil : lang
                    inCode = true
                }
                continue
            }

            if inCode {
                currentCode.append(line)
            } else {
                currentText.append(line)
            }
        }

        // Unclosed code fence (streaming in progress): show what we have.
        if inCode {
            result.append(.code(currentCode.joined(separator: "\n"), language: codeLanguage))
        } else {
            flushText()
        }

        return result
    }

    // MARK: - Inline formatting

    private func inlineAttributed(_ text: String) -> AttributedString {
        // Pre-process line starts that inline Markdown ignores.
        let processedLines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Headers become bold lines.
            if let range = trimmed.range(of: #"^#{1,4}\s+"#, options: .regularExpression) {
                return "**" + String(trimmed[range.upperBound...]) + "**"
            }
            // Bullets: "- item" or "* item" become "• item".
            if let range = trimmed.range(of: #"^[-*]\s+"#, options: .regularExpression) {
                return "•  " + String(trimmed[range.upperBound...])
            }
            // Numbered lists pass through unchanged.
            if trimmed.range(of: #"^\d{1,3}\.\s+"#, options: .regularExpression) != nil {
                return trimmed
            }
            return line
        }
        let processed = processedLines.joined(separator: "\n")

        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace

        if let attributed = try? AttributedString(markdown: processed, options: options) {
            return attributed
        }
        return AttributedString(text)
    }
}

// MARK: - Code Block

private struct CodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .accessibilityLabel(Text("Copy code"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.systemGray4).opacity(0.5))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
    }
}

#Preview {
    ScrollView {
        MarkdownText(content: """
        Here is **bold**, *italic*, and `inline code`.

        # A header

        - First bullet
        - Second bullet with **bold**

        1. Numbered item
        2. Another item

        ```swift
        let greeting = "Hello"
        print(greeting)
        ```

        And a [link](https://aigoodbye.ai).
        """)
        .padding()
    }
}
