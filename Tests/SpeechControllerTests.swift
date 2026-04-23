import Foundation
import Testing
@testable import ClaudeCodeVoice

// Helper: build a controller with a fake AV driver + an optional
// controllable processor. Default is passthrough so tests that
// don't care about rewrite timing get near-instant .ready items
// (still one Task-yield away from synchronous).
@MainActor
private func makeController(
    processor: any SpeechTextProcessor = PassthroughSpeechProcessor()
) -> (controller: SpeechController, avDriver: FakeSpeechBackendDriver) {
    let avDriver = FakeSpeechBackendDriver(
        availableVoices: [
            SpeechVoiceOption(id: "voice-1", name: "Voice One", language: "en-US", quality: .default)
        ]
    )
    let controller = SpeechController(
        avSpeechDriver: avDriver,
        systemVoiceDriver: FakeSpeechBackendDriver(wordsPerMinute: 400),
        speechTextProcessor: processor
    )
    return (controller, avDriver)
}

@Suite
struct SpeechControllerTests {

    // MARK: - Basic playback via insertAuto / insertManual

    @Test
    @MainActor
    func insertAutoOnIdleStartsPlaybackAfterRewriteCompletes() async throws {
        let (controller, avDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "Queued first", voiceIdentifier: "voice-1", rate: 0.4, sessionID: "s")

        // Passthrough rewrite lands via a Task hop — wait for it.
        try await waitUntil { controller.currentMessageID == "m1" }
        #expect(avDriver.startedRequests.count == 1)
        #expect(avDriver.startedRequests.first?.messageID == "m1")
    }

    @Test
    @MainActor
    func finishingCurrentPlaybackAdvancesToNext() async throws {
        let (controller, avDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        controller.insertAuto(messageID: "m2", sourceText: "Second", voiceIdentifier: nil, rate: 0.4, sessionID: "s")

        try await waitUntil { controller.currentMessageID == "m1" }
        try await waitUntil { controller.queue.first?.id == "m2" && controller.queue.first?.readyText != nil }

        let firstPlaybackID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didFinish(firstPlaybackID))

        try await waitUntil { controller.currentMessageID == "m2" }
        #expect(avDriver.startedRequests.count == 2)
    }

    // MARK: - Manual vs Auto insert ordering

