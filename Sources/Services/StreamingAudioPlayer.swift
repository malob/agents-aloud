import AppKit
import AVFoundation
import CoreMedia
import Foundation
import OSLog

// Streaming PCM audio player built on AVSampleBufferAudioRenderer +
// AVSampleBufferRenderSynchronizer. Consumes chunks of 16-bit
// little-endian PCM from an AsyncThrowingStream (as delivered by
// ElevenLabsClient.streamSynthesize), wraps each chunk in a
// CMSampleBuffer stamped with a running sample-count timestamp, and
// lets the renderer play them at the synchronizer's rate.
//
// Why this stack (history): v1 used AVAudioEngine + AVAudioPlayerNode
// with an AVAudioUnitTimePitch stage for rate control. That unit is a
// phase-vocoder stretcher; at 2x+ rates speech takes on the family's
// signature "phasiness" — hollow / tinny / phone-line coloration from
// harmonics losing phase lock — and maxing its overlap parameter only
// reduced it. The renderer stack exposes
// AVAudioTimePitchAlgorithm.timeDomain, Apple's voice-optimized
// WSOLA-family stretcher (the kind podcast apps use), which keeps a
// single voice's harmonics phase-locked at speed. Don't swap back to
// an engine graph without re-listening at 2.3x.
//
// Rate semantics: synchronizer.rate IS the playback-speed multiplier;
// the .timeDomain algorithm pitch-corrects. Rate is fixed per
// utterance at play() time, matching how voice/rate resolve per item.
//
// Clock-start subtlety (load-bearing): the synchronizer's timebase
// runs in real time regardless of whether the renderer has data.
// Starting it inside play() would let the network's time-to-first-
// byte (~300-500ms) advance the clock past the first buffers'
// timestamps and clip the start of every utterance. The timebase
// therefore starts only when the FIRST chunk is enqueued. Mid-stream
// underruns (delivery slower than consumption) would similarly drop
// late audio; TTS generation outpaces even 2-3x playback in practice,
// so late buffers are logged rather than buffered. If that warning
// ever shows up in Console, the fix is a jitter buffer: pause the
// timebase until the queue catches up.
//
// Callbacks are invoked on the main actor. After onFinish or onError
// fires the player returns to idle; you can call play() again.
@MainActor
final class StreamingAudioPlayer {
    // Clamp bounds for the playback-rate multiplier. Speech below
    // 0.5x drags unintelligibly and above 4x turns to mush even with
    // pitch correction — values outside this range are always a
    // caller bug, not a preference.
    nonisolated static let minimumPlaybackRate = 0.5
    nonisolated static let maximumPlaybackRate = 4.0

    // var, not let: the renderer + synchronizer are rebuilt fresh for
    // every utterance (see rebuildPipeline). macOS silently invalidates
    // an idle/paused AVSampleBufferAudioRenderer — after system sleep, an
    // output-device power-down, or an automatic flush — and a wedged
    // renderer keeps its synchronizer clock advancing (so playback
    // "completes") while emitting nothing. A single renderer reused for
    // the app's lifetime therefore meant one long pause wedged ALL
    // subsequent playback until relaunch.
    private var renderer = AVSampleBufferAudioRenderer()
    private var synchronizer = AVSampleBufferRenderSynchronizer()
    private let logger = Logger(subsystem: "local.claudecodevoice", category: "StreamingAudioPlayer")
    private var rendererStatusObservation: NSKeyValueObservation?

    // Mutable bookkeeping for one playback session. Bundled into a
    // class so callbacks can compare identity via the monotonic `id`;
    // late callbacks from a superseded session see a different id (or
    // idle state) and no-op.
    private final class Session {
        let id: Int
        let sampleRate: Double
        let playbackRate: Double
        let formatDescription: CMAudioFormatDescription
        var consumeTask: Task<Void, Never>?
        var streamEnded = false
        // Whether the synchronizer's timebase has been started for
        // this session. See the clock-start subtlety in the header.
        var clockStarted = false
        // Running count of enqueued PCM frames — doubles as the next
        // buffer's presentation timestamp and, once the stream ends,
        // the end-of-media time.
        var enqueuedSamples: Int64 = 0
        // Every enqueued PCM chunk, retained in order so the utterance
        // can be re-enqueued into a fresh renderer if macOS flushes the
        // current one out from under us (sleep/wake, route change). One
        // utterance's PCM only — released when the session ends.
        var rawChunks: [Data] = []
        var boundaryObserver: Any?
        let onFinish: @MainActor () -> Void
        let onError: @MainActor (Error) -> Void

