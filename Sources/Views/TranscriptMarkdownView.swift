import SwiftUI
import Textual

// Markdown rendering is ON (restored 2026-06-11). It was disabled
// during a perf investigation whose two preconditions are gone:
// transcripts were unbounded (now capped at 10/50 messages) and
// LazyVStack re-materialized cells on scroll, re-parsing markdown as
// a hot path (now an eager VStack — each visible row's body
// evaluates once per actual invalidation, and MessageRowView's
// .equatable() keeps those scoped to real changes).
//
// Render branches follow the parse-time `Content` classification:
// - .literal — Claude's XML-ish envelopes (hook notifications, slash
//   command metadata): verbatim by design, markdown heuristics would
//   mangle them.
// - .plainText — no markdown constructs detected: plain Text.
// - .markdown — Textual's StructuredText: block rendering with code
//   blocks, headings, tables, lists, and native text selection.
//
// Collapsed rows (lineLimit != nil): plain text keeps Text's true
// lineLimit; markdown is height-capped and clipped instead.
// StructuredText sets .lineLimit(nil) internally — an environment
// line limit would otherwise apply PER text fragment, so a
// three-paragraph document would show three times the intended
// lines. The gradient mask in MessageRowView fades the cut edge
// either way, so a mid-block clip reads as "continues below" rather
// than a hard chop.
struct TranscriptMarkdownView: View, Equatable {
    let content: TranscriptMessage.Content
    // nil = unlimited (expanded / short message). Non-nil caps visible
    // lines for the collapsed state of long rows; MessageRowView decides
    // the value per-message.
    var lineLimit: Int? = nil

    // Approximate advance of one body line (13pt system body on macOS
    // plus the 4pt lineSpacing used below) for the collapsed-height
    // cap on block-rendered markdown. Doesn't need to be exact: the
    // mask fade hides the boundary, and the cap only needs to keep
    // collapsed rows in the same visual ballpark as plain-text ones.
    private static let approximateLineHeight: CGFloat = 22

    var body: some View {
        switch content {
        case let .literal(text), let .plainText(text):
            Text(verbatim: text)
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineSpacing(4)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .markdown(text):
            if let lineLimit {
                markdownBody(text)
                    .frame(
                        maxHeight: CGFloat(lineLimit) * Self.approximateLineHeight,
                        alignment: .top
                    )
                    .clipped()
            } else {
                markdownBody(text)
            }
        }
    }

    private func markdownBody(_ text: String) -> some View {
        StructuredText(markdown: text)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
