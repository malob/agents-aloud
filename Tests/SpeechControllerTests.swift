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

        controller.playNext(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
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
    func playNextWhileSpeakingQueuesAtHeadWithoutInterrupting() throws {
        // New semantic: clicking Speak on a message while another is
        // playing puts the clicked message next in line, but DOES NOT
        // cut off the current utterance or drop existing queued items.
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

        controller.playNext(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
        controller.enqueue(text: "Second", messageID: "m2", voiceIdentifier: nil, rate: 0.4)
        // While m1 is speaking and m2 is queued, playNext(m3) should
        // insert m3 at the head of the queue — NOT interrupt m1 or
        // drop m2.
        controller.playNext(text: "Third", messageID: "m3", voiceIdentifier: nil, rate: 0.4)

        #expect(avDriver.stopCallCount == 0)
        #expect(avDriver.startedRequests.count == 1)
        #expect(controller.currentMessageID == "m1")

        // When m1 finishes, m3 plays next — before m2, which was
        // enqueued earlier.
        let firstPlaybackID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didFinish(firstPlaybackID))

        #expect(controller.currentMessageID == "m3")
        #expect(avDriver.startedRequests.count == 2)

        // And after m3 finishes, m2 still plays — the original queued
        // item wasn't lost.
        let thirdPlaybackID = try #require(avDriver.startedRequests.last?.playbackID)
        avDriver.emit(.didFinish(thirdPlaybackID))

        #expect(controller.currentMessageID == "m2")
        #expect(avDriver.startedRequests.count == 3)
    }

    @Test
    @MainActor
    func insertAfterThreadsRequestIntoSequencePosition() throws {
        // Drives playMessagesFromHere's contiguous-sequence guarantee:
        // when the user hits Speak from Here with other items already
        // queued, the sequence should stay contiguous instead of letting
        // prior queue items sneak between its messages.
        let avDriver = FakeSpeechBackendDriver(
            availableVoices: [
                SpeechVoiceOption(id: "voice-1", name: "Voice One", language: "en-US", quality: .default)
            ]
        )
        let controller = SpeechController(
            avSpeechDriver: avDriver,
            systemVoiceDriver: FakeSpeechBackendDriver(wordsPerMinute: 400)
        )

        // Simulate Live Speak state: m1 playing, [X] queued.
        controller.playNext(text: "M1", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
        controller.enqueue(text: "X", messageID: "x", voiceIdentifier: nil, rate: 0.4)

        // User's "Speak from Here" sequence: playNext(B), insertAfter(B → C),
        // insertAfter(C → D). Expected final order: m1 (playing), B, C, D, X.
        controller.playNext(text: "B", messageID: "b", voiceIdentifier: nil, rate: 0.4)
        controller.insertAfter(priorMessageID: "b", text: "C", messageID: "c", voiceIdentifier: nil, rate: 0.4)
        controller.insertAfter(priorMessageID: "c", text: "D", messageID: "d", voiceIdentifier: nil, rate: 0.4)

        #expect(controller.currentMessageID == "m1")

        let playbackIDs = avDriver.startedRequests.map(\.playbackID)
        avDriver.emit(.didFinish(try #require(playbackIDs.first)))
        #expect(controller.currentMessageID == "b")

        avDriver.emit(.didFinish(try #require(avDriver.startedRequests.last?.playbackID)))
        #expect(controller.currentMessageID == "c")

        avDriver.emit(.didFinish(try #require(avDriver.startedRequests.last?.playbackID)))
        #expect(controller.currentMessageID == "d")

        avDriver.emit(.didFinish(try #require(avDriver.startedRequests.last?.playbackID)))
        #expect(controller.currentMessageID == "x")
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

        controller.playNext(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
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

        controller.playNext(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
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

        controller.playNext(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)

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

        controller.playNext(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
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

        controller.playNext(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
        controller.enqueue(text: "Second", messageID: "m2", voiceIdentifier: nil, rate: 0.4)
        controller.stop()

        let firstPlaybackID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didFinish(firstPlaybackID))

        #expect(avDriver.startedRequests.count == 1)
        #expect(controller.currentMessageID == nil)
    }

    @Test
    @MainActor
    func playNextWhilePausedInterruptsAndRestartsPlayback() throws {
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

        controller.playNext(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
        let firstPlaybackID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didPause(firstPlaybackID))

        controller.playNext(text: "Replacement", messageID: "m2", voiceIdentifier: nil, rate: 0.5)

        #expect(avDriver.stopCallCount == 1)
        #expect(avDriver.startedRequests.count == 2)
        #expect(controller.currentMessageID == "m2")
    }

    @Test
    @MainActor
    func staleEventsAreIgnoredAfterPlaybackReplacement() throws {
        // Stale event here means: a driver fires didFinish for a
        // playback that's no longer current (e.g. stopped by the user
        // before the driver noticed, or a paused utterance that got
        // replaced by a fresh playNext). The controller must reject
        // the stale ID so a late callback can't bounce state to idle.
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

        controller.playNext(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
        let firstPlaybackID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didPause(firstPlaybackID))

        // playNext-while-paused replaces the paused utterance. The old
        // playback ID is now stale; a late didFinish for it should be
        // ignored rather than clobbering the new playback.
        controller.playNext(text: "Second", messageID: "m2", voiceIdentifier: nil, rate: 0.4)
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

        controller.playNext(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
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
        controller.playNext(text: "First", messageID: "m1", voiceIdentifier: nil, rate: 0.4)
        let playbackID = try #require(avDriver.startedRequests.first?.playbackID)

        avDriver.emit(.didStart(playbackID))

        #expect(controller.playbackError == nil)
    }

    @Test
    @MainActor
    func playNextPassesRateAndVoiceIdentifierToDriver() {
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

        controller.playNext(text: "First", messageID: "m1", voiceIdentifier: "voice-1", rate: 0.4)

        #expect(avDriver.startedRequests.first?.voiceIdentifier == "voice-1")
        #expect(avDriver.startedRequests.first?.rate == 0.4)
    }
}