        init(
            id: Int,
            sampleRate: Double,
            playbackRate: Double,
            formatDescription: CMAudioFormatDescription,
            onFinish: @escaping @MainActor () -> Void,
            onError: @escaping @MainActor (Error) -> Void
        ) {
            self.id = id
            self.sampleRate = sampleRate
            self.playbackRate = playbackRate
            self.formatDescription = formatDescription
            self.onFinish = onFinish
            self.onError = onError
        }
    }

    private enum State {
        case idle
        case playing(Session)
        case paused(Session)

        var session: Session? {
            switch self {
            case .idle:
                return nil
            case let .playing(session), let .paused(session):
                return session
            }
        }

        var isIdle: Bool {
            if case .idle = self {
                return true
            }
            return false
        }
    }

    private var state: State = .idle
    private var nextSessionID = 0

    var isIdle: Bool { state.isIdle }
    var isPlaying: Bool {
        if case .playing = state { return true }
        return false
    }
    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    enum PlayerError: LocalizedError, Equatable {
        case unsupportedFormat(sampleRate: Double)
        case rendererFailed

        var errorDescription: String? {
            switch self {
            case let .unsupportedFormat(sampleRate):
                return "Unsupported audio format (sample rate \(sampleRate))."
            case .rendererFailed:
                return "Audio renderer failed."
            }
        }
    }

    init() {
        configurePipeline()
        registerSystemAudioObservers()
    }

    // Wire up the current renderer + synchronizer. Re-run after every
    // rebuildPipeline() so the fresh renderer gets the time-domain
    // stretcher and the failed-status observation.
    private func configurePipeline() {
        renderer.audioTimePitchAlgorithm = .timeDomain
        synchronizer.addRenderer(renderer)
        // PCM essentially can't fail to decode, but surface a failed
        // renderer rather than hanging silently with no finish/error.
        rendererStatusObservation = renderer.observe(\.status, options: [.new]) { [weak self] renderer, _ in
            guard renderer.status == .failed else { return }
            let error = renderer.error
            Task { @MainActor [weak self] in
                self?.handleRendererFailure(error)
            }
        }
    }

    // Discard the current renderer/synchronizer and stand up a fresh
    // pair. Called at the top of every play() so a renderer that macOS
    // silently tore down during a prior pause can't poison the next
    // utterance — the failure is contained to at most the one paused
    // utterance instead of persisting until app relaunch.
    private func rebuildPipeline() {
        rendererStatusObservation?.invalidate()
        rendererStatusObservation = nil
        synchronizer.rate = 0
        renderer = AVSampleBufferAudioRenderer()
        synchronizer = AVSampleBufferRenderSynchronizer()
        configurePipeline()
    }

