import Foundation

struct SpeechRequest: Equatable {
    let playbackID: UUID
    let messageID: String
    let text: String
    let voiceIdentifier: String?
    let rate: Float
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
    var wordsPerMinute: Int? { get }

    func resolveVoiceIdentifier(_ identifier: String?) -> String?
    func start(
        request: SpeechRequest,
        eventHandler: @escaping @MainActor @Sendable (SpeechDriverEvent) -> Void
    ) throws
    func pause()
    func resume()
    func stop()
}
