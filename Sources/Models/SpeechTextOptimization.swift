import Foundation

// Which backend (if any) rewrites assistant message text for speech
// before handing it to the TTS engine.
//
// `off` = raw message text goes straight to TTS (markdown, code, and
//          URLs read literally — sounds rough but zero added latency)
// `claudeCLI` = shell out to `claude --print --model haiku`; best
//               quality. Latency ~5s for short messages, up to
//               ~60s on long structure-heavy messages (tables +
//               code blocks + lists). Needs `claude` CLI installed
//               and authenticated.
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
            return "Claude (Haiku) via CLI"
        case .foundationModel:
            return "Apple Intelligence (experimental)"
        }
    }

    var detailText: String {
        switch self {
        case .off:
            return "Message text is sent to the speech engine unchanged. Markdown, code blocks, and URLs will be read literally."
        case .claudeCLI:
            return "Rewrites code blocks, tables, and structure-heavy content into speech-friendly prose. Requires the `claude` CLI installed and authenticated. Adds about 5 seconds of latency for short messages and up to a minute for long, heavily-formatted ones."
        case .foundationModel:
            return "On-device rewriting using Apple Intelligence. Currently experimental — the on-device model has limited success on this task. Requires Apple Intelligence enabled on this Mac."
        }
    }
}
