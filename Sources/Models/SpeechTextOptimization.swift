import Foundation

// Which backend (if any) rewrites assistant message text for speech
// before handing it to the TTS engine.
//
// `off` = raw message text goes straight to TTS (markdown, code, and
//          URLs read literally — sounds rough but zero added latency)
// `claudeCLI` = shell out to `claude --print --model sonnet`; best
//               quality, ~10s added latency per message (tight run-to-
//               run variance). Needs `claude` CLI installed and
//               authenticated.
// `foundationModel` = Apple's on-device FoundationModels framework;
//                     experimental — the ~3B model currently struggles
//                     with this task, kept as an option for users who
//                     want fully on-device processing
enum SpeechTextOptimization: String, CaseIterable, Identifiable {
    case off
    case claudeCLI = "claude_cli"
    case foundationModel = "foundation_model"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .claudeCLI:
            return "Claude (Sonnet) via CLI"
        case .foundationModel:
            return "Apple Intelligence (experimental)"
        }
    }

    var detailText: String {
        switch self {
        case .off:
            return "Message text is sent to the speech engine unchanged. Markdown, code blocks, and URLs will be read literally."
        case .claudeCLI:
            return "Rewrites code blocks, tables, and structure-heavy content into speech-friendly prose. Requires the `claude` CLI installed and authenticated. Adds about 10 seconds of latency per message."
        case .foundationModel:
            return "On-device rewriting using Apple Intelligence. Currently experimental — the on-device model has limited success on this task. Requires Apple Intelligence enabled on this Mac."
        }
    }
}
