import Foundation

struct SpeechRequest: Equatable {
    let playbackID: UUID
    let messageID: String
    let text: String
    let voiceIdentifier: String?
    // Rate is expressed in words per minute. SystemVoice passes it
    // straight to `say -r`; ElevenLabs maps it onto its 0.7-1.2 speed
    // multiplier. This is the natural unit for the surviving backends
    // — AVSpeech's normalized 0.2-0.6 was the awkward outlier and went
    // away with that backend.
    let wordsPerMinute: Int
}

enum SpeechDriverEvent: Equatable {
    case didStart(UUID)
    case didPause(UUID)
    case didResume(UUID)
    case didFinish(UUID)
    case didFail(UUID, description: String)

    var playbackID: UUID {
        switch self {
        case let .didStart(playbackID),
             let .didPause(playbackID),
             let .didResume(playbackID),
             let .didFinish(playbackID),
             let .didFail(playbackID, _):
            return playbackID
        }
    }
}

@MainActor
protocol SpeechBackendDriver: AnyObject {
    var availableVoices: [SpeechVoiceOption] { get }

    func resolveVoiceIdentifier(_ identifier: String?) -> String?
    func start(
        request: SpeechRequest,
        eventHandler: @escaping @MainActor @Sendable (SpeechDriverEvent) -> Void
    ) throws
    func pause()
    func resume()
    func stop()
}
