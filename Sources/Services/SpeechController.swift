import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class SpeechController {
    struct PlaybackError: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

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
    @ObservationIgnored private var playbackErrorDismissTask: Task<Void, Never>?
    @ObservationIgnored private let avSpeechDriver: any SpeechBackendDriver
    @ObservationIgnored private let systemVoiceDriver: any SpeechBackendDriver
    @ObservationIgnored let elevenLabsDriver: ElevenLabsBackendDriver
    private var playbackState: PlaybackState = .idle

    var backend: SpeechBackend = .avSpeech {
        didSet {
            guard oldValue != backend else {
                return
            }

            queuedRequests.removeAll()
            driver(for: oldValue).stop()
            playbackState = .idle
        }
    }

    init(
        avSpeechDriver: any SpeechBackendDriver = AVSpeechBackendDriver(),
        systemVoiceDriver: any SpeechBackendDriver = SystemVoiceBackendDriver(),
        elevenLabsDriver: ElevenLabsBackendDriver = ElevenLabsBackendDriver(
            client: ElevenLabsClient(apiKey: "")
        )
    ) {
        self.avSpeechDriver = avSpeechDriver
        self.systemVoiceDriver = systemVoiceDriver
        self.elevenLabsDriver = elevenLabsDriver
    }

    deinit {
        playbackErrorDismissTask?.cancel()
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

    // Voice list is backend-scoped — AVSpeech voices and ElevenLabs voices
    // are disjoint ID spaces. Callers read this reactively (the Settings
    // picker binds to it), so whenever `backend` changes this returns the
    // right set automatically.
    var availableVoices: [SpeechVoiceOption] {
        driver(for: backend).availableVoices
    }

    var systemVoiceWordsPerMinute: Int {
        systemVoiceDriver.wordsPerMinute ?? 400
    }

    var defaultVoiceIdentifier: String? {
        driver(for: backend).resolveVoiceIdentifier(nil)
    }

    var playbackError: PlaybackError?

    func resolveVoiceIdentifier(_ identifier: String?) -> String? {
        driver(for: backend).resolveVoiceIdentifier(identifier)
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
            (activeDriver ?? currentDriver).stop()
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
        (activeDriver ?? currentDriver).stop()
        playbackState = .idle
    }

    func dismissPlaybackError() {
        clearPlaybackError()
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
            showPlaybackError(error.localizedDescription)
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
        case .elevenLabs:
            return elevenLabsDriver
        }
    }

    private func showPlaybackError(_ message: String) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            return
        }

        playbackErrorDismissTask?.cancel()
        let playbackError = PlaybackError(message: trimmedMessage)
        self.playbackError = playbackError
        playbackErrorDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.playbackError?.id == playbackError.id else {
                return
            }

            self.playbackError = nil
        }
    }

    private func clearPlaybackError() {
        playbackErrorDismissTask?.cancel()
        playbackErrorDismissTask = nil
        playbackError = nil
    }

    private func finishCurrentPlayback(playbackID: UUID) {
        guard let activePlayback = playbackState.activePlayback,
              activePlayback.request.playbackID == playbackID else {
            return
        }

        playbackState = .idle
        playNextQueuedRequestIfNeeded()
    }

    private func handleDriverEvent(_ event: SpeechDriverEvent) {
        guard let activePlayback = playbackState.activePlayback,
              activePlayback.request.playbackID == event.playbackID else {
            return
        }

        switch event {
        case .didStart:
            clearPlaybackError()
            playbackState = .speaking(activePlayback)
        case .didResume:
            playbackState = .speaking(activePlayback)
        case .didPause:
            playbackState = .paused(activePlayback)
        case .didFinish:
            finishCurrentPlayback(playbackID: activePlayback.request.playbackID)
        case let .didFail(_, description):
            logger.error(
                "Playback failed for \(activePlayback.request.messageID, privacy: .public): \(description, privacy: .public)"
            )
            showPlaybackError(description)
            finishCurrentPlayback(playbackID: activePlayback.request.playbackID)
        }
    }
}
