import Foundation
import Testing
@testable import AgentsAloud

// Helper: build a controller wired to a single fake driver (acting as
// the SystemVoice driver, since that's the post-AVSpeech default
// backend) plus an optional controllable processor. Default processor
// is passthrough so tests that don't care about rewrite timing get
// near-instant .ready items (still one Task-yield away from sync).
@MainActor
private func makeController(
    processor: any SpeechTextProcessor = PassthroughSpeechProcessor()
) -> (controller: SpeechController, fakeDriver: FakeSpeechBackendDriver) {
    let fakeDriver = FakeSpeechBackendDriver(
        availableVoices: [
            SpeechVoiceOption(id: "voice-1", name: "Voice One", language: "en-US")
        ]
    )
    let controller = SpeechController(
        systemVoiceDriver: fakeDriver,
        speechTextProcessor: processor
    )
    return (controller, fakeDriver)
}

@Suite
struct SpeechControllerTests {

    // MARK: - Basic playback via insertAuto / insertManual

    @Test
    @MainActor
    func insertAutoOnIdleStartsPlaybackAfterRewriteCompletes() async throws {
        let (controller, fakeDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "Queued first", sessionID: "s")

        // Passthrough rewrite lands via a Task hop — wait for it.
        try await waitUntil { controller.currentMessageID == "m1" }
        #expect(fakeDriver.startedRequests.count == 1)
        #expect(fakeDriver.startedRequests.first?.messageID == "m1")
    }