    @Test
    @MainActor
    func manualInsertGoesAfterLastManualItem() async throws {
        let (controller, avDriver) = makeController()

        // m1 starts playing (manual, idle → speak).
        controller.insertManual(messageID: "m1", sourceText: "M1", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }

        // Live Speak queues X, Y behind m1.
        controller.insertAuto(messageID: "x", sourceText: "X", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        controller.insertAuto(messageID: "y", sourceText: "Y", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        // User clicks Speak on m2 — lands before x, y (manual beats
        // auto) but after m1 (playhead).
        controller.insertManual(messageID: "m2", sourceText: "M2", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        // m3 manual — after m2 (FIFO among manual clicks).
        controller.insertManual(messageID: "m3", sourceText: "M3", voiceIdentifier: nil, rate: 0.4, sessionID: "s")

        #expect(controller.queue.map(\.id) == ["m2", "m3", "x", "y"])

        let m1ID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didFinish(m1ID))
        try await waitUntil { controller.currentMessageID == "m2" }
    }

    @Test
    @MainActor
    func manualSequenceStaysContiguous() async throws {
        let (controller, avDriver) = makeController()

        controller.insertManual(messageID: "m1", sourceText: "M1", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        controller.insertAuto(messageID: "x", sourceText: "X", voiceIdentifier: nil, rate: 0.4, sessionID: "s")

        // Speak from Here on {b, c, d} — sequence goes after the last
        // manual (m1, playing) and ahead of x.
        controller.insertManualSequence([
            (messageID: "b", sourceText: "B", voiceIdentifier: nil, rate: 0.4, sessionID: "s"),
            (messageID: "c", sourceText: "C", voiceIdentifier: nil, rate: 0.4, sessionID: "s"),
            (messageID: "d", sourceText: "D", voiceIdentifier: nil, rate: 0.4, sessionID: "s"),
        ])

        #expect(controller.queue.map(\.id) == ["b", "c", "d", "x"])

        let m1ID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didFinish(m1ID))
        try await waitUntil { controller.currentMessageID == "b" }
    }

    @Test
    @MainActor
    func autoInsertWhileManualQueuedGoesAtTail() async throws {
        let (controller, _) = makeController()

        controller.insertManual(messageID: "m1", sourceText: "M1", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        controller.insertManual(messageID: "m2", sourceText: "M2", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        controller.insertAuto(messageID: "x", sourceText: "X", voiceIdentifier: nil, rate: 0.4, sessionID: "s")

        #expect(controller.queue.map(\.id) == ["m2", "x"])
    }

    // MARK: - Dedupe

    @Test
    @MainActor
    func insertManualDedupesAgainstActiveAndQueuedMessages() async throws {
        let (controller, _) = makeController()

        controller.insertManual(messageID: "m1", sourceText: "First", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        // Second click on the already-playing message: no-op.
        controller.insertManual(messageID: "m1", sourceText: "First", voiceIdentifier: nil, rate: 0.4, sessionID: "s")

        controller.insertManual(messageID: "m2", sourceText: "Second", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        // Second click on a queued message: also no-op.
        controller.insertManual(messageID: "m2", sourceText: "Second", voiceIdentifier: nil, rate: 0.4, sessionID: "s")

        #expect(controller.queue.map(\.id) == ["m2"])
        #expect(controller.currentMessageID == "m1")
    }

    // MARK: - Rewrite state exposed to UI

    @Test
    @MainActor
    func isRewritingReflectsRewriteStateForQueuedItems() async throws {
        let processor = ControllableSpeechTextProcessor()
        let (controller, _) = makeController(processor: processor)

        controller.insertManual(messageID: "m1", sourceText: "First", voiceIdentifier: nil, rate: 0.4, sessionID: "s")

        // Wait for the rewrite to reach the processor fixture.
        try await waitUntil { processor.pendingCount == 1 }
        // m1 is in-flight rewrite — still in queue, label should show.
        #expect(controller.isRewriting(messageID: "m1"))
        #expect(controller.currentMessageID == nil)

        // Release — m1 transitions to .ready, gets promoted, starts
        // playing. isRewriting flips back to false (item left the queue).
        processor.releaseAll()
        try await waitUntil { controller.currentMessageID == "m1" }
        #expect(!controller.isRewriting(messageID: "m1"))
    }

    @Test
    @MainActor
    func reactiveRewriterSwitchesTargetOnManualJump() async throws {
        let processor = ControllableSpeechTextProcessor()
        let (controller, _) = makeController(processor: processor)

        // Live Speak arrival starts rewriting.
        controller.insertAuto(messageID: "auto-1", sourceText: "Auto", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { processor.pendingCount == 1 }
        #expect(controller.isRewriting(messageID: "auto-1"))

        // User clicks Speak on a different message. Manual insert
        // lands at the head of the queue (no manual items yet), so
        // it becomes the new earliest-not-ready item. The reactive
        // rewriter cancels auto-1's rewrite and starts manual-1.
        controller.insertManual(messageID: "manual-1", sourceText: "Manual", voiceIdentifier: nil, rate: 0.4, sessionID: "s")

        try await waitUntil { controller.isRewriting(messageID: "manual-1") }
        #expect(controller.queue.map(\.id) == ["manual-1", "auto-1"])
    }

    // MARK: - Pause / resume / stop

    @Test
    @MainActor
    func pauseAndResumeEmitMatchingEvents() async throws {
        let (controller, avDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
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
    func stopClearsQueueAndActivePlayback() async throws {
        let (controller, avDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        controller.insertAuto(messageID: "m2", sourceText: "Second", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }

        controller.stop()

        #expect(avDriver.stopCallCount == 1)
        #expect(controller.currentMessageID == nil)
        #expect(controller.queue.isEmpty)
    }

    @Test
    @MainActor
    func drainAutoQueueRemovesAutoButPreservesManualAndCurrent() async throws {
        let (controller, _) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "M1", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        controller.insertManual(messageID: "m2", sourceText: "M2", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        controller.insertAuto(messageID: "m3", sourceText: "M3", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        // Give the passthrough rewriter time to mark m2/m3 ready.
        try await waitUntil { controller.queue.count == 2 }

        controller.drainAutoQueue()

        // m1 still playing (active, not in queue). m2 manual preserved,
        // m3 auto dropped.
        #expect(controller.currentMessageID == "m1")
        #expect(controller.queue.map(\.id) == ["m2"])
    }

    @Test
    @MainActor
    func switchingBackendsStopsActivePlaybackAndClearsQueue() async throws {
        let avDriver = FakeSpeechBackendDriver(
            availableVoices: [
                SpeechVoiceOption(id: "voice-1", name: "Voice One", language: "en-US", quality: .default)
            ]
        )
        let systemDriver = FakeSpeechBackendDriver(wordsPerMinute: 400)
        let controller = SpeechController(
            avSpeechDriver: avDriver,
            systemVoiceDriver: systemDriver
        )

        controller.insertAuto(messageID: "m1", sourceText: "First", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        controller.insertAuto(messageID: "m2", sourceText: "Second", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        controller.backend = .systemVoice

        #expect(avDriver.stopCallCount == 1)
        #expect(systemDriver.stopCallCount == 0)
        #expect(controller.currentMessageID == nil)
        #expect(controller.queue.isEmpty)
    }

    // MARK: - Error surfacing

    @Test
    @MainActor
    func startFailureSurfacesPlaybackError() async throws {
        let avDriver = FakeSpeechBackendDriver(
            availableVoices: [
                SpeechVoiceOption(id: "voice-1", name: "Voice One", language: "en-US", quality: .default)
            ]
        )
        avDriver.startError = FakeSpeechBackendDriver.StartFailure(description: "Voice not available")
        let controller = SpeechController(
            avSpeechDriver: avDriver,
            systemVoiceDriver: FakeSpeechBackendDriver(wordsPerMinute: 400)
        )

        controller.insertAuto(messageID: "m1", sourceText: "First", voiceIdentifier: nil, rate: 0.4, sessionID: "s")

        try await waitUntil { controller.playbackError?.message == "Voice not available" }
        #expect(controller.currentMessageID == nil)
    }

    @Test
    @MainActor
    func driverFailureSurfacesPlaybackErrorAndAdvancesQueue() async throws {
        let (controller, avDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        controller.insertAuto(messageID: "m2", sourceText: "Second", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }

        let firstPlaybackID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didFail(firstPlaybackID, description: "Mid-playback hiccup"))

        #expect(controller.playbackError?.message == "Mid-playback hiccup")
        try await waitUntil { controller.currentMessageID == "m2" }
    }

    @Test
    @MainActor
    func didStartClearsPreviousPlaybackError() async throws {
        let (controller, avDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        let firstPlaybackID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didFail(firstPlaybackID, description: "Broken"))
        #expect(controller.playbackError != nil)

        // Next item starts cleanly — the banner should auto-dismiss.
        controller.insertAuto(messageID: "m2", sourceText: "Second", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m2" }
        let secondPlaybackID = try #require(avDriver.startedRequests.last?.playbackID)
        avDriver.emit(.didStart(secondPlaybackID))
        #expect(controller.playbackError == nil)
    }

    @Test
    @MainActor
    func dismissPlaybackErrorClearsToast() async throws {
        let avDriver = FakeSpeechBackendDriver(
            availableVoices: [
                SpeechVoiceOption(id: "voice-1", name: "Voice One", language: "en-US", quality: .default)
            ]
        )
        avDriver.startError = FakeSpeechBackendDriver.StartFailure(description: "Voice not available")
        let controller = SpeechController(
            avSpeechDriver: avDriver,
            systemVoiceDriver: FakeSpeechBackendDriver(wordsPerMinute: 400)
        )

        controller.insertAuto(messageID: "m1", sourceText: "First", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.playbackError != nil }
        controller.dismissPlaybackError()

        #expect(controller.playbackError == nil)
    }

    @Test
    @MainActor
    func passesRateAndVoiceIdentifierToDriver() async throws {
        let (controller, avDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", voiceIdentifier: "voice-1", rate: 0.4, sessionID: "s")

        try await waitUntil { avDriver.startedRequests.count == 1 }
        let started = avDriver.startedRequests.first
        #expect(started?.rate == 0.4)
        #expect(started?.voiceIdentifier == "voice-1")
    }

    @Test
    @MainActor
    func driverEventsUpdatePauseAndResumeState() async throws {
        let (controller, avDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        let playbackID = try #require(avDriver.startedRequests.first?.playbackID)

        avDriver.emit(.didPause(playbackID))
        #expect(controller.isPaused)

        avDriver.emit(.didResume(playbackID))
        #expect(controller.isSpeaking)
    }
}
