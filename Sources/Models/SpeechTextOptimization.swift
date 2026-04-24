import Foundation

// Which backend (if any) rewrites assistant message text for speech
// before handing it to the TTS engine.
//
// `off` = raw message text goes straight to TTS (markdown, code, and
//          URLs read literally — sounds rough but zero added latency)
// `claudeCLI` = shell out to `claude --print`; best quality, ~10s
//               added latency per message (tight run-to-run variance).
//               Model is configurable separately via `ClaudeCLIModel`.
//               Needs `claude` CLI installed and authenticated.
//
// Apple's on-device FoundationModels framework was previously offered
// as an `.foundationModel` option here, but the ~3B model couldn't
// handle structure-heavy output (code, tables, URLs) across multiple
// prompt variants — it kept echoing markdown verbatim. Removed rather
// than maintain a backend that never shipped useful output. If a
// future on-device model handles the task, we'll add a new case.
enum SpeechTextOptimization: String, CaseIterable, Identifiable {
    case off
    case claudeCLI = "claude_cli"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .claudeCLI:
            return "Claude via CLI"
        }
    }

    var detailText: String {
        switch self {
        case .off:
            return "Message text is sent to the speech engine unchanged. Markdown, code blocks, and URLs will be read literally."
        case .claudeCLI:
            return "Rewrites code blocks, tables, and structure-heavy content into speech-friendly prose. Requires the `claude` CLI installed and authenticated."
        }
    }
}
