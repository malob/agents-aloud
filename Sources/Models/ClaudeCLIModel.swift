import Foundation

// Which Claude model the CLI-backed speech rewriter calls.
//
// Defaults to Sonnet because (measured): on a representative 1.3KB
// structure-heavy input, Sonnet averages ~9.6s with 0.2s run-to-run
// variance, versus Haiku 4.5's ~18s with 12s variance. Haiku's
// infrastructure provisioning is currently much noisier than
// Sonnet's, so "smaller model is faster" doesn't actually hold in
// practice. Opus is slower + more expensive but tighter output for
// longer / more structured messages.
//
// Cost per ~1KB rewrite, ballpark:
//   Haiku:  ~$0.002
//   Sonnet: ~$0.01
//   Opus:   ~$0.05
// All trivial at conversational volume and absorbed by the user's
// OAuth'd Claude Code subscription.
enum ClaudeCLIModel: String, CaseIterable, Identifiable {
    case haiku
    case sonnet
    case opus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .haiku: return "Haiku"
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        }
    }

    var detailText: String {
        switch self {
        case .haiku:
            return "Fastest and cheapest, but noisier latency — single messages can run 5–25s depending on current provisioning."
        case .sonnet:
            return "Best balance. ~10s per message with tight run-to-run variance. Recommended default."
        case .opus:
            return "Highest quality for long or unusually structured messages. Slower and more expensive than Sonnet."
        }
    }

    // Argument value passed to `claude --model`.
    var cliArgument: String { rawValue }
}
