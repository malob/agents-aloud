import AppKit
import SwiftUI
import Textual

struct TranscriptMarkdownView: View, Equatable {
    let markdown: String

    var body: some View {
        Group {
            switch renderingMode {
            case .literal:
                literalContent
            case .plainText:
                plainTextContent
            case .markdown:
                StructuredText(markdown, parser: CachedMarkdownParser())
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textual.inlineStyle(.claudeTranscript)
                    .textual.structuredTextStyle(.claudeTranscript)
            }
        }
    }

    private var renderingMode: RenderingMode {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let literalPrefixes = [
            "<task-notification>",
            "<command-message>",
            "<command-name>",
            "<command-args>",
            "<local-command-caveat>",
        ]

        if literalPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return .literal
        }

        if markdown.contains("```") ||
            markdown.contains("`") ||
            markdown.contains("](") ||
            markdown.contains("![") ||
            markdown.contains("**") ||
            markdown.contains("__") ||
            markdown.contains("~~") {
            return .markdown
        }

        for line in markdown.split(whereSeparator: \.isNewline) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty {
                continue
            }

            if trimmedLine.hasPrefix("#") ||
                trimmedLine.hasPrefix(">") ||
                trimmedLine.hasPrefix("- ") ||
                trimmedLine.hasPrefix("* ") ||
                trimmedLine.hasPrefix("+ ") ||
                trimmedLine == "---" ||
                trimmedLine == "***" ||
                trimmedLine.contains("| ---") ||
                trimmedLine.contains(" | ") ||
                orderedListPrefix(in: trimmedLine) {
                return .markdown
            }
        }

        return .plainText
    }

    private var literalContent: some View {
        Text(verbatim: markdown)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.primary)
            .lineSpacing(4)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var plainTextContent: some View {
        Text(verbatim: markdown)
            .font(.body)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func orderedListPrefix(in line: String) -> Bool {
        var digits = 0

        for character in line {
            if character.isNumber {
                digits += 1
                continue
            }

            return digits > 0 && character == "." && line.dropFirst(digits + 1).first == " "
        }

        return false
    }
}

private enum RenderingMode {
    case literal
    case plainText
    case markdown
}

@MainActor
private final class MarkdownAttributedStringCache {
    static let shared = MarkdownAttributedStringCache()

    private let parser = AttributedStringMarkdownParser(baseURL: nil)
    private var cache: [String: AttributedString] = [:]
    private let maxEntries = 256

    func attributedString(for input: String) throws -> AttributedString {
        if let cached = cache[input] {
            return cached
        }

        let parsed = try parser.attributedString(for: input)

        if cache.count >= maxEntries, let firstKey = cache.keys.first {
            cache.removeValue(forKey: firstKey)
        }

        cache[input] = parsed
        return parsed
    }
}

@MainActor
private struct CachedMarkdownParser: MarkupParser {
    func attributedString(for input: String) throws -> AttributedString {
        try MarkdownAttributedStringCache.shared.attributedString(for: input)
    }
}

private struct ClaudeTranscriptMarkdownStyle: StructuredText.Style {
    let inlineStyle: InlineStyle = .claudeTranscript
    let headingStyle = ClaudeTranscriptHeadingStyle()
    let paragraphStyle = ClaudeTranscriptParagraphStyle()
    let blockQuoteStyle: StructuredText.DefaultBlockQuoteStyle = .default
    let codeBlockStyle = ClaudeTranscriptCodeBlockStyle()
    let listItemStyle: StructuredText.DefaultListItemStyle = .default
    let unorderedListMarker: StructuredText.SymbolListMarker = .disc
    let orderedListMarker: StructuredText.DecimalListMarker = .decimal
    let tableStyle: StructuredText.DefaultTableStyle = .default
    let tableCellStyle: StructuredText.DefaultTableCellStyle = .default
    let thematicBreakStyle: StructuredText.DividerThematicBreakStyle = .divider
}

private struct ClaudeTranscriptHeadingStyle: StructuredText.HeadingStyle {
    private static let lineSpacings: [CGFloat] = [0.08, 0.18, 0.12, 0.14, 0.16, 0.22]
    private static let fontScales: [CGFloat] = [1.65, 1.42, 1.28, 1.16, 1.08, 1.0]

    func makeBody(configuration: Configuration) -> some View {
        let headingLevel = min(configuration.headingLevel, 6)
        let lineSpacing = Self.lineSpacings[headingLevel - 1]
        let fontScale = Self.fontScales[headingLevel - 1]

        configuration.label
            .textual.fontScale(fontScale)
            .textual.lineSpacing(.fontScaled(lineSpacing))
            .textual.blockSpacing(.fontScaled(top: 1.2, bottom: 0.45))
            .fontWeight(.semibold)
    }
}

private struct ClaudeTranscriptParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(0.19))
            .textual.blockSpacing(.fontScaled(top: 0.65))
    }
}

private struct ClaudeTranscriptCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        Overflow {
            configuration.label
                .textual.lineSpacing(.fontScaled(0.32))
                .textual.fontScale(0.9)
                .fixedSize(horizontal: false, vertical: true)
                .monospaced()
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
        .textual.blockSpacing(.fontScaled(top: 0.8, bottom: 0.15))
    }
}

private extension InlineStyle {
    static let claudeTranscript = InlineStyle()
        .code(
            .monospaced,
            .fontScale(0.9),
            .backgroundColor(Color(nsColor: .controlBackgroundColor)),
            .foregroundColor(.primary)
        )
        .strong(.fontWeight(.semibold))
        .link(.foregroundColor(.accentColor))
}

private extension StructuredText.Style where Self == ClaudeTranscriptMarkdownStyle {
    static var claudeTranscript: Self {
        .init()
    }
}
