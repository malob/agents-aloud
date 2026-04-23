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

    // PlaybackState fuses "what's playing" with "what's queued behind it".
    // Previously the queue was a free-standing field whose invariant ("empty
    // when idle") was convention-enforced across many callers. Bundling the
    // queue into the non-idle cases makes the invariant structural, and
    // transitions through helper mutators keep it correct without caller
    // ceremony.
    private enum PlaybackState {
        case idle
        case speaking(ActivePlayback, queue: [SpeechRequest])
        case paused(ActivePlayback, queue: [SpeechRequest])

        var activePlayback: ActivePlayback? {
            switch self {
            case .idle:
                return nil
            case let .speaking(activePlayback, _), let .paused(activePlayback, _):
                return activePlayback
            }
        }

        var queue: [SpeechRequest] {
            switch self {
            case .idle:
                return []
            case let .speaking(_, queue), let .paused(_, queue):
                return queue
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

        // Replace the queue on the active state; no-op on .idle (idle has
        // no queue by construction).
        mutating func setQueue(_ newQueue: [SpeechRequest]) {
            switch self {
            case .idle:
                return
            case let .speaking(active, _):
                self = .speaking(active, queue: newQueue)
            case let .paused(active, _):
                self = .paused(active, queue: newQueue)
            }
        }

        // Remove and return the first queued request, if any.
        mutating func popQueue() -> SpeechRequest? {
            var current = queue
            guard !current.isEmpty else { return nil }
            let first = current.removeFirst()
            setQueue(current)
            return first
        }
    }

    @ObservationIgnored private let logger = Logger(subsystem: "local.claudecodevoice", category: "Speech")
    @ObservationIgnored private var playbackErrorDismissTask: Task<Void, Never>?
    @ObservationIgnored private let avSpeechDriver: any SpeechBackendDriver
    @ObservationIgnored private let systemVoiceDriver: any SpeechBackendDriver
    // Not @ObservationIgnored: the ElevenLabs driver is @Observable, and
    // `availableVoices` reads through this stored property. Keeping the
    // property observable lets SwiftUI propagate voice-list refreshes
    // (populated async after the API key is entered) to Settings' picker.
    let elevenLabsDriver: ElevenLabsBackendDriver
    private var playbackState: PlaybackState = .idle

    var backend: SpeechBackend = .avSpeech {
        didSet {
            guard oldValue != backend else {
                return
            }

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

    // "Play this message next." Semantics depend on current state:
    //
    //  - idle → speak immediately (nothing to wait behind)
    //  - speaking → insert at the head of the queue, DON'T interrupt
    //    the active utterance. The user's click means "play this next,"
    //    not "stop everything." Stop/Pause exist for the full-stop
    //    intent. This preserves both narrative continuity of what's
    //    currently being read AND anything Live Speak had queued up
    //    behind it (those items stay in the queue after the new one).
    //  - paused → the current utterance is parked and the user isn't
    //    actively listening. A fresh "play this" click is a clear
    //    start-over intent, so drop the paused state and speak.
    func playNext(text: String, messageID: String, voiceIdentifier: String?, rate: Float) {
        let request = SpeechRequest(
            playbackID: UUID(),
            messageID: messageID,
            text: text,
            voiceIdentifier: voiceIdentifier,
            rate: rate
        )

        if playbackState.isPaused {
            (activeDriver ?? currentDriver).stop()
            playbackState = .idle
            speak(request)
            return
        }

        if playbackState.isSpeaking {
            playbackState.setQueue([request] + playbackState.queue)
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
            playbackState.setQueue(playbackState.queue + [request])
        } else {
            speak(request)
        }
    }

    // Insert `request` immediately after `priorMessageID` in the play
    // order. Used by playMessagesFromHere so a batch of messages
    // ({B, C, D}) stays contiguous even when there's a pre-existing
    // queue — without this, each call to enqueue would append at the
    // back, letting earlier-queued items (Live Speak arrivals, etc.)
    // slip between B and C.
    //
    // Placement cascade:
    //  - priorMessageID is the currently-playing message → head of queue
    //  - priorMessageID is in the queue → insert right after it
    //  - priorMessageID not found (prior already finished and rolled off)
    //    → head of queue, as the closest thing to "next in the sequence"
    func insertAfter(priorMessageID: String, text: String, messageID: String, voiceIdentifier: String?, rate: Float) {
        let request = SpeechRequest(
            playbackID: UUID(),
            messageID: messageID,
            text: text,
            voiceIdentifier: voiceIdentifier,
            rate: rate
        )

        guard playbackState.activePlayback != nil else {
            speak(request)
            return
        }

        if playbackState.currentMessageID == priorMessageID {
            playbackState.setQueue([request] + playbackState.queue)
            return
        }

        var newQueue = playbackState.queue
        if let index = newQueue.firstIndex(where: { $0.messageID == priorMessageID }) {
            newQueue.insert(request, at: index + 1)
        } else {
            newQueue.insert(request, at: 0)
        }
        playbackState.setQueue(newQueue)
    }

    func pause() {
        activeDriver?.pause()
    }

    func resume() {
        activeDriver?.resume()
    }

    func stop() {
        (activeDriver ?? currentDriver).stop()
        playbackState = .idle
    }

    // Drop anything queued but let the current utterance finish on its own.
    // Used when the user disables Live Speak mid-playback — honors the help
    // text promise that no new messages will be spoken without cutting off
    // whatever's currently being read.
    func drainQueue() {
        playbackState.setQueue([])
    }

    func dismissPlaybackError() {
        playbackErrorDismissTask?.cancel()
        playbackErrorDismissTask = nil
        playbackError = nil
    }

    // `queue` is the set of requests to run after `request` finishes. Passed
    // explicitly rather than read from playbackState so the caller controls
    // whether to preserve existing queue (e.g. on didFinish, pop next +
    // carry the tail) or drop it (playNow explicitly replaces).
    private func speak(_ request: SpeechRequest, queue: [SpeechRequest] = []) {
        let driver = currentDriver
        let activePlayback = ActivePlayback(request: request, backend: backend)

        do {
            try driver.start(
                request: request,
                eventHandler: handleDriverEvent(_:)
            )
            playbackState = .speaking(activePlayback, queue: queue)
        } catch {
            logger.error(
                "Playback failed to start for \(request.messageID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            showPlaybackError(error.localizedDescription)
            playbackState = .idle
            // Failure drops the current attempt; try draining the next queued
            // request instead of leaving the rest of the queue stranded.
            if let next = queue.first {
                speak(next, queue: Array(queue.dropFirst()))
            }
        }
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

    private func finishCurrentPlayback(playbackID: UUID) {
        guard let activePlayback = playbackState.activePlayback,
              activePlayback.request.playbackID == playbackID else {
            return
        }

        // Capture the queue BEFORE clearing state; .idle has no queue
        // by construction so reading playbackState.queue afterward gives [].
        let remainingQueue = playbackState.queue
        playbackState = .idle
        if let next = remainingQueue.first {
            speak(next, queue: Array(remainingQueue.dropFirst()))
        }
    }

    private func handleDriverEvent(_ event: SpeechDriverEvent) {
        guard let activePlayback = playbackState.activePlayback,
              activePlayback.request.playbackID == event.playbackID else {
            return
        }

        let currentQueue = playbackState.queue
        switch event {
        case .didStart:
            dismissPlaybackError()
            playbackState = .speaking(activePlayback, queue: currentQueue)
        case .didResume:
            playbackState = .speaking(activePlayback, queue: currentQueue)
        case .didPause:
            playbackState = .paused(activePlayback, queue: currentQueue)
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
