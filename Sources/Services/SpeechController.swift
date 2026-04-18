import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class SpeechController {
    private struct ActivePlayback {
        let request: SpeechRequest
        let backend: SpeechBackend
    }

    private enum PlaybackState {
        case idle
        case speaking(ActivePlayback)
        case paused(ActivePlayback)

        var activePlayback: ActivePlayback? {
            switch self {
            case .idle:
                return nil
            case let .speaking(activePlayback), let .paused(activePlayback):
                return activePlayback
            }
        }

        var currentMessageID: String? {
            activePlayback?.request.messageID
        }

        var isSpeaking: Bool {
            if case .speaking = self {
                return true
            }

            return false
        }

        var isPaused: Bool {
            if case .paused = self {
                return true
            }

            return false
        }
    }

    @ObservationIgnored private let logger = Logger(subsystem: "local.claudecodevoice", category: "Speech")
    @ObservationIgnored private var queuedRequests: [SpeechRequest] = []
    @ObservationIgnored private let avSpeechDriver: any SpeechBackendDriver
    @ObservationIgnored private let systemVoiceDriver: any SpeechBackendDriver
    private var playbackState: PlaybackState = .idle

    var backend: SpeechBackend = .avSpeech {
        didSet {
            guard oldValue != backend else {
                return
            }

            queuedRequests.removeAll()
            stopPlayback(using: driver(for: oldValue))
            playbackState = .idle
        }
    }

    init(
        avSpeechDriver: any SpeechBackendDriver = AVSpeechBackendDriver(),
        systemVoiceDriver: any SpeechBackendDriver = SystemVoiceBackendDriver()
    ) {
        self.avSpeechDriver = avSpeechDriver
        self.systemVoiceDriver = systemVoiceDriver
    }

    var isSpeaking: Bool {
        playbackState.isSpeaking
    }

    var isPaused: Bool {
        playbackState.isPaused
    }

    var currentMessageID: String? {
        playbackState.currentMessageID
    }

    var availableVoices: [SpeechVoiceOption] {
        avSpeechDriver.availableVoices
    }

    var systemVoiceWordsPerMinute: Int {
        systemVoiceDriver.wordsPerMinute ?? 400
    }

    var defaultVoiceIdentifier: String? {
        avSpeechDriver.resolveVoiceIdentifier(nil)
    }

    func resolveVoiceIdentifier(_ identifier: String?) -> String? {
        avSpeechDriver.resolveVoiceIdentifier(identifier)
    }

    func playNow(text: String, messageID: String, voiceIdentifier: String?, rate: Float) {
        let request = SpeechRequest(
            playbackID: UUID(),
            messageID: messageID,
            text: text,
            voiceIdentifier: voiceIdentifier,
            rate: rate
        )

        if playbackState.activePlayback != nil {
            queuedRequests = [request]
            stopPlayback(using: activeDriver ?? currentDriver)
            playbackState = .idle
            playNextQueuedRequestIfNeeded()
            return
        }

        speak(request)
    }

    func enqueue(text: String, messageID: String, voiceIdentifier: String?, rate: Float) {
        let request = SpeechRequest(
            playbackID: UUID(),
            messageID: messageID,
            text: text,
            voiceIdentifier: voiceIdentifier,
            rate: rate
        )

        if playbackState.activePlayback != nil {
            queuedRequests.append(request)
        } else {
            speak(request)
        }
    }

    func pause() {
        activeDriver?.pause()
    }

    func resume() {
        activeDriver?.resume()
    }

    func stop() {
        queuedRequests.removeAll()
        stopPlayback(using: activeDriver ?? currentDriver)
        playbackState = .idle
    }

    private func speak(_ request: SpeechRequest) {
        let driver = currentDriver
        let activePlayback = ActivePlayback(request: request, backend: backend)

        do {
            try driver.start(
                request: request,
                eventHandler: handleDriverEvent(_:)
            )
            playbackState = .speaking(activePlayback)
        } catch {
            logger.error(
                "Playback failed to start for \(request.messageID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            playbackState = .idle
            playNextQueuedRequestIfNeeded()
        }
    }

    private func playNextQueuedRequestIfNeeded() {
        guard !queuedRequests.isEmpty else {
            playbackState = .idle
            return
        }

        let nextRequest = queuedRequests.removeFirst()
        speak(nextRequest)
    }

    private var currentDriver: any SpeechBackendDriver {
        driver(for: backend)
    }

    private var activeDriver: (any SpeechBackendDriver)? {
        guard let activePlayback = playbackState.activePlayback else {
            return nil
        }

        return driver(for: activePlayback.backend)
    }

    private func driver(for backend: SpeechBackend) -> any SpeechBackendDriver {
        switch backend {
        case .avSpeech:
            return avSpeechDriver
        case .systemVoice:
            return systemVoiceDriver
        }
    }

    private func stopPlayback(using driver: any SpeechBackendDriver) {
        driver.stop()
    }

    private func finishCurrentPlayback(playbackID: UUID) {
        guard let activePlayback = playbackState.activePlayback,
              activePlayback.request.playbackID == playbackID else {
            return
        }

        playbackState = .idle
        playNextQueuedRequestIfNeeded()
    }

    private func setPlaybackStateToSpeaking() {
        guard let activePlayback = playbackState.activePlayback else {
            return
        }

        playbackState = .speaking(activePlayback)
    }

    private func setPlaybackStateToPaused() {
        guard let activePlayback = playbackState.activePlayback else {
            return
        }

        playbackState = .paused(activePlayback)
    }

    private func handleDriverEvent(_ event: SpeechDriverEvent) {
        guard let activePlayback = playbackState.activePlayback,
              activePlayback.request.playbackID == event.playbackID else {
            return
        }

        switch event {
        case .didStart, .didResume:
            setPlaybackStateToSpeaking()
        case .didPause:
            setPlaybackStateToPaused()
        case .didFinish:
            finishCurrentPlayback(playbackID: activePlayback.request.playbackID)
        case let .didFail(_, description):
            logger.error(
                "Playback failed for \(activePlayback.request.messageID, privacy: .public): \(description, privacy: .public)"
            )
            finishCurrentPlayback(playbackID: activePlayback.request.playbackID)
        }
    }
}
