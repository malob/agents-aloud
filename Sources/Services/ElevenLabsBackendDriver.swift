import AVFoundation
import Foundation
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
// `.didStart` fires synchronously at `start()` time (same as
// AVSpeechBackendDriver's pattern) rather than at first-audio. That
// gives the UI an immediate "speaking" signal on button-click; the
// ~200-500ms gap before first byte plays is the inherent cost of a
// network TTS backend.
@MainActor
final class ElevenLabsBackendDriver: SpeechBackendDriver {
    static let defaultModelID = "eleven_turbo_v2_5"

    private let client: ElevenLabsClientType
    private let player: StreamingAudioPlayer
    private let modelID: String
    private let logger = Logger(subsystem: "local.claudecodevoice", category: "ElevenLabsDriver")

    private(set) var availableVoices: [SpeechVoiceOption] = []
    var wordsPerMinute: Int? { nil }

    private var currentRequest: SpeechRequest?
    private var currentEventHandler: ((SpeechDriverEvent) -> Void)?

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

    // Re-fetches the voice list from ElevenLabs. Intended to be called
    // by AppModel when the API key is (re-)entered or on app launch if
    // a key is already stored. Silent-fails to an empty list on error
    // so the picker still shows something (a "type a voice ID" affordance
    // can live in Settings for the failure case).
    func refreshVoices() async {
        do {
            let voices = try await client.listVoices()
            availableVoices = voices.map { voice in
                SpeechVoiceOption(
                    id: voice.voiceID,
                    name: voice.name,
                    language: "en-US",
                    quality: .enhanced
                )
            }
            logger.info("Loaded \(self.availableVoices.count, privacy: .public) ElevenLabs voices")
        } catch {
            logger.error("Failed to list ElevenLabs voices: \(error.localizedDescription, privacy: .public)")
            availableVoices = []
        }
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
        guard let voiceID = request.voiceIdentifier?.nonEmpty else {
            throw DriverError.noVoiceSelected
        }

        // Anything currently playing for an older request is cancelled.
        // SpeechController already calls stop() before a fresh start(),
        // but be defensive: we never want two utterances overlapping.
        player.stop()

        currentRequest = request
        currentEventHandler = eventHandler

        let speed = Self.mapRateToSpeed(request.rate)
        let stream = client.streamSynthesize(
            voiceID: voiceID,
            text: request.text,
            speed: speed,
            modelID: modelID
        )

        do {
            try player.play(
                stream: stream,
                sampleRate: ElevenLabsClient.pcmSampleRate,
                onFinish: { [weak self] in
                    self?.handleFinish(for: request.playbackID)
                },
                onError: { [weak self] error in
                    self?.handleError(error, for: request.playbackID)
                }
            )
        } catch {
            currentRequest = nil
            currentEventHandler = nil
            throw error
        }

        eventHandler(.didStart(request.playbackID))
    }

    func pause() {
        guard let request = currentRequest else { return }
        player.pause()
        currentEventHandler?(.didPause(request.playbackID))
    }

    func resume() {
        guard let request = currentRequest else { return }
        player.resume()
        currentEventHandler?(.didResume(request.playbackID))
    }

    func stop() {
        player.stop()
        currentRequest = nil
        currentEventHandler = nil
    }

    // MARK: -

    private func handleFinish(for playbackID: UUID) {
        guard currentRequest?.playbackID == playbackID else { return }
        let handler = currentEventHandler
        currentRequest = nil
        currentEventHandler = nil
        handler?(.didFinish(playbackID))
    }

    private func handleError(_ error: Error, for playbackID: UUID) {
        guard currentRequest?.playbackID == playbackID else { return }
        let handler = currentEventHandler
        currentRequest = nil
        currentEventHandler = nil
        handler?(.didFail(playbackID, description: error.localizedDescription))
    }

    // Maps our 0.2-0.6 speech rate slider (AVSpeech-calibrated, middle ~=
    // AVSpeechUtteranceDefaultSpeechRate) onto ElevenLabs' 0.5-2.0 speed
    // scale. Linear; slider at rest feels like "slightly quick" per
    // ElevenLabs conventions, which testing has found preferable.
    nonisolated static func mapRateToSpeed(_ rate: Float) -> Double {
        let t = (Double(rate) - 0.2) / (0.6 - 0.2)
        return max(0.5, min(2.0, 0.5 + t * 1.5))
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
