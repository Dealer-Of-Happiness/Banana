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

/// Small memo cache for parsed Markdown, keyed by the exact source text.
///
/// A streaming answer produces a new, slightly longer string dozens of times
/// a second; without this, each one re-parses everything before it.
@MainActor
final class MarkdownCache {
    static let shared = MarkdownCache()

    private var blockCache: [String: [MarkdownText.Block]] = [:]
    private var inlineCache: [String: AttributedString] = [:]
    private var blockOrder: [String] = []
    private var inlineOrder: [String] = []
    /// Whole messages.
    private let blockLimit = 60
    /// Paragraphs. Generous because a streaming answer adds a new key for
    /// its growing last paragraph on every redraw; with room for only 60,
    /// those pushed out the paragraphs of the answers on screen, and every
    /// redraw parsed them again.
    private let inlineLimit = 400

    func blocks(for content: String) -> [MarkdownText.Block] {
        if let cached = blockCache[content] { return cached }
        let parsed = MarkdownText.parseBlocks(content)
        blockCache[content] = parsed
        blockOrder.append(content)
        trim(&blockOrder, to: blockLimit) { self.blockCache[$0] = nil }
        return parsed
    }

    func attributed(for text: String) -> AttributedString {
        if let cached = inlineCache[text] { return cached }
        let parsed = MarkdownText.parseInline(text)
        inlineCache[text] = parsed
        inlineOrder.append(text)
        trim(&inlineOrder, to: inlineLimit) { self.inlineCache[$0] = nil }
        return parsed
    }

    private func trim(_ order: inout [String], to limit: Int, remove: (String) -> Void) {
        guard order.count > limit else { return }
        let excess = order.count - limit
        order.prefix(excess).forEach(remove)
        order.removeFirst(excess)
    }
}

struct MarkdownText: View {
    let content: String

    /// Parsing is done once per distinct string and cached. `blocks` used to
    /// be a computed property read from `body`, so a streaming answer
    /// re-parsed the entire accumulated text - regex and Markdown parsing -
    /// on every single token. That is quadratic in the answer length and is
    /// the main reason streaming felt slow on older devices.
    private var blocks: [Block] { MarkdownCache.shared.blocks(for: content) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(MarkdownCache.shared.attributed(for: text))
                        .textSelection(.enabled)
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
                }
            }
        }
    }

    // MARK: - Block parsing

    enum Block {
        case text(String)
        case code(String, language: String?)
    }

    static func parseBlocks(_ content: String) -> [Block] {
        MarkdownText(content: content).parsedBlocks
    }

    static func parseInline(_ text: String) -> AttributedString {
        MarkdownText(content: text).inlineAttributed(text)
    }

    /// The answer as a reader sees it, without Markdown markers - for
    /// selecting and copying a passage out of it.
    static func plainText(_ content: String) -> String {
        MarkdownCache.shared.blocks(for: content).map { block -> String in
            switch block {
            case .text(let text):
                return String(MarkdownCache.shared.attributed(for: text).characters)
            case .code(let code, _):
                return code
            }
        }
        .joined(separator: "\n\n")
    }

    private var parsedBlocks: [Block] {
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
            } else if trimmed.isEmpty {
                // A blank line ends a paragraph. Each paragraph is its own
                // block and so its own cache key: while an answer streams,
                // only the growing last paragraph is parsed again, not the
                // whole answer on every token. (The VStack spacing stands in
                // for the blank line.)
                flushText()
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

    /// Compiled once. `range(of:options: .regularExpression)` built a new
    /// regex for every line of every parse - three per line, per token.
    private static let headerPrefix = #/^#{1,4}\s+/#
    private static let bulletPrefix = #/^[-*]\s+/#
    private static let numberedPrefix = #/^\d{1,3}\.\s+/#

    fileprivate func inlineAttributed(_ text: String) -> AttributedString {
        // Pre-process line starts that inline Markdown ignores.
        let processedLines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Headers become bold lines.
            if let match = trimmed.prefixMatch(of: Self.headerPrefix) {
                return "**" + String(trimmed[match.range.upperBound...]) + "**"
            }
            // Bullets: "- item" or "* item" become "• item".
            if let match = trimmed.prefixMatch(of: Self.bulletPrefix) {
                return "•  " + String(trimmed[match.range.upperBound...])
            }
            // Numbered lists pass through unchanged.
            if trimmed.prefixMatch(of: Self.numberedPrefix) != nil {
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

    /// Shows "Copied" for a moment after a tap; copying used to give no sign.
    @State private var copied = false
    /// Same key as `SettingsManager.hapticFeedbackEnabled`.
    @AppStorage("haptic_feedback") private var hapticsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Group {
                    if let language {
                        Text(verbatim: language)
                    } else {
                        Text("Code")
                    }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    if hapticsEnabled {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    copied = true
                    ChatViewModel.announce(L10n.text("Copied"))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        if copied {
                            Text("Copied")
                        }
                    }
                    .font(.caption)
                    // A full 44 x 44 target (it was 44 x 32).
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(copied ? Text("Copied") : Text("Copy code"))
                // Keyed, so a second tap restarts the 1.5 s rather than
                // inheriting the first one's timer.
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            .padding(.horizontal, 10)
            .background(Color(.systemGray4).opacity(0.5))

            ScrollView(.horizontal, showsIndicators: false) {
                // Footnote, not caption: 12 pt code under 17 pt prose was
                // the hardest text in the app to read. Still scales with
                // Dynamic Type.
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
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
