import Foundation
import Observation
import OSLog

// Owns the single source of truth for "what's going to play and in
// what order." The queue holds PendingSpeechItems carrying their own
// rewrite state, so ordering is set by queue position (not by which
// rewrite happened to finish first). A single serial rewriter walks
// the queue top-down, one item at a time. When the head of the queue
// is .ready AND no active playback, we promote it to activePlayback
// and start the driver.
//
// Committed-head semantic: once the rewriter starts on an item, that
// item is committed to play next — subsequent inserts go AFTER it,
// not ahead of it. The only things that can interrupt a committed
// rewrite are stop() / session switch / backend switch / drainAuto
// (the last only if the rewriter was working on an auto item that
// got drained). A manual Speak click while something is rewriting
// queues the new message behind the committed one, matching the
// user mental model: "the thing at the top of the queue is set,
// nothing jumps it."
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
        let messageID: String
        let sessionID: String
    }

    private enum PlaybackState {
        case idle
        case speaking(ActivePlayback)
        case paused(ActivePlayback)

        var activePlayback: ActivePlayback? {
            switch self {
            case .idle: return nil
            case let .speaking(active), let .paused(active): return active
            }
        }

        var isSpeaking: Bool {
            if case .speaking = self { return true }
            return false
        }

        var isPaused: Bool {
            if case .paused = self { return true }
            return false
        }
    }

    @ObservationIgnored private let logger = Logger(subsystem: "local.claudecodevoice", category: "Speech")
    @ObservationIgnored private var playbackErrorDismissTask: Task<Void, Never>?
    @ObservationIgnored private let systemVoiceDriver: any SpeechBackendDriver
    // Not @ObservationIgnored: the ElevenLabs driver is @Observable, and
    // `availableVoices` reads through this stored property. Keeping the
    // property observable lets SwiftUI propagate voice-list refreshes
    // (populated async after the API key is entered) to Settings' picker.
    let elevenLabsDriver: ElevenLabsBackendDriver

    // The rewriter that transforms source text into speech-ready text.
    // Injected so AppModel can swap it (off / Claude CLI / Apple
    // Intelligence) without the controller knowing which backend is
    // doing the rewriting.
    @ObservationIgnored private var speechTextProcessor: any SpeechTextProcessor

    // Providers for the per-playback voice and rate. Looked up fresh
    // at speak() time rather than baked into queue items, so the
    // queue is robust to both backend switches (each driver has its
    // own voice ID space) and rate changes between enqueue and play.
    // AppModel wires these to point at its own currentVoiceIdentifier
    // and preferredSpeechRate properties.
    @ObservationIgnored var voiceIdentifierProvider: @MainActor () -> String? = { nil }
    @ObservationIgnored var wordsPerMinuteProvider: @MainActor () -> Int = { 400 }

    // Resolves a sessionID to a short, spoken-friendly label for the
    // cross-session attribution cue ("From <label>."). Looked up at
    // speak() time so a renamed session announces its current name.
    // AppModel wires this to its session list; nil ⇒ no cue (unknown
    // session, or caller didn't wire a provider).
    @ObservationIgnored var sessionLabelProvider: @MainActor (String) -> String? = { _ in nil }

    // Whether the FIRST utterance of a stream (no prior session
    // context) should still be attributed. Normally false — you don't
    // need "From X" before the only thing playing. AppModel wires this
    // to "more than one session has Live Speak on," so a cold start
    // with several live sources orients the listener instead of leaving
    // the first message anonymous.
    @ObservationIgnored var shouldAttributeFirstUtteranceProvider: @MainActor () -> Bool = { false }

    // The session whose message was last sent to a driver. Drives the
    // attribution cue: a new item whose sessionID differs from this
    // gets a "From <label>." preamble. nil at the start of a stream
    // (launch, or after stop()) so the first utterance is never
    // prefixed — only genuine transitions are announced, which keeps
    // single-session listening completely cue-free.
    @ObservationIgnored private var lastPlayedSessionID: String?

    private var playbackState: PlaybackState = .idle
    // The ordered queue of items waiting to play. Items enter via
    // insertManual / insertAuto / insertManualSequence; exit when
    // promoted to activePlayback. UI observes this to render the
    // "Rewriting…" label on any row whose item is .rewriting.
    private(set) var queue: [PendingSpeechItem] = []

    // The Task currently performing a SpeechTextProcessor.process call.
    // Only one at a time — rewrites are serial. Once a target is
    // picked it runs to completion; inserts never cancel an in-flight
    // rewrite (that's the committed-head invariant). Cancellation
    // only happens via stop / session switch / backend switch /
    // drainAutoQueue-where-target-was-auto.
    @ObservationIgnored private var rewriterTask: Task<Void, Never>?
    @ObservationIgnored private var rewriterTargetID: String?

    var backend: SpeechBackend = .systemVoice {
        didSet {
            guard oldValue != backend else { return }
            // Backend switch is NOT a reset. The currently-playing
            // utterance continues on the old driver until it finishes
            // naturally (activeDriver is captured from the stored
            // playback's backend, not from this var). The queue
            // persists — its items don't carry voice IDs, so each
            // one will pick up the current backend via the providers
            // when it's next to play.
        }
    }

    init(
        systemVoiceDriver: any SpeechBackendDriver = SystemVoiceBackendDriver(),
        elevenLabsDriver: ElevenLabsBackendDriver = ElevenLabsBackendDriver(
            client: ElevenLabsClient(apiKey: "")
        ),
        speechTextProcessor: any SpeechTextProcessor = PassthroughSpeechProcessor()
    ) {
        self.systemVoiceDriver = systemVoiceDriver
        self.elevenLabsDriver = elevenLabsDriver
        self.speechTextProcessor = speechTextProcessor
    }

    deinit {
        playbackErrorDismissTask?.cancel()
        rewriterTask?.cancel()
    }

    // Called by AppModel when the user toggles the optimization mode in
    // Settings. Swapping mid-queue is OK — items already rewritten keep
    // their .ready text; items still .pending will be rewritten by the
    // new processor when their turn comes up.
    func setSpeechTextProcessor(_ processor: any SpeechTextProcessor) {
        speechTextProcessor = processor
    }

    var isSpeaking: Bool { playbackState.isSpeaking }
    var isPaused: Bool { playbackState.isPaused }
    var currentMessageID: String? { playbackState.activePlayback?.messageID }
    // Session that owns the currently-active utterance (playing OR
    // paused), nil when idle. Lets the UI show which session is
    // speaking right now — distinct from liveReadSessionIDs (which
    // sessions WILL auto-read) and from lastPlayedSessionID (which
    // persists past the end of playback for the attribution cue).
    var currentSessionID: String? { playbackState.activePlayback?.sessionID }

    // Everything the UI needs to render per-row status for a given
    // message. One enum instead of a grab-bag of booleans so the row
    // view just switches on it.
    enum MessageStatus: Equatable {
        case idle
        case speaking                        // currently playing
        case rewriting                       // being rewritten (always queue head under committed-head)
        case queued(position: Int)           // in queue, 0-indexed position

        var isInFlight: Bool {
            switch self {
            case .speaking, .rewriting, .queued: return true
            case .idle: return false
            }
        }
    }

    func status(for messageID: String) -> MessageStatus {
        if currentMessageID == messageID { return .speaking }
        guard let index = queue.firstIndex(where: { $0.id == messageID }) else {
            return .idle
        }
        if case .rewriting = queue[index].rewriteState {
            return .rewriting
        }
        return .queued(position: index)
    }

    // Voice list is backend-scoped: SystemVoice exposes nothing (uses
    // the system-wide voice); ElevenLabs exposes the user's account
    // voices. Callers read this reactively (the Settings picker binds
    // to it), so whenever `backend` changes this returns the right
    // set automatically.
    var availableVoices: [SpeechVoiceOption] {
        driver(for: backend).availableVoices
    }

    var defaultVoiceIdentifier: String? {
        driver(for: backend).resolveVoiceIdentifier(nil)
    }

    var playbackError: PlaybackError?

    func resolveVoiceIdentifier(_ identifier: String?) -> String? {
        driver(for: backend).resolveVoiceIdentifier(identifier)
    }

    // MARK: - Queue mutation (external API)

    // User clicked Speak on a message. Manual insert rule: land right
    // after the last manual item in the queue (or right after the
    // playhead if there's no manual item yet), preserving FIFO order
    // of manual clicks and keeping auto (Live Speak) items behind all
    // manual items.
    //
    // Dedupe: if the messageID is already in the queue or currently
    // playing, no-op. The user's click is interpreted as "I want this
    // spoken" — which is either already in motion or already happening.
    func insertManual(
        messageID: String,
        sourceText: String,
        sessionID: String
    ) {
        guard !isQueuedOrActive(messageID: messageID) else { return }

        let item = PendingSpeechItem(
            id: messageID,
            sourceText: sourceText,
            rewriteState: .pending,
            source: .manual,
            sessionID: sessionID
        )
        let index = indexForManualInsert()
        queue.insert(item, at: index)
        onQueueChanged()
    }

    // Speak-from-Here batches a sequence of messages into the manual
    // slot contiguously. All are .manual so subsequent manual clicks
    // land after this whole block, not in the middle of it.
    func insertManualSequence(
        _ messages: [(messageID: String, sourceText: String, sessionID: String)]
    ) {
        guard !messages.isEmpty else { return }
        var insertIndex = indexForManualInsert()
        for message in messages {
            guard !isQueuedOrActive(messageID: message.messageID) else { continue }
            let item = PendingSpeechItem(
                id: message.messageID,
                sourceText: message.sourceText,
                rewriteState: .pending,
                source: .manual,
                sessionID: message.sessionID
            )
            queue.insert(item, at: insertIndex)
            insertIndex += 1
        }
        onQueueChanged()
    }

    // Live Speak arrival → tail of queue. No special handling, just
    // append and let the serial pipeline do its thing. This is the
    // entire Live Speak integration from the queue's perspective.
    func insertAuto(
        messageID: String,
        sourceText: String,
        sessionID: String
    ) {
        guard !isQueuedOrActive(messageID: messageID) else { return }

        let item = PendingSpeechItem(
            id: messageID,
            sourceText: sourceText,
            rewriteState: .pending,
            source: .auto,
            sessionID: sessionID
        )
        queue.append(item)
        onQueueChanged()
    }

    // MARK: - Playback controls

    func pause() {
        activeDriver?.pause()
    }

    func resume() {
        activeDriver?.resume()
    }

    // Full stop: kill current audio, drop the queue, cancel any
    // in-flight rewrite. User's "stop everything" intent.
    func stop() {
        (activeDriver ?? currentDriver).stop()
        playbackState = .idle
        // End the attribution stream: the next message is a fresh
        // start, not a transition from whatever was last heard.
        lastPlayedSessionID = nil
        clearQueueAndRewriter()
    }

    // Per-item cancel. Removes a single message from the speech
    // pipeline without affecting anything else:
    //
    //  - If `messageID` is currently playing: stop that utterance,
    //    promote the next ready item in the queue (if any). Other
    //    queued items are untouched — this is "skip," not "stop."
    //  - If `messageID` is the current rewriter target: cancel the
    //    in-flight rewrite, remove it from the queue, and start the
    //    rewriter on the next pending item.
    //  - If `messageID` is otherwise in the queue: just remove it.
    //  - If `messageID` is nowhere in the pipeline: no-op.
    //
    // Used by the per-row pill's hover-to-cancel affordance.
    func cancel(messageID: String) {
        if currentMessageID == messageID {
            (activeDriver ?? currentDriver).stop()
            playbackState = .idle
            promoteHeadIfReady()
            return
        }
        guard let index = queue.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        let wasRewriterTarget = rewriterTargetID == messageID
        if wasRewriterTarget {
            cancelRewriterIfRunning()
        }
        queue.remove(at: index)
        // cancelRewriterIfRunning above bumped the removed item back
        // to .pending — but since we just removed it from the queue,
        // that doesn't matter. Kick the rewriter onto whatever's next.
        if wasRewriterTarget {
            startRewriterIfNeeded()
        }
        promoteHeadIfReady()
    }

    // Drop queued AUTO items belonging to a specific session but
    // preserve everything else (manual items, auto items from other
    // sessions, the current utterance). Used by "Stop Live Speak"
    // for a single session under the one-Live-Speak-at-a-time rule.
    // The user's manual intent survives toggling auto off, and so
    // do any residual auto items from a session that previously had
    // Live Speak before it was transferred away.
    func drainAutoQueue(for sessionID: String) {
        let hadRewritingAutoForSession = rewriterTargetID.flatMap { id in
            queue.first(where: {
                $0.id == id && $0.source == .auto && $0.sessionID == sessionID
            })
        } != nil
        queue.removeAll(where: { $0.source == .auto && $0.sessionID == sessionID })
        if hadRewritingAutoForSession {
            // The item the rewriter was working on got drained.
            cancelRewriterIfRunning()
            // Start on the next .pending, if any.
            startRewriterIfNeeded()
        }
    }

    func dismissPlaybackError() {
        playbackErrorDismissTask?.cancel()
        playbackErrorDismissTask = nil
        playbackError = nil
    }

    // MARK: - Internal queue mechanics

    private func isQueuedOrActive(messageID: String) -> Bool {
        if playbackState.activePlayback?.messageID == messageID { return true }
        return queue.contains(where: { $0.id == messageID })
    }

    // Manual insert position: after the last manual item in the
    // queue, AND after the committed frontier. "Committed" means any
    // item the rewriter has already touched — .rewriting or .ready.
    // Only .pending items are still uncommitted. Taking the max of
    // those two bounds preserves:
    //  - manual beats auto (manual items cluster ahead of auto tail
    //    among uncommitted items)
    //  - FIFO among manual clicks (new manual after previous manual)
    //  - committed-head (never jumps a rewrite already in progress or
    //    an item that's finished rewriting and is waiting behind
    //    active playback)
    private func indexForManualInsert() -> Int {
        let committedFrontier = queue.lastIndex(where: { item in
            if case .pending = item.rewriteState { return false }
            return true
        }) ?? -1
        let lastManual = queue.lastIndex(where: { $0.source == .manual }) ?? -1
        return max(committedFrontier + 1, lastManual + 1)
    }

    // Called after any queue mutation. Two jobs:
    //  1. If the rewriter isn't running and there's a .pending item in
    //     the queue, start a rewrite.
    //  2. If activePlayback is nil and head of queue is .ready, promote
    //     it and start the driver.
    private func onQueueChanged() {
        startRewriterIfNeeded()
        promoteHeadIfReady()
    }

    private func cancelRewriterIfRunning() {
        rewriterTask?.cancel()
        rewriterTask = nil
        // Reset any .rewriting item back to .pending — we cancelled
        // mid-rewrite, its result is no longer coming.
        if let oldID = rewriterTargetID,
           let idx = queue.firstIndex(where: { $0.id == oldID }),
           case .rewriting = queue[idx].rewriteState {
            queue[idx].rewriteState = .pending
        }
        rewriterTargetID = nil
    }

    private func startRewriterIfNeeded() {
        guard rewriterTask == nil else { return }
        guard let targetIdx = queue.firstIndex(where: { $0.rewriteState == .pending }) else {
            return
        }
        let targetID = queue[targetIdx].id
        let sourceText = queue[targetIdx].sourceText
        queue[targetIdx].rewriteState = .rewriting
        rewriterTargetID = targetID

        // Snapshot processor locally so the Task closes over the
        // current instance even if setSpeechTextProcessor swaps it
        // mid-rewrite (the in-flight call continues with the old one).
        let processor = speechTextProcessor
        rewriterTask = Task { [weak self] in
            let rewritten = await processor.process(text: sourceText)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.handleRewriteResult(messageID: targetID, rewritten: rewritten)
            }
        }
    }

    private func handleRewriteResult(messageID: String, rewritten: String) {
        // Only accept the result if this was still our target (didn't
        // get cancelled + retargeted to a different item between the
        // completion and this callback).
        guard rewriterTargetID == messageID else { return }
        rewriterTask = nil
        rewriterTargetID = nil

        if let idx = queue.firstIndex(where: { $0.id == messageID }) {
            queue[idx].rewriteState = .ready(rewritten)
        }

        // Start on the next .pending item (if any), then try promoting.
        startRewriterIfNeeded()
        promoteHeadIfReady()
    }

    private func promoteHeadIfReady() {
        guard playbackState.activePlayback == nil else { return }
        guard let head = queue.first, case let .ready(text) = head.rewriteState else { return }

        // Pop head out of the queue and start playback.
        queue.removeFirst()
        speak(text: text, item: head)
    }

    // Build a SpeechRequest from a PendingSpeechItem's ready state and
    // start the driver. Voice + rate are looked up via the providers
    // at this moment — NOT captured at insert time — so mid-queue
    // backend switches and rate changes take effect for the next
    // item without needing to invalidate the queue.
    private func speak(text: String, item: PendingSpeechItem) {
        // messageID stays the real ID (event routing, Now Playing,
        // dedup all key on it); only the spoken text carries the cue.
        let request = SpeechRequest(
            playbackID: UUID(),
            messageID: item.id,
            text: attributedText(text, for: item),
            voiceIdentifier: voiceIdentifierProvider(),
            wordsPerMinute: wordsPerMinuteProvider()
        )
        let driver = currentDriver
        let activePlayback = ActivePlayback(
            request: request,
            backend: backend,
            messageID: item.id,
            sessionID: item.sessionID
        )

        do {
            try driver.start(
                request: request,
                eventHandler: handleDriverEvent(_:)
            )
            // Advance the attribution frontier only once playback has
            // actually started — a failed start never reached the ear,
            // so the next item should still transition from the prior
            // session, not this one.
            lastPlayedSessionID = item.sessionID
            playbackState = .speaking(activePlayback)
        } catch {
            logger.error(
                "Playback failed to start for \(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            showPlaybackError(error.localizedDescription)
            playbackState = .idle
            // Failure drops the current attempt; try promoting the
            // next queued ready item instead of stranding the rest.
            promoteHeadIfReady()
        }
    }

    // Prepend "From <label>." when this item comes from a different
    // session than the last thing spoken, so a listener can follow a
    // queue that interleaves sessions. No cue on the first utterance
    // of a stream (lastPlayedSessionID == nil) or within one session.
    private func attributedText(_ text: String, for item: PendingSpeechItem) -> String {
        guard shouldAttribute(item) else { return text }
        guard let label = sessionLabelProvider(item.sessionID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !label.isEmpty else {
            return text
        }
        return "From \(label). \(text)"
    }

    private func shouldAttribute(_ item: PendingSpeechItem) -> Bool {
        guard let previous = lastPlayedSessionID else {
            // No prior context (stream start, or just after stop()).
            // Only orient the listener when the source is genuinely
            // ambiguous — more than one session can auto-speak.
            return shouldAttributeFirstUtteranceProvider()
        }
        return previous != item.sessionID
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
        case .systemVoice:
            return systemVoiceDriver
        case .elevenLabs:
            return elevenLabsDriver
        }
    }

    private func clearQueueAndRewriter() {
        queue.removeAll()
        cancelRewriterIfRunning()
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

        playbackState = .idle
        promoteHeadIfReady()
    }

    private func handleDriverEvent(_ event: SpeechDriverEvent) {
        guard let activePlayback = playbackState.activePlayback,
              activePlayback.request.playbackID == event.playbackID else {
            return
        }

        switch event {
        case .didStart:
            dismissPlaybackError()
            playbackState = .speaking(activePlayback)
        case .didResume:
            playbackState = .speaking(activePlayback)
        case .didPause:
            playbackState = .paused(activePlayback)
        case .didFinish:
            finishCurrentPlayback(playbackID: activePlayback.request.playbackID)
        case let .didFail(_, description):
            logger.error(
                "Playback failed for \(activePlayback.messageID, privacy: .public): \(description, privacy: .public)"
            )
            showPlaybackError(description)
            finishCurrentPlayback(playbackID: activePlayback.request.playbackID)
        }
    }
}
