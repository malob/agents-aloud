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

    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
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

        // Fires when PLAYBACK reaches the end of the enqueued media —
        // boundary observers run on media time, so rate changes and
        // pauses are accounted for automatically.
        let id = session.id
        session.boundaryObserver = synchronizer.addBoundaryTimeObserver(
            forTimes: [NSValue(time: end)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.boundaryReached(sessionID: id)
            }
        }

        // The clock may have crossed `end` between the check above and
        // the observer landing; a boundary in the past never fires.
        // boundaryReached / finishAndCallback are idempotent via the
        // session-identity guard, so the double-call case is safe.
        if session.clockStarted, synchronizer.currentTime() >= end {
            boundaryReached(sessionID: id)
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
