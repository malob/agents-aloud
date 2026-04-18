import AppKit
import SwiftUI
import Textual

struct TranscriptMarkdownView: View, Equatable {
    let content: TranscriptMessage.Content

    @ViewBuilder
    var body: some View {
        switch content {
        case .literal:
            literalContent
        case .plainText:
            plainTextContent
        case let .markdown(markdown):
            StructuredText(markdown, parser: CachedMarkdownParser())
                .font(.body)
                .foregroundStyle(.primary)
                .textual.inlineStyle(.claudeTranscript)
                .textual.structuredTextStyle(.claudeTranscript)
        }
    }

    private var literalContent: some View {
        Text(verbatim: content.text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.primary)
            .lineSpacing(4)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var plainTextContent: some View {
        Text(verbatim: content.text)
            .font(.body)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private final class MarkdownAttributedStringCache {
    static let shared = MarkdownAttributedStringCache()

    private let parser = AttributedStringMarkdownParser(baseURL: nil)
    private let cache: NSCache<NSString, AttributedStringBox>

    init() {
        let cache = NSCache<NSString, AttributedStringBox>()
        cache.name = "ClaudeMarkdown"
        cache.countLimit = 1024
        self.cache = cache
    }

    func attributedString(for input: String) throws -> AttributedString {
        let cacheKey = input as NSString

        if let cached = cache.object(forKey: cacheKey) {
            return cached.value
        }

        let parsed = try parser.attributedString(for: input)
        cache.setObject(AttributedStringBox(parsed), forKey: cacheKey)
        return parsed
    }
}

private final class AttributedStringBox: NSObject {
    let value: AttributedString

    init(_ value: AttributedString) {
        self.value = value
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
        .background(.fill.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator.secondary.opacity(0.6), lineWidth: 1)
        }
        .textual.blockSpacing(.fontScaled(top: 0.8, bottom: 0.15))
    }
}

private extension InlineStyle {
    static let claudeTranscript = InlineStyle()
        .code(
            .monospaced,
            .fontScale(0.9),
            .backgroundColor(Color.secondary.opacity(0.14)),
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
