import Foundation

// Identifies which CLI's session log a transcript came from. Threaded
// through ClaudeSessionSummary so the sidebar can render per-source
// icons and the user can filter the unified feed by source.
//
// Keeping this enum separate from `SpeechBackend` and from the
// optimization-mode enum because it's a different axis of concern —
// the speech backend (TTS engine) and the rewriter optimizer
// (Claude / Codex CLI used to rewrite text) are unrelated to which
// CLI's transcripts we're showing in the sidebar.
enum TranscriptSource: String, CaseIterable, Identifiable, Hashable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    // SF Symbol for the source. Reused in both the sidebar filter
    // picker and the per-row indicator. SF Symbols doesn't ship
    // brand assets; we lean on suggestive abstract symbols and
    // tooltips for clarity. Could swap for custom assets later.
    var symbolName: String {
        switch self {
        case .claude: return "bubble.left.and.bubble.right.fill"
        case .codex: return "sparkles"
        }
    }
}
