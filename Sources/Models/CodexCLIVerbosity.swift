import Foundation

// Verbosity level passed to `codex exec -c model_verbosity=<level>`
// for the Codex CLI speech rewriter. The CLI accepts: low, medium,
// high. Affects sentence structure / connective tissue more than
// total length — at low, prose comes out terse and clipped; at
// medium it adds light connectives and reads more naturally as
// listened audio; at high it gets meaningfully wordier without
// adding new information.
//
// Defaults to `medium` because the user-tested-this-in-the-loop
// preference is for slightly smoother prose between sentences when
// hearing the rewrite read aloud. `low` is available for users who
// want the tightest possible output.
enum CodexCLIVerbosity: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var detailText: String {
        switch self {
        case .low:
            return "Tightest output. Short sentences with minimal connective tissue."
        case .medium:
            return "Recommended default. Smoother prose with light connectives — reads better as listened audio."
        case .high:
            return "Wordier prose. Adds connective tissue and softening phrases without new information."
        }
    }

    // Value passed to `codex exec -c model_verbosity`.
    var cliArgument: String { rawValue }
}
