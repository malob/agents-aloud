import Foundation

// Which OpenAI Codex model the CLI-backed speech rewriter calls.
//
// Defaults to gpt-5.5 because the 54-run eval matrix
// (`eval-output/codex-eval-matrix-*.md`) showed:
//
//   - gpt-5.4-mini: unreliable. 4 of 18 settings leaked raw Swift code
//     verbatim into the rewrite output (disastrous for TTS). Skipped
//     entirely from the user-facing picker.
//   - gpt-5.5: reliable across all 18 settings, ~7-10s per message,
//     output quality comparable to Claude Sonnet for our task.
//   - gpt-5.3-codex-spark: fastest of the three (~3.6-7s) and reliable
//     across all 18 settings. Limited to ChatGPT Pro and labeled
//     "research preview" — we expose it as an opt-in alternative
//     rather than as the default so non-Pro users aren't blocked.
//
// Cost scales meaningfully across these models — gpt-5.5 is ~2x the
// per-token credit cost of gpt-5.4 and ~7x gpt-5.4-mini per OpenAI's
// rate card. Still negligible at conversational message volume.
enum CodexCLIModel: String, CaseIterable, Identifiable {
    case gpt55 = "gpt-5.5"
    case codexSpark53 = "gpt-5.3-codex-spark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt55: return "GPT-5.5"
        case .codexSpark53: return "GPT-5.3 Codex Spark"
        }
    }

    var detailText: String {
        switch self {
        case .gpt55:
            return "Reliable balance of speed, quality, and consistency. Recommended default."
        case .codexSpark53:
            return "Faster than GPT-5.5 in our eval. Research preview — only available on ChatGPT Pro accounts and may change without notice."
        }
    }

    // Value passed to `codex exec --model`.
    var cliArgument: String { rawValue }
}
