import Foundation

// Effort level passed to `claude --effort <level>` for the CLI-backed
// speech rewriter. The CLI ladder is low → medium → high → xhigh → max;
// omitting the flag entirely behaves like `max` (so historically we
// were paying for max effort).
//
// Defaults to `medium` based on the eval sweep at fixed model=Sonnet
// on a representative 1.3KB structure-heavy input
// (`eval-output/cli-eval-effort-*.md`):
//
//   low:    ~6.5s
//   medium: ~6.8s   ← default; output indistinguishable from low
//   high:   ~17s
//   xhigh:  ~21s
//   max:    ~32s   (matches no-flag default)
//
// Output quality at low and medium were both indistinguishable from
// the higher levels for our markdown→speech task — tables expanded
// inline, URLs replaced with natural-language phrases, file
// extensions dropped, identifiers preserved exactly. We default to
// medium rather than low because the latency cost is ~300ms and
// the headroom buys us robustness on longer / more complex messages
// where the eval didn't probe.
enum ClaudeCLIEffort: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "X-High"
        case .max: return "Max"
        }
    }

    var detailText: String {
        switch self {
        case .low:
            return "Fastest. Quality indistinguishable from medium in our eval."
        case .medium:
            return "Recommended default. A hair slower than low, with headroom for outliers."
        case .high:
            return "Noticeably slower with no measurable quality gain over medium for read-aloud."
        case .xhigh:
            return "Slower still. Diminishing returns."
        case .max:
            return "Slowest. Equivalent to the CLI's no-flag default."
        }
    }

    // Value passed to `claude --effort`.
    var cliArgument: String { rawValue }
}
