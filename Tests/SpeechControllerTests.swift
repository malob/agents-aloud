import Foundation
import Testing
@testable import ClaudeCodeVoice

@MainActor
private final class FakeSpeechBackendDriver: SpeechBackendDriver {
    struct StartFailure: LocalizedError {
        let description: String

        var errorDescription: String? {
            description
        }
    }

    let availableVoices: [SpeechVoiceOption]
    let wordsPerMinute: Int?
    private(set) var startedRequests: [SpeechRequest] = []
    private(set) var pauseCallCount = 0
    private(set) var resumeCallCount = 0
    private(set) var stopCallCount = 0
    var startError: Error?
    private var eventHandler: (@MainActor @Sendable (SpeechDriverEvent) -> Void)?

    init(
        availableVoices: [SpeechVoiceOption] = [],
        wordsPerMinute: Int? = nil
    ) {
        self.availableVoices = availableVoices
        self.wordsPerMinute = wordsPerMinute
    }

    func resolveVoiceIdentifier(_ identifier: String?) -> String? {
        if let identifier {
            return identifier
        }

        return availableVoices.first?.id
    }

    func start(
        request: SpeechRequest,
        eventHandler: @escaping @MainActor @Sendable (SpeechDriverEvent) -> Void
    ) throws {
        if let startError {
            throw startError
        }

        self.eventHandler = eventHandler
        startedRequests.append(request)
    }

    func pause() {
        pauseCallCount += 1
    }

    func resume() {
        resumeCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func emit(_ event: SpeechDriverEvent) {
        eventHandler?(event)
    }
}

@Suite
struct SpeechControllerTests {
    @Test
    @MainActor
    func finishingCurrentPlaybackStartsQueuedRequest() throws {
        let avDriver = FakeSpeechBackendDriver(
            availableVoices: [
                SpeechVoiceOption(
                    id: "voice-1",
                    name: "Voice One",
                    language: "en-US",
                    quality: .default
                )
            ]
        )
        let systemDriver = FakeSpeechBackendDriver(wordsPerMinute: 400)
        let controller = SpeechController(
            avSpeechDriver: avDriver,
            systemVoiceDriver: systemDriver
        )

        controller.playNow(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
        controller.enqueue(text: "Second", messageID: "m2", voiceIdentifier: nil, rate: 0.4)

        #expect(controller.currentMessageID == "m1")
        #expect(avDriver.startedRequests.count == 1)

        let firstPlaybackID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didFinish(firstPlaybackID))

        #expect(controller.currentMessageID == "m2")
        #expect(avDriver.startedRequests.count == 2)
    }