    @Test
    @MainActor
    func finishingCurrentPlaybackAdvancesToNext() async throws {
        let (controller, fakeDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        controller.insertAuto(messageID: "m2", sourceText: "Second", sessionID: "s")

        try await waitUntil { controller.currentMessageID == "m1" }
        try await waitUntil { controller.queue.first?.id == "m2" && controller.queue.first?.readyText != nil }

        let firstPlaybackID = try #require(fakeDriver.startedRequests.first?.playbackID)
        fakeDriver.emit(.didFinish(firstPlaybackID))

        try await waitUntil { controller.currentMessageID == "m2" }
        #expect(fakeDriver.startedRequests.count == 2)
    }

    // MARK: - Manual vs Auto insert ordering

    @Test
    @MainActor
    func manualInsertGoesAfterCommittedAndAfterLastManual() async throws {
        let (controller, fakeDriver) = makeController()

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
        let m1ID = try #require(fakeDriver.startedRequests.first?.playbackID)
        fakeDriver.emit(.didFinish(m1ID))
        try await waitUntil { controller.currentMessageID == "x" }
    }

    @Test
    @MainActor
    func manualSequenceStaysContiguousAfterCommittedAuto() async throws {
        let (controller, fakeDriver) = makeController()

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

        let m1ID = try #require(fakeDriver.startedRequests.first?.playbackID)
        fakeDriver.emit(.didFinish(m1ID))
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
        let (controller, fakeDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        let playbackID = try #require(fakeDriver.startedRequests.first?.playbackID)

        controller.pause()
        #expect(fakeDriver.pauseCallCount == 1)
        fakeDriver.emit(.didPause(playbackID))
        #expect(controller.isPaused)

        controller.resume()
        #expect(fakeDriver.resumeCallCount == 1)
        fakeDriver.emit(.didResume(playbackID))
        #expect(controller.isSpeaking)
        #expect(!controller.isPaused)
    }

    @Test
    @MainActor
    func stopClearsQueueAndActivePlayback() async throws {
        let (controller, fakeDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        controller.insertAuto(messageID: "m2", sourceText: "Second", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }

        controller.stop()

        #expect(fakeDriver.stopCallCount == 1)
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
        let (controller, fakeDriver) = makeController()

        controller.insertManual(messageID: "m1", sourceText: "M1", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        controller.insertManual(messageID: "m2", sourceText: "M2", sessionID: "s")
        try await waitUntil { controller.queue.first?.readyText != nil }

        let stopCallsBefore = fakeDriver.stopCallCount
        controller.cancel(messageID: "m1")

        // m1's driver was stopped, next queued (m2) promotes.
        #expect(fakeDriver.stopCallCount == stopCallsBefore + 1)
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
        let (controller, fakeDriver) = makeController()
        fakeDriver.startError = FakeSpeechBackendDriver.StartFailure(description: "Voice not available")

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")

        try await waitUntil { controller.playbackError?.message == "Voice not available" }
        #expect(controller.currentMessageID == nil)
    }

    @Test
    @MainActor
    func driverFailureSurfacesPlaybackErrorAndAdvancesQueue() async throws {
        let (controller, fakeDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        controller.insertAuto(messageID: "m2", sourceText: "Second", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }

        let firstPlaybackID = try #require(fakeDriver.startedRequests.first?.playbackID)
        fakeDriver.emit(.didFail(firstPlaybackID, description: "Mid-playback hiccup"))

        #expect(controller.playbackError?.message == "Mid-playback hiccup")
        try await waitUntil { controller.currentMessageID == "m2" }
    }

    @Test
    @MainActor
    func didStartClearsPreviousPlaybackError() async throws {
        let (controller, fakeDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        let firstPlaybackID = try #require(fakeDriver.startedRequests.first?.playbackID)
        fakeDriver.emit(.didFail(firstPlaybackID, description: "Broken"))
        #expect(controller.playbackError != nil)

        // Next item starts cleanly — the banner should auto-dismiss.
        controller.insertAuto(messageID: "m2", sourceText: "Second", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m2" }
        let secondPlaybackID = try #require(fakeDriver.startedRequests.last?.playbackID)
        fakeDriver.emit(.didStart(secondPlaybackID))
        #expect(controller.playbackError == nil)
    }

    @Test
    @MainActor
    func dismissPlaybackErrorClearsToast() async throws {
        let (controller, fakeDriver) = makeController()
        fakeDriver.startError = FakeSpeechBackendDriver.StartFailure(description: "Voice not available")

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
        let (controller, fakeDriver) = makeController()
        var currentVoice: String? = "voice-1"
        var currentWPM: Int = 350
        controller.voiceIdentifierProvider = { currentVoice }
        controller.wordsPerMinuteProvider = { currentWPM }

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")

        try await waitUntil { fakeDriver.startedRequests.count == 1 }
        let firstRequest = try #require(fakeDriver.startedRequests.first)
        #expect(firstRequest.wordsPerMinute == 350)
        #expect(firstRequest.voiceIdentifier == "voice-1")

        // Change the providers BEFORE the next item starts. When m2
        // promotes, it should read the new values.
        currentVoice = "voice-2"
        currentWPM = 425
        controller.insertAuto(messageID: "m2", sourceText: "Second", sessionID: "s")
        // Simulate m1 finishing so m2 promotes.
        fakeDriver.emit(.didFinish(firstRequest.playbackID))
        try await waitUntil { fakeDriver.startedRequests.count == 2 }
        let secondRequest = try #require(fakeDriver.startedRequests.last)
        #expect(secondRequest.wordsPerMinute == 425)
        #expect(secondRequest.voiceIdentifier == "voice-2")
    }

    @Test
    @MainActor
    func backendSwitchDoesNotClearQueueOrInterruptCurrent() async throws {
        // The queue is cross-backend by design: items don't carry a
        // voice ID or rate, so they survive a backend switch and pick
        // up whatever's selected when their turn comes. This test
        // covers the "switch flips while m1 is playing" path: m1 must
        // continue to the end on its original driver, and the queue
        // (with m2 still pending) must not be cleared.
        let (controller, fakeDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        controller.insertAuto(messageID: "m2", sourceText: "Second", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }

        // Switch backend mid-playback. Choose ElevenLabs as the
        // target — it's the only other backend now that AVSpeech is
        // gone. We don't try to verify m2 starts there because the
        // ElevenLabs driver requires a real API client to actually
        // synthesize; this test focuses solely on the "no clear / no
        // interrupt" guarantee.
        controller.backend = .elevenLabs

        #expect(fakeDriver.stopCallCount == 0)
        #expect(controller.currentMessageID == "m1")
        #expect(!controller.queue.isEmpty)
    }

    @Test
    @MainActor
    func driverEventsUpdatePauseAndResumeState() async throws {
        let (controller, fakeDriver) = makeController()

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        let playbackID = try #require(fakeDriver.startedRequests.first?.playbackID)

        fakeDriver.emit(.didPause(playbackID))
        #expect(controller.isPaused)

        fakeDriver.emit(.didResume(playbackID))
        #expect(controller.isSpeaking)
    }

    // MARK: - Currently-speaking session

    @Test
    @MainActor
    func currentSessionIDTracksActivePlaybackAndClearsOnIdle() async throws {
        let (controller, fakeDriver) = makeController()
        #expect(controller.currentSessionID == nil)

        controller.insertAuto(messageID: "m1", sourceText: "Hi", sessionID: "sX")
        try await waitUntil { controller.currentMessageID == "m1" }
        #expect(controller.currentSessionID == "sX")

        let playbackID = try #require(fakeDriver.startedRequests.first?.playbackID)
        fakeDriver.emit(.didFinish(playbackID))
        try await waitUntil { controller.currentMessageID == nil }
        #expect(controller.currentSessionID == nil)
    }

    // MARK: - Cross-session attribution cue

    @Test
    @MainActor
    func attributionPrefixSpokenWhenSessionChanges() async throws {
        let (controller, fakeDriver) = makeController()
        controller.sessionLabelProvider = { id in
            switch id {
            case "sA": return "Project A"
            case "sB": return "Project B"
            default: return nil
            }
        }

        // First utterance of a fresh stream: no prior context, so no
        // attribution — only genuine transitions get announced.
        controller.insertAuto(messageID: "m1", sourceText: "Hello from A", sessionID: "sA")
        try await waitUntil { controller.currentMessageID == "m1" }
        let first = try #require(fakeDriver.startedRequests.first)
        #expect(first.text == "Hello from A")

        // A message from a DIFFERENT session plays next → prefixed.
        controller.insertAuto(messageID: "m2", sourceText: "Hello from B", sessionID: "sB")
        fakeDriver.emit(.didFinish(first.playbackID))
        try await waitUntil { controller.currentMessageID == "m2" }
        let second = try #require(fakeDriver.startedRequests.last)
        #expect(second.text == "From Project B. Hello from B")
    }

    @Test
    @MainActor
    func noAttributionPrefixWithinSameSession() async throws {
        let (controller, fakeDriver) = makeController()
        controller.sessionLabelProvider = { _ in "Project A" }

        controller.insertAuto(messageID: "m1", sourceText: "First", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m1" }
        let first = try #require(fakeDriver.startedRequests.first)
        fakeDriver.emit(.didFinish(first.playbackID))

        controller.insertAuto(messageID: "m2", sourceText: "Second", sessionID: "s")
        try await waitUntil { controller.currentMessageID == "m2" }
        let second = try #require(fakeDriver.startedRequests.last)
        #expect(second.text == "Second")
    }

    @Test
    @MainActor
    func firstUtteranceAttributedWhenMultipleSourcesLive() async throws {
        // With more than one session able to auto-speak, even the first
        // utterance of a cold stream is ambiguous — so it gets a cue,
        // unlike the single-source case (which the test above pins).
        let (controller, fakeDriver) = makeController()
        controller.sessionLabelProvider = { _ in "Project A" }
        controller.shouldAttributeFirstUtteranceProvider = { true }

        controller.insertAuto(messageID: "m1", sourceText: "Hello", sessionID: "sA")
        try await waitUntil { controller.currentMessageID == "m1" }
        let first = try #require(fakeDriver.startedRequests.first)
        #expect(first.text == "From Project A. Hello")
    }

    @Test
    @MainActor
    func stopResetsAttributionContext() async throws {
        let (controller, fakeDriver) = makeController()
        controller.sessionLabelProvider = { id in id == "sB" ? "Project B" : "Project A" }

        controller.insertAuto(messageID: "m1", sourceText: "A", sessionID: "sA")
        try await waitUntil { controller.currentMessageID == "m1" }
        controller.stop()

        // A full stop ends the stream. The next message — even from a
        // different session — is the start of a new stream, so there's
        // no prior context to transition from and no prefix.
        controller.insertAuto(messageID: "m2", sourceText: "B", sessionID: "sB")
        try await waitUntil { controller.currentMessageID == "m2" }
        let last = try #require(fakeDriver.startedRequests.last)
        #expect(last.text == "B")
    }
}