    // Diagnostic only (no behavior): log the system events that
    // silently invalidate an idle renderer, so a reproduced "resume →
    // silence" can be tied to its trigger in Console. Closures capture
    // only the Sendable logger — never self — so they're concurrency-
    // safe and harmless if they outlive the player.
    private func registerSystemAudioObservers() {
        let log = logger
        // Referenced by raw name: the Swift-imported symbol for this
        // constant isn't stable across SDKs, but the notification name
        // string is.
        autoFlushObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Delivered on .main (queue: .main above), so assumeIsolated
            // is valid. Carry only the renderer's identity across the
            // actor hop (ObjectIdentifier is Sendable; the renderer
            // itself isn't) so recovery can confirm the flush was for
            // the renderer we're actively using.
            let flushedID = (note.object as? AVSampleBufferAudioRenderer).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                self?.handleAutomaticFlush(flushedRendererID: flushedID)
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObserver = workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in log.info("System willSleep") }
        wakeObserver = workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in log.info("System didWake") }
    }

    private var autoFlushObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    // Throws synchronously on format setup failure; otherwise returns
    // immediately and delivers completion via onFinish / onError.
    // `rate` is a playback-speed multiplier (1.0 = as generated),
    // applied via the synchronizer with pitch preserved.
    func play(
        stream: AsyncThrowingStream<Data, Error>,
        sampleRate: Double,
        rate: Double = 1.0,
        onFinish: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) throws {
        teardownWithoutCallback()
        // Every utterance starts on a freshly-built renderer so a
        // pipeline macOS invalidated during a prior pause can't make
        // this one play silently.
        rebuildPipeline()

        guard let formatDescription = Self.makePCMFormatDescription(sampleRate: sampleRate) else {
            throw PlayerError.unsupportedFormat(sampleRate: sampleRate)
        }

        nextSessionID &+= 1
        let session = Session(
            id: nextSessionID,
            sampleRate: sampleRate,
            playbackRate: min(max(rate, Self.minimumPlaybackRate), Self.maximumPlaybackRate),
            formatDescription: formatDescription,
            onFinish: onFinish,
            onError: onError
        )
        state = .playing(session)

        let sessionID = session.id
        session.consumeTask = Task { @MainActor [weak self] in
            do {
                for try await chunk in stream {
                    if Task.isCancelled { return }
                    self?.enqueue(chunk: chunk, sessionID: sessionID)
                }
                self?.markStreamEnded(sessionID: sessionID)
            } catch {
                self?.reportError(error, sessionID: sessionID)
            }
        }
    }

    func pause() {
        guard case let .playing(session) = state else { return }
        synchronizer.rate = 0
        state = .paused(session)
    }

    func resume() {
        guard case let .paused(session) = state else { return }
        // Diagnostic: a silent resume after a long pause originates
        // here. status != .rendering or a preceding auto-flush log
        // pinpoints the wedge.
        logger.info("resume(): renderer status=\(self.renderer.status.rawValue, privacy: .public) clockStarted=\(session.clockStarted, privacy: .public)")
        state = .playing(session)
        if session.clockStarted {
            synchronizer.rate = Float(session.playbackRate)
        } else {
            // Paused through the entire pre-first-byte window (or the
            // whole stream arrived while paused): start now if there's
            // anything to play.
            maybeStartClock(session)
        }
    }

    // Neither onFinish nor onError fires after stop().
    func stop() {
        teardownWithoutCallback()
    }

    // MARK: - Stream consumption

    private func enqueue(chunk: Data, sessionID: Int) {
        guard let session = state.session, session.id == sessionID else { return }
        let frameCount = chunk.count / MemoryLayout<Int16>.size
        guard frameCount > 0 else { return }

        guard let sampleBuffer = Self.makeSampleBuffer(
            from: chunk,
            frameCount: frameCount,
            format: session.formatDescription,
            presentationSamples: session.enqueuedSamples,
            sampleRate: session.sampleRate
        ) else {
            logger.error("Dropping audio chunk: CMSampleBuffer creation failed")
            return
        }

        if session.clockStarted {
            let pts = CMTime(value: session.enqueuedSamples, timescale: CMTimeScale(session.sampleRate))
            if synchronizer.currentTime() > pts {
                // See the underrun note in the header — late audio is
                // clipped by the running clock. Loud so a real-world
                // occurrence prompts the jitter-buffer fix.
                logger.warning("Audio chunk arrived behind the playback clock; start of chunk may be clipped")
            }
        }

        renderer.enqueue(sampleBuffer)
        session.enqueuedSamples += Int64(frameCount)
        // Retain in lockstep with enqueuedSamples so a flush-recovery
        // can replay exactly these chunks and reproduce identical PTSs.
        session.rawChunks.append(chunk)
        maybeStartClock(session)
    }

    // Start the timebase once the first audio exists, and only while
    // actually in the playing state (the user may have paused during
    // the pre-first-byte window).
    private func maybeStartClock(_ session: Session) {
        guard case let .playing(current) = state, current.id == session.id else { return }
        guard !session.clockStarted, session.enqueuedSamples > 0 else { return }
        session.clockStarted = true
        synchronizer.setRate(Float(session.playbackRate), time: .zero)
    }

    private func markStreamEnded(sessionID: Int) {
        guard let session = state.session, session.id == sessionID else { return }
        session.streamEnded = true

        guard session.enqueuedSamples > 0 else {
            // Stream produced no audio at all — finish immediately.
            finishAndCallback()
            return
        }

        let end = CMTime(value: session.enqueuedSamples, timescale: CMTimeScale(session.sampleRate))
        if session.clockStarted, synchronizer.currentTime() >= end {
            finishAndCallback()
            return
        }

        armEndBoundaryObserver(session: session)
    }

    // Install the end-of-media boundary observer. Factored out of
    // markStreamEnded so flush-recovery can re-arm it on the rebuilt
    // synchronizer (the prior observer died with the discarded one).
    // Caller must clear session.boundaryObserver first when the old
    // synchronizer is gone. Boundary observers run on media time, so
    // rate changes and pauses are accounted for automatically.
    private func armEndBoundaryObserver(session: Session) {
        let end = CMTime(value: session.enqueuedSamples, timescale: CMTimeScale(session.sampleRate))
        let id = session.id
        session.boundaryObserver = synchronizer.addBoundaryTimeObserver(
            forTimes: [NSValue(time: end)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.boundaryReached(sessionID: id)
            }
        }

        // A boundary already in the past never fires; boundaryReached is
        // idempotent via the session-identity guard, so calling it
        // directly here covers the clock-already-past-end case.
        if session.clockStarted, synchronizer.currentTime() >= end {
            boundaryReached(sessionID: id)
        }
    }

    // macOS automatically flushes an idle/paused AVSampleBufferAudioRenderer
    // (after sleep/wake or an output-device/route change) WITHOUT marking
    // it .failed — the synchronizer's clock keeps advancing while the
    // dropped buffers leave only silence, so a plain resume() plays
    // nothing. Recover by rebuilding the pipeline, replaying the
    // utterance's retained PCM, and restoring the clock to the position
    // playback had reached — so resume continues instead of going silent.
    private func handleAutomaticFlush(flushedRendererID: ObjectIdentifier?) {
        guard let flushedRendererID, flushedRendererID == ObjectIdentifier(renderer) else { return }
        guard let session = state.session else { return }

        let wasPlaying = isPlaying
        let resumeTime = session.clockStarted ? synchronizer.currentTime() : .zero
        logger.warning("Recovering from automatic flush: replaying \(session.rawChunks.count, privacy: .public) chunks at \(resumeTime.seconds, privacy: .public)s (wasPlaying=\(wasPlaying, privacy: .public))")

        rebuildPipeline()

        var offset: Int64 = 0
        for chunk in session.rawChunks {
            let frameCount = chunk.count / MemoryLayout<Int16>.size
            guard frameCount > 0,
                  let buffer = Self.makeSampleBuffer(
                      from: chunk,
                      frameCount: frameCount,
                      format: session.formatDescription,
                      presentationSamples: offset,
                      sampleRate: session.sampleRate
                  ) else { continue }
            renderer.enqueue(buffer)
            offset += Int64(frameCount)
        }

        // Restore the timebase first so the re-armed boundary observer's
        // past-end check sees the correct position.
        if session.clockStarted {
            synchronizer.setRate(wasPlaying ? Float(session.playbackRate) : 0, time: resumeTime)
        } else if wasPlaying {
            maybeStartClock(session)
        }

        // The prior observer was tied to the now-discarded synchronizer.
        session.boundaryObserver = nil
        if session.streamEnded {
            armEndBoundaryObserver(session: session)
        }
    }

    private func boundaryReached(sessionID: Int) {
        guard let session = state.session, session.id == sessionID else { return }
        finishAndCallback()
    }

    private func reportError(_ error: Error, sessionID: Int) {
        guard let session = state.session, session.id == sessionID else { return }
        let callback = session.onError
        teardownWithoutCallback()
        callback(error)
    }

    private func handleRendererFailure(_ error: Error?) {
        guard let session = state.session else { return }
        reportError(error ?? PlayerError.rendererFailed, sessionID: session.id)
    }

    private func finishAndCallback() {
        guard let session = state.session else { return }
        let callback = session.onFinish
        teardownWithoutCallback()
        callback()
    }

    // Shared teardown path. Goes to .idle, cancels the stream-consumer
    // task, removes the boundary observer, and flushes the renderer;
    // any late callbacks that captured the old session's id see a
    // different id (or idle state) in state.session and no-op.
    private func teardownWithoutCallback() {
        if let session = state.session {
            session.consumeTask?.cancel()
            if let observer = session.boundaryObserver {
                synchronizer.removeTimeObserver(observer)
                session.boundaryObserver = nil
            }
        }
        synchronizer.rate = 0
        renderer.flush()
        state = .idle
    }

    // MARK: - CoreMedia plumbing

    nonisolated private static func makePCMFormatDescription(sampleRate: Double) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        return status == noErr ? formatDescription : nil
    }

    nonisolated private static func makeSampleBuffer(
        from data: Data,
        frameCount: Int,
        format: CMAudioFormatDescription,
        presentationSamples: Int64,
        sampleRate: Double
    ) -> CMSampleBuffer? {
        // frameCount * 2 can be one byte short of data.count for an
        // odd-length chunk; the trailing byte is dropped, same as the
        // old AVAudioPCMBuffer path. Chunk boundaries are arbitrary
        // byte counts but the client emits fixed 4096-byte chunks, so
        // this is theoretical.
        let byteCount = frameCount * MemoryLayout<Int16>.size

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }

        let copyStatus = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: CMTime(value: presentationSamples, timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }
}
