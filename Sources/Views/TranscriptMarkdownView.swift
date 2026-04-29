import SwiftUI

// Intentionally renders `content.text` verbatim — markdown rendering was
// disabled during a performance investigation (large transcripts + eager
// markdown parsing on scroll was a hot path). `TranscriptMessage.Content`
// classification and the `Textual` dependency are kept wired so we can
// restore markdown rendering by branching on `content` (e.g.
// `Text(AttributedString(markdown: ...))` or `Textual`) without re-doing
// the plumbing. Don't "fix" this to render markdown without re-running
// the perf check.
struct TranscriptMarkdownView: View, Equatable {
    let content: TranscriptMessage.Content
    // nil = unlimited (expanded / short message). Non-nil caps visible
    // lines for the collapsed state of long rows; MessageRowView decides
    // the value per-message.
    var lineLimit: Int? = nil

    var body: some View {
        Text(verbatim: content.text)
            .font(.body)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineSpacing(4)
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
