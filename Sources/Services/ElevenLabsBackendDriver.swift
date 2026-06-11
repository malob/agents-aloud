import Foundation
import Observation
import OSLog

// SpeechBackendDriver over ElevenLabs' streaming TTS API. Architecture:
//
//   start() -> client.streamSynthesize() -> AsyncThrowingStream<Data> ->
//              StreamingAudioPlayer -> AVAudioEngine -> speakers
//
// The driver is the glue; the client handles HTTP, the player handles
// audio. Each plays one utterance at a time; when that finishes (or
// errors), the driver emits the corresponding SpeechDriverEvent so the
// shared SpeechController can advance its queue / update playback state.
//
// `.didStart` fires synchronously at `start()` time rather than at
// first-audio — gives the UI an immediate "speaking" signal on
// button-click; the ~200-500ms gap before first byte plays is the
// inherent cost of a network TTS backend.
// @Observable so `availableVoices` changes (populated async via
// `refreshVoices()` after an API key is entered) trigger SwiftUI
// re-renders wherever they're read through the `SpeechController`
// facade.
@MainActor
@Observable
final class ElevenLabsBackendDriver: SpeechBackendDriver {
    static let defaultModelID = "eleven_turbo_v2_5"

    // var because AppModel swaps it via replaceClient() when the API key changes.
    @ObservationIgnored private var client: ElevenLabsClientType
    @ObservationIgnored private let player: StreamingAudioPlayer
    @ObservationIgnored private let modelID: String
    @ObservationIgnored private let logger = Logger(subsystem: "local.claudecodevoice", category: "ElevenLabsDriver")

    private(set) var availableVoices: [SpeechVoiceOption] = []

    // Active playback — the pair of (request, event handler) must move
    // together: non-nil when a stream is playing, nil between calls. A
    // single optional prevents the "cleared one, forgot the other" class
    // of bug across start/stop/finish/error paths.
    private struct Active {
        let request: SpeechRequest
        let eventHandler: @MainActor @Sendable (SpeechDriverEvent) -> Void
    }
    @ObservationIgnored private var active: Active?

    enum DriverError: LocalizedError, Equatable {
        case noVoiceSelected

        var errorDescription: String? {
            switch self {
            case .noVoiceSelected:
                return "No ElevenLabs voice selected. Pick one in Settings."
            }
        }
    }

    init(
        client: ElevenLabsClientType,
        player: StreamingAudioPlayer = StreamingAudioPlayer(),
        modelID: String = ElevenLabsBackendDriver.defaultModelID
    ) {
        self.client = client
        self.player = player
        self.modelID = modelID
    }

    // Re-fetches the voice list from ElevenLabs. Called by AppModel when
    // the API key is (re-)entered or on app launch if a key is stored.
    // On error, clears availableVoices and rethrows so the caller can
    // surface the failure (AppModel puts it in the error banner when
    // ElevenLabs is the active backend).
    func refreshVoices() async throws {
        do {
            let voices = try await client.listVoices()
            availableVoices = voices.map { voice in
                SpeechVoiceOption(
                    id: voice.voiceID,
                    name: voice.name,
                    language: "en-US"
                )
            }
            logger.info("Loaded \(self.availableVoices.count, privacy: .public) ElevenLabs voices")
        } catch {
            logger.error("Failed to list ElevenLabs voices: \(error.localizedDescription, privacy: .public)")
            availableVoices = []
            throw error
        }
    }

    func replaceClient(_ client: ElevenLabsClientType) {
        stop()
        self.client = client
        availableVoices = []
    }

    func resolveVoiceIdentifier(_ identifier: String?) -> String? {
        if let identifier, availableVoices.contains(where: { $0.id == identifier }) {
            return identifier
        }
        return availableVoices.first?.id
    }

    func start(
        request: SpeechRequest,
        eventHandler: @escaping @MainActor @Sendable (SpeechDriverEvent) -> Void
    ) throws {
        guard let voiceID = request.voiceIdentifier?.nilIfEmpty else {
            throw DriverError.noVoiceSelected
        }

        // Anything currently playing for an older request is cancelled.
        // SpeechController already calls stop() before a fresh start(),
        // but be defensive: we never want two utterances overlapping.
        player.stop()

        active = Active(request: request, eventHandler: eventHandler)

        let stream = client.streamSynthesize(
            voiceID: voiceID,
            text: request.text,
            speed: Self.naturalGenerationSpeed,
            modelID: modelID
        )

        do {
            try player.play(
                stream: stream,
                sampleRate: ElevenLabsClient.pcmSampleRate,
                rate: Self.playbackRate(wordsPerMinute: request.wordsPerMinute),
                onFinish: { [weak self] in
                    self?.handleFinish(for: request.playbackID)
                },
                onError: { [weak self] error in
                    self?.handleError(error, for: request.playbackID)
                }
            )
        } catch {
            active = nil
            throw error
        }

        eventHandler(.didStart(request.playbackID))
    }

    func pause() {
        guard let active else { return }
        player.pause()
        active.eventHandler(.didPause(active.request.playbackID))
    }

    func resume() {
        guard let active else { return }
        player.resume()
        active.eventHandler(.didResume(active.request.playbackID))
    }

    func stop() {
        player.stop()
        active = nil
    }

    // MARK: -

    private func handleFinish(for playbackID: UUID) {
        guard let active, active.request.playbackID == playbackID else { return }
        let handler = active.eventHandler
        self.active = nil
        handler(.didFinish(playbackID))
    }

    private func handleError(_ error: Error, for playbackID: UUID) {
        guard let active, active.request.playbackID == playbackID else { return }
        let handler = active.eventHandler
        self.active = nil
        handler(.didFail(playbackID, description: error.localizedDescription))
    }

    // Generation speed is pinned to ElevenLabs' natural pace; the WPM
    // slider is honored at PLAYBACK time by StreamingAudioPlayer's
    // time-pitch stage instead. voice_settings.speed only accepts
    // 0.7–1.2 (anything outside is a 400), which capped audible speed
    // at ~1.2× — far below the slider's ceiling and useless for fast
    // listeners. Squeezing prosody at generation time also degrades
    // delivery; stretching at playback keeps the performance natural
    // and works across the whole range.
    nonisolated static let naturalGenerationSpeed = 1.0

    // Convert the slider's words-per-minute into a playback-rate
    // multiplier. 175 wpm approximates ElevenLabs voices' natural pace
    // at speed 1.0, so slider position ≈ audible wpm — the same unit
    // semantics as `say -r` on the SystemVoice backend. The player
    // clamps the result to its supported range.
    nonisolated static func playbackRate(wordsPerMinute: Int) -> Double {
        Double(wordsPerMinute) / 175.0
    }
}

