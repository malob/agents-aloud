import Foundation
import Testing
@testable import ClaudeCodeVoice

@Suite
struct SpeechControllerTests {
    @Test
    @MainActor
    func enqueueOnIdleStartsPlaybackImmediately() {
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

        controller.enqueue(text: "Queued first", messageID: "m1", voiceIdentifier: "voice-1", rate: 0.4)

        #expect(avDriver.startedRequests.count == 1)
        #expect(avDriver.startedRequests.first?.messageID == "m1")
    }

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
    func stopClearsQueuedRequests() throws {
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
        controller.stop()

        let firstPlaybackID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didFinish(firstPlaybackID))

        #expect(avDriver.startedRequests.count == 1)
        #expect(controller.currentMessageID == nil)
    }

    @Test
    @MainActor
    func playNowWhilePausedInterruptsAndRestartsPlayback() throws {
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
        avDriver.emit(.didPause(firstPlaybackID))

        controller.playNow(text: "Replacement", messageID: "m2", voiceIdentifier: nil, rate: 0.5)

        #expect(avDriver.stopCallCount == 1)
        #expect(avDriver.startedRequests.count == 2)
        #expect(controller.currentMessageID == "m2")
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

    @Test
    @MainActor
    func dismissPlaybackErrorClearsToast() {
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
        controller.dismissPlaybackError()

        #expect(controller.playbackError == nil)
    }

    @Test
    @MainActor
    func didStartClearsPreviousPlaybackError() throws {
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

        controller.playbackError = SpeechController.PlaybackError(message: "Old error")
        controller.playNow(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
        let playbackID = try #require(avDriver.startedRequests.first?.playbackID)

        avDriver.emit(.didStart(playbackID))

        #expect(controller.playbackError == nil)
    }

    @Test
    @MainActor
    func playNowPassesRateAndVoiceIdentifierToDriver() {
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

        controller.playNow(text: "First", messageID: "m1", voiceIdentifier: "voice-1", rate: 0.4)

        #expect(avDriver.startedRequests.first?.voiceIdentifier == "voice-1")
        #expect(avDriver.startedRequests.first?.rate == 0.4)
    }
}
