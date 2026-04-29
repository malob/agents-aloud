import Foundation

// Effort level passed to `codex exec -c model_reasoning_effort=<level>`
// for the Codex CLI speech rewriter. The CLI accepts: minimal, low,
// medium, high, xhigh. (No `max` — that's a Claude-only level.)
//
// Defaults to `low` based on the eval matrix
// (`eval-output/codex-eval-matrix-*.md`): on gpt-5.5 and gpt-5.3-codex-
// spark, output quality at low was indistinguishable from medium and
// high for our markdown→speech task. Low was also the fastest of the
// tested rungs.
//
// We don't expose `minimal` in the picker — it wasn't tested in the
// eval and is too aggressive for a default-style production knob. If
// a user needs to drop further, they can override via a future
// `-c model_reasoning_effort="minimal"` setting; the enum can grow.
enum CodexCLIEffort: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "X-High"
        }
    }

    var detailText: String {
        switch self {
        case .low:
            return "Fastest. Quality indistinguishable from medium in our eval."
        case .medium:
            return "Slower than low without a measurable quality gain on this task."
        case .high:
            return "Noticeably slower with no measurable quality gain over low or medium."
        case .xhigh:
            return "Slowest. Maximum reasoning effort offered by the Codex CLI."
        }
    }

    // Value passed to `codex exec -c model_reasoning_effort`.
    var cliArgument: String { rawValue }
}
