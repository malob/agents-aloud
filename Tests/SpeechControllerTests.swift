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
    func manualInsertGoesAfterCommittedAndAfterLastManual() async throws {
        let (controller, avDriver) = makeController()

        // m1 starts playing (manual, idle → speak).
        controller.insertManual(messageID: "m1", sourceText: "M1", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }

        // Live Speak queues x. The passthrough rewriter hops through
        // Task land; by the next synchronous insert x is the committed
        // head (being rewritten), and y hasn't started yet.
        controller.insertAuto(messageID: "x", sourceText: "X", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        controller.insertAuto(messageID: "y", sourceText: "Y", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        // Manual click — lands AFTER the committed x (can't jump an
        // in-flight rewrite) but AHEAD of the uncommitted y (manual
        // beats auto among pending items).
        controller.insertManual(messageID: "m2", sourceText: "M2", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        // m3 — after m2 (FIFO among manual clicks), still ahead of y.
        controller.insertManual(messageID: "m3", sourceText: "M3", voiceIdentifier: nil, rate: 0.4, sessionID: "s")

        #expect(controller.queue.map(\.id) == ["x", "m2", "m3", "y"])

        // When m1 finishes, x plays next — it was committed. m2 waits.
        let m1ID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didFinish(m1ID))
        try await waitUntil { controller.currentMessageID == "x" }
    }

    @Test
    @MainActor
    func manualSequenceStaysContiguousAfterCommittedAuto() async throws {
        let (controller, avDriver) = makeController()

        controller.insertManual(messageID: "m1", sourceText: "M1", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        // Live Speak queues x — x becomes the committed head.
        controller.insertAuto(messageID: "x", sourceText: "X", voiceIdentifier: nil, rate: 0.4, sessionID: "s")

        // Speak from Here on {b, c, d} — sequence goes after the
        // committed x, stays contiguous, before anything not yet
        // touched.
        controller.insertManualSequence([
            (messageID: "b", sourceText: "B", voiceIdentifier: nil, rate: 0.4, sessionID: "s"),
            (messageID: "c", sourceText: "C", voiceIdentifier: nil, rate: 0.4, sessionID: "s"),
            (messageID: "d", sourceText: "D", voiceIdentifier: nil, rate: 0.4, sessionID: "s"),
        ])

        #expect(controller.queue.map(\.id) == ["x", "b", "c", "d"])

        let m1ID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didFinish(m1ID))
        try await waitUntil { controller.currentMessageID == "x" }
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
    func manualInsertDoesNotJumpACommittedAutoRewrite() async throws {
        // Committed-head invariant: if an auto item is already being
        // rewritten when the user clicks Speak on a manual message,
        // the manual lands AFTER the auto (not ahead). The auto's
        // in-flight rewrite runs to completion; the manual waits its
        // turn. "Once a message is in the rewriting stage, nothing
        // will interrupt it" — the user's preferred semantics.
        let processor = ControllableSpeechTextProcessor()
        let (controller, _) = makeController(processor: processor)

        // Live Speak arrival starts rewriting.
        controller.insertAuto(messageID: "auto-1", sourceText: "Auto", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { processor.pendingCount == 1 }
        #expect(controller.isRewriting(messageID: "auto-1"))

        // Manual click lands AFTER the committed auto-1.
        controller.insertManual(messageID: "manual-1", sourceText: "Manual", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        #expect(controller.queue.map(\.id) == ["auto-1", "manual-1"])

        // Rewriter is still working on auto-1 — no new process() call
        // was issued for manual-1, and auto-1's rewrite wasn't cancelled.
        #expect(processor.pendingCount == 1)
        #expect(controller.isRewriting(messageID: "auto-1"))
    }

    @Test
    @MainActor
    func manualInsertStillJumpsUncommittedAutoItems() async throws {
        // The committed-head rule only protects the item currently
        // being rewritten — auto items queued behind still lose to
        // manual clicks.
        let processor = ControllableSpeechTextProcessor()
        let (controller, _) = makeController(processor: processor)

        // auto-1 starts rewriting (committed).
        controller.insertAuto(messageID: "auto-1", sourceText: "A1", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        try await waitUntil { processor.pendingCount == 1 }
        // auto-2 arrives behind it, still .pending.
        controller.insertAuto(messageID: "auto-2", sourceText: "A2", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        #expect(controller.queue.map(\.id) == ["auto-1", "auto-2"])

        // Manual click lands after the committed auto-1 but before
        // the uncommitted auto-2.
        controller.insertManual(messageID: "manual-1", sourceText: "M1", voiceIdentifier: nil, rate: 0.4, sessionID: "s")
        #expect(controller.queue.map(\.id) == ["auto-1", "manual-1", "auto-2"])
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