    @Test
    @MainActor
    func playNowInterruptsCurrentPlaybackAndReplacesQueue() {
        let avDriver = FakeSpeechBackendDriver(
            availableVoices: [
                SpeechVoiceOption(
                    id: "voice-1",
                    name: "Voice One",
                    language: "en-US",
                    quality: .default
                )
            ]
        )
        let controller = SpeechController(
            avSpeechDriver: avDriver,
            systemVoiceDriver: FakeSpeechBackendDriver(wordsPerMinute: 400)
        )

        controller.playNow(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
        controller.enqueue(text: "Second", messageID: "m2", voiceIdentifier: nil, rate: 0.4)
        controller.playNow(text: "Third", messageID: "m3", voiceIdentifier: nil, rate: 0.4)

        #expect(avDriver.stopCallCount == 1)
        #expect(avDriver.startedRequests.count == 2)
        #expect(controller.currentMessageID == "m3")
    }

    @Test
    @MainActor
    func driverEventsUpdatePauseAndResumeState() throws {
        let avDriver = FakeSpeechBackendDriver(
            availableVoices: [
                SpeechVoiceOption(
                    id: "voice-1",
                    name: "Voice One",
                    language: "en-US",
                    quality: .default
                )
            ]
        )
        let controller = SpeechController(
            avSpeechDriver: avDriver,
            systemVoiceDriver: FakeSpeechBackendDriver(wordsPerMinute: 400)
        )

        controller.playNow(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
        let playbackID = try #require(avDriver.startedRequests.first?.playbackID)

        controller.pause()
        #expect(avDriver.pauseCallCount == 1)
        avDriver.emit(.didPause(playbackID))
        #expect(controller.isPaused)

        controller.resume()
        #expect(avDriver.resumeCallCount == 1)
        avDriver.emit(.didResume(playbackID))
        #expect(controller.isSpeaking)
        #expect(!controller.isPaused)
    }

    @Test
    @MainActor
    func switchingBackendsStopsThePreviouslyActiveDriver() {
        let avDriver = FakeSpeechBackendDriver(
            availableVoices: [
                SpeechVoiceOption(
                    id: "voice-1",
                    name: "Voice One",
                    language: "en-US",
                    quality: .default
                )
            ]
        )
        let systemDriver = FakeSpeechBackendDriver(wordsPerMinute: 400)
        let controller = SpeechController(
            avSpeechDriver: avDriver,
            systemVoiceDriver: systemDriver
        )

        controller.playNow(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
        controller.backend = .systemVoice

        #expect(avDriver.stopCallCount == 1)
        #expect(systemDriver.stopCallCount == 0)
        #expect(controller.currentMessageID == nil)
    }

    @Test
    @MainActor
    func startFailureSurfacesPlaybackError() {
        let avDriver = FakeSpeechBackendDriver(
            availableVoices: [
                SpeechVoiceOption(
                    id: "voice-1",
                    name: "Voice One",
                    language: "en-US",
                    quality: .default
                )
            ]
        )
        avDriver.startError = FakeSpeechBackendDriver.StartFailure(description: "Voice not available")
        let controller = SpeechController(
            avSpeechDriver: avDriver,
            systemVoiceDriver: FakeSpeechBackendDriver(wordsPerMinute: 400)
        )

        controller.playNow(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)

        #expect(controller.currentMessageID == nil)
        #expect(controller.playbackError?.message == "Voice not available")
    }

    @Test
    @MainActor
    func driverFailureSurfacesPlaybackErrorAndAdvancesQueue() throws {
        let avDriver = FakeSpeechBackendDriver(
            availableVoices: [
                SpeechVoiceOption(
                    id: "voice-1",
                    name: "Voice One",
                    language: "en-US",
                    quality: .default
                )
            ]
        )
        let controller = SpeechController(
            avSpeechDriver: avDriver,
            systemVoiceDriver: FakeSpeechBackendDriver(wordsPerMinute: 400)
        )

        controller.playNow(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
        controller.enqueue(text: "Second", messageID: "m2", voiceIdentifier: nil, rate: 0.4)

        let firstPlaybackID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didFail(firstPlaybackID, description: "Playback failed."))

        #expect(controller.playbackError?.message == "Playback failed.")
        #expect(controller.currentMessageID == "m2")
        #expect(avDriver.startedRequests.count == 2)
    }

    @Test
    @MainActor
    func staleEventsAreIgnoredAfterPlaybackReplacement() throws {
        let avDriver = FakeSpeechBackendDriver(
            availableVoices: [
                SpeechVoiceOption(
                    id: "voice-1",
                    name: "Voice One",
                    language: "en-US",
                    quality: .default
                )
            ]
        )
        let controller = SpeechController(
            avSpeechDriver: avDriver,
            systemVoiceDriver: FakeSpeechBackendDriver(wordsPerMinute: 400)
        )

        controller.playNow(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
        let firstPlaybackID = try #require(avDriver.startedRequests.first?.playbackID)

        controller.playNow(text: "Second", messageID: "m2", voiceIdentifier: nil, rate: 0.4)
        let secondPlaybackID = try #require(avDriver.startedRequests.last?.playbackID)

        avDriver.emit(.didFinish(firstPlaybackID))

        #expect(controller.currentMessageID == "m2")

        avDriver.emit(.didFinish(secondPlaybackID))

        #expect(controller.currentMessageID == nil)
    }
}
