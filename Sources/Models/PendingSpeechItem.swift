import Foundation

// An item waiting to be spoken. Lives in SpeechController's queue
// alongside its own rewrite state, so the queue is the single source
// of truth for "what's going to play and in what order" — including
// the in-progress rewrite phase before the TTS engine runs.
//
// Earlier the app used a separate Set<MessageID> for "currently
// rewriting" and a queue<SpeechRequest> for "ready to play," which
// let the two diverge: a message could finish rewriting and get a
// playback slot before an earlier-clicked message's rewrite was
// done, producing out-of-order playback. The unified queue closes
// that gap — queue position is the single ordering axis.
struct PendingSpeechItem: Identifiable, Equatable {
    enum RewriteState: Equatable {
        case pending         // not started yet
        case rewriting       // SpeechTextProcessor.process in flight
        case ready(String)   // rewritten text ready for the driver
    }

    // How the item got into the queue. Manual items go after the last
    // manual item on insert; auto items go at the tail. Preserves
    // click-order among manual clicks and keeps manual priority over
    // Live Speak arrivals.
    enum Source: Equatable {
        case manual  // user clicked Speak or Speak-from-Here
        case auto    // Live Speak auto-enqueued on transcript arrival
    }

    let id: String               // messageID — also the dedup key
    let sourceText: String       // raw text before rewriting
    var rewriteState: RewriteState
    let voiceIdentifier: String?
    let rate: Float
    let source: Source
    let sessionID: String        // for future multi-session cues

    var isRewriting: Bool {
        if case .rewriting = rewriteState { return true }
        return false
    }

    var readyText: String? {
        if case let .ready(text) = rewriteState { return text }
        return nil
    }
}
