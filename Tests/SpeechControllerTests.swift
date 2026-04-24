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

        controller.insertAuto(messageID: "m1", sourceText: "Queued first", sessionID: "s")

        // Passthrough rewrite lands via a Task hop — wait for it.
        try await waitUntil { controller.currentMessageID == "m1" }
        #expect(avDriver.startedRequests.count == 1)
        #expect(avDriver.startedRequests.first?.messageID == "m1")
    }

    @Test
    @MainActor
    func finishingCurrentPlaybackAdvancesToNext() async throws {
        let (controller, avDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        controller.insertAuto(messageID: "m2", sourceText: "Second", sessionID: "s")

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
        controller.insertManual(messageID: "m1", sourceText: "M1", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }

        // Live Speak queues x. The passthrough rewriter hops through
        // Task land; by the next synchronous insert x is the committed
        // head (being rewritten), and y hasn't started yet.
        controller.insertAuto(messageID: "x", sourceText: "X", sessionID: "s")
        controller.insertAuto(messageID: "y", sourceText: "Y", sessionID: "s")
        // Manual click — lands AFTER the committed x (can't jump an
        // in-flight rewrite) but AHEAD of the uncommitted y (manual
        // beats auto among pending items).
        controller.insertManual(messageID: "m2", sourceText: "M2", sessionID: "s")
        // m3 — after m2 (FIFO among manual clicks), still ahead of y.
        controller.insertManual(messageID: "m3", sourceText: "M3", sessionID: "s")

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

        controller.insertManual(messageID: "m1", sourceText: "M1", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        // Live Speak queues x — x becomes the committed head.
        controller.insertAuto(messageID: "x", sourceText: "X", sessionID: "s")

        // Speak from Here on {b, c, d} — sequence goes after the
        // committed x, stays contiguous, before anything not yet
        // touched.
        controller.insertManualSequence([
            (messageID: "b", sourceText: "B", sessionID: "s"),
            (messageID: "c", sourceText: "C", sessionID: "s"),
            (messageID: "d", sourceText: "D", sessionID: "s"),
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

        controller.insertManual(messageID: "m1", sourceText: "M1", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        controller.insertManual(messageID: "m2", sourceText: "M2", sessionID: "s")
        controller.insertAuto(messageID: "x", sourceText: "X", sessionID: "s")

        #expect(controller.queue.map(\.id) == ["m2", "x"])
    }

    // MARK: - Dedupe

    @Test
    @MainActor
    func insertManualDedupesAgainstActiveAndQueuedMessages() async throws {
        let (controller, _) = makeController()

        controller.insertManual(messageID: "m1", sourceText: "First", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        // Second click on the already-playing message: no-op.
        controller.insertManual(messageID: "m1", sourceText: "First", sessionID: "s")

        controller.insertManual(messageID: "m2", sourceText: "Second", sessionID: "s")
        // Second click on a queued message: also no-op.
        controller.insertManual(messageID: "m2", sourceText: "Second", sessionID: "s")

        #expect(controller.queue.map(\.id) == ["m2"])
        #expect(controller.currentMessageID == "m1")
    }

    // MARK: - Rewrite state exposed to UI

    @Test
    @MainActor
    func isRewritingReflectsRewriteStateForQueuedItems() async throws {
        let processor = ControllableSpeechTextProcessor()
        let (controller, _) = makeController(processor: processor)

        controller.insertManual(messageID: "m1", sourceText: "First", sessionID: "s")

        // Wait for the rewrite to reach the processor fixture.
        try await waitUntil { processor.pendingCount == 1 }
        // m1 is in-flight rewrite — still in queue, label should show.
        #expect(controller.status(for: "m1") == .rewriting)
        #expect(controller.currentMessageID == nil)

        // Release — m1 transitions to .ready, gets promoted, starts
        // playing. isRewriting flips back to false (item left the queue).
        processor.releaseAll()
        try await waitUntil { controller.currentMessageID == "m1" }
        #expect(controller.status(for: "m1") != .rewriting)
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
        controller.insertAuto(messageID: "auto-1", sourceText: "Auto", sessionID: "s")
        try await waitUntil { processor.pendingCount == 1 }
        #expect(controller.status(for: "auto-1") == .rewriting)

        // Manual click lands AFTER the committed auto-1.
        controller.insertManual(messageID: "manual-1", sourceText: "Manual", sessionID: "s")
        #expect(controller.queue.map(\.id) == ["auto-1", "manual-1"])

        // Rewriter is still working on auto-1 — no new process() call
        // was issued for manual-1, and auto-1's rewrite wasn't cancelled.
        #expect(processor.pendingCount == 1)
        #expect(controller.status(for: "auto-1") == .rewriting)
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
        controller.insertAuto(messageID: "auto-1", sourceText: "A1", sessionID: "s")
        try await waitUntil { processor.pendingCount == 1 }
        // auto-2 arrives behind it, still .pending.
        controller.insertAuto(messageID: "auto-2", sourceText: "A2", sessionID: "s")
        #expect(controller.queue.map(\.id) == ["auto-1", "auto-2"])

        // Manual click lands after the committed auto-1 but before
        // the uncommitted auto-2.
        controller.insertManual(messageID: "manual-1", sourceText: "M1", sessionID: "s")
        #expect(controller.queue.map(\.id) == ["auto-1", "manual-1", "auto-2"])
    }

    // MARK: - Pause / resume / stop

    @Test
    @MainActor
    func pauseAndResumeEmitMatchingEvents() async throws {
        let (controller, avDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
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

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        controller.insertAuto(messageID: "m2", sourceText: "Second", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }

        controller.stop()

        #expect(avDriver.stopCallCount == 1)
        #expect(controller.currentMessageID == nil)
        #expect(controller.queue.isEmpty)
    }

    // MARK: - Per-item cancel

    @Test
    @MainActor
    func cancelRemovesQueuedItemWithoutAffectingOthers() async throws {
        let (controller, _) = makeController()

        controller.insertManual(messageID: "m1", sourceText: "M1", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        controller.insertManual(messageID: "m2", sourceText: "M2", sessionID: "s")
        controller.insertManual(messageID: "m3", sourceText: "M3", sessionID: "s")
        try await waitUntil { controller.queue.map(\.id) == ["m2", "m3"] }

        controller.cancel(messageID: "m2")

        #expect(controller.currentMessageID == "m1")  // untouched
        #expect(controller.queue.map(\.id) == ["m3"])
    }

    @Test
    @MainActor
    func cancelSkipsCurrentPlaybackAndAdvancesToQueue() async throws {
        let (controller, avDriver) = makeController()

        controller.insertManual(messageID: "m1", sourceText: "M1", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        controller.insertManual(messageID: "m2", sourceText: "M2", sessionID: "s")
        try await waitUntil { controller.queue.first?.readyText != nil }

        let stopCallsBefore = avDriver.stopCallCount
        controller.cancel(messageID: "m1")

        // m1's driver was stopped, next queued (m2) promotes.
        #expect(avDriver.stopCallCount == stopCallsBefore + 1)
        try await waitUntil { controller.currentMessageID == "m2" }
        #expect(controller.queue.isEmpty)
    }

    @Test
    @MainActor
    func cancelOnInFlightRewriteTargetAdvancesToNextPending() async throws {
        let processor = ControllableSpeechTextProcessor()
        let (controller, _) = makeController(processor: processor)

        // Insert two items; m1 starts rewriting (committed head), m2 waits.
        controller.insertManual(messageID: "m1", sourceText: "M1", sessionID: "s")
        try await waitUntil { processor.pendingCount == 1 }
        controller.insertManual(messageID: "m2", sourceText: "M2", sessionID: "s")

        #expect(controller.status(for: "m1") == .rewriting)

        controller.cancel(messageID: "m1")

        // m1's rewrite is cancelled, m1 leaves the queue, rewriter
        // kicks off on m2.
        #expect(!controller.queue.contains(where: { $0.id == "m1" }))
        try await waitUntil { controller.status(for: "m2") == .rewriting }

        processor.releaseAll()
    }

    @Test
    @MainActor
    func cancelOnUnknownMessageIsNoOp() async throws {
        let (controller, _) = makeController()

        controller.insertManual(messageID: "m1", sourceText: "M1", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }

        controller.cancel(messageID: "does-not-exist")

        #expect(controller.currentMessageID == "m1")
    }

    @Test
    @MainActor
    func drainAutoQueueRemovesAutoButPreservesManualAndCurrent() async throws {
        let (controller, _) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "M1", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        controller.insertManual(messageID: "m2", sourceText: "M2", sessionID: "s")
        controller.insertAuto(messageID: "m3", sourceText: "M3", sessionID: "s")
        // Give the passthrough rewriter time to mark m2/m3 ready.
        try await waitUntil { controller.queue.count == 2 }

        controller.drainAutoQueue(for: "s")

        // m1 still playing (active, not in queue). m2 manual preserved,
        // m3 auto dropped.
        #expect(controller.currentMessageID == "m1")
        #expect(controller.queue.map(\.id) == ["m2"])
    }

    // NOTE: the old test that asserted "switching backends stops the
    // active driver + clears the queue" was removed. Under the current
    // architecture the queue is backend-neutral — items don't store
    // voice IDs, so a mid-playback backend switch lets the current
    // utterance finish on its original driver and the next item in
    // the queue starts on the newly-selected one. See
    // backendSwitchDoesNotClearQueueOrInterruptCurrent below.

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

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")

        try await waitUntil { controller.playbackError?.message == "Voice not available" }
        #expect(controller.currentMessageID == nil)
    }

    @Test
    @MainActor
    func driverFailureSurfacesPlaybackErrorAndAdvancesQueue() async throws {
        let (controller, avDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        controller.insertAuto(messageID: "m2", sourceText: "Second", sessionID: "s")
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

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        let firstPlaybackID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didFail(firstPlaybackID, description: "Broken"))
        #expect(controller.playbackError != nil)

        // Next item starts cleanly — the banner should auto-dismiss.
        controller.insertAuto(messageID: "m2", sourceText: "Second", sessionID: "s")
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

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        try await waitUntil { controller.playbackError != nil }
        controller.dismissPlaybackError()

        #expect(controller.playbackError == nil)
    }

    @Test
    @MainActor
    func readsVoiceAndRateFromProvidersAtSpeakTime() async throws {
        // Queue items don't carry voice/rate; the controller looks
        // them up at speak() time via injected providers. Swapping
        // the provider values between enqueue and playback means the
        // driver receives the latest values.
        let (controller, avDriver) = makeController()
        var currentVoice: String? = "voice-1"
        var currentRate: Float = 0.4
        controller.voiceIdentifierProvider = { currentVoice }
        controller.rateProvider = { currentRate }

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")

        try await waitUntil { avDriver.startedRequests.count == 1 }
        let firstRequest = try #require(avDriver.startedRequests.first)
        #expect(firstRequest.rate == 0.4)
        #expect(firstRequest.voiceIdentifier == "voice-1")

        // Change the providers BEFORE the next item starts. When m2
        // promotes, it should read the new values.
        currentVoice = "voice-2"
        currentRate = 0.5
        controller.insertAuto(messageID: "m2", sourceText: "Second", sessionID: "s")
        // Simulate m1 finishing so m2 promotes.
        avDriver.emit(.didFinish(firstRequest.playbackID))
        try await waitUntil { avDriver.startedRequests.count == 2 }
        let secondRequest = try #require(avDriver.startedRequests.last)
        #expect(secondRequest.rate == 0.5)
        #expect(secondRequest.voiceIdentifier == "voice-2")
    }

    @Test
    @MainActor
    func backendSwitchDoesNotClearQueueOrInterruptCurrent() async throws {
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

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        controller.insertAuto(messageID: "m2", sourceText: "Second", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }

        // Switch backend mid-playback.
        controller.backend = .systemVoice

        // Current utterance on AVSpeech is NOT stopped, queue is NOT cleared.
        #expect(avDriver.stopCallCount == 0)
        #expect(controller.currentMessageID == "m1")
        #expect(!controller.queue.isEmpty)

        // When m1 finishes on AVSpeech, the next item plays on the
        // current backend (System Voice).
        let m1PlaybackID = try #require(avDriver.startedRequests.first?.playbackID)
        avDriver.emit(.didFinish(m1PlaybackID))
        try await waitUntil { controller.currentMessageID == "m2" }
        #expect(systemDriver.startedRequests.count == 1)
        #expect(systemDriver.startedRequests.first?.messageID == "m2")
    }

    @Test
    @MainActor
    func driverEventsUpdatePauseAndResumeState() async throws {
        let (controller, avDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        let playbackID = try #require(avDriver.startedRequests.first?.playbackID)

        avDriver.emit(.didPause(playbackID))
        #expect(controller.isPaused)

        avDriver.emit(.didResume(playbackID))
        #expect(controller.isSpeaking)
    }
}
