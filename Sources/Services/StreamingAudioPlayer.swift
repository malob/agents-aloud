import AVFoundation
import Foundation
import OSLog

// Streaming PCM audio player built on AVAudioEngine + AVAudioPlayerNode.
// Consumes chunks of 16-bit little-endian PCM from an AsyncThrowingStream
// (as delivered by ElevenLabsClient.streamSynthesize) and schedules each
// chunk on the player node as an AVAudioPCMBuffer.
//
// Why hand-roll: we need pause/resume. AVAudioEngine + AVAudioPlayerNode
// support that natively; wrapping them in a streaming-friendly shell
// was the simplest path.
//
// The graph routes through an AVAudioUnitTimePitch stage
// (player → mixer → timePitch → output) so playback rate is decoupled
// from generation rate. ElevenLabs' voice_settings.speed only accepts
// 0.7–1.2 — far below the WPM slider's ceiling — but TTS generation
// streams faster than realtime, so stretching TIME at playback (with
// pitch preserved; same mechanism as 2× in Podcasts) delivers the
// full slider range regardless of the API cap. See init() for why the
// stage sits after the mixer.
//
// Usage pattern from the driver:
//   let player = StreamingAudioPlayer()
//   try player.play(stream: ..., sampleRate: ElevenLabsClient.pcmSampleRate,
//                   rate: 2.0, onFinish: { ... }, onError: { error in ... })
//   player.pause() / player.resume() / player.stop()
//
// Callbacks are invoked on the main actor. After onFinish or onError
// fires the player returns to idle; you can call play() again.
@MainActor
final class StreamingAudioPlayer {
    // Clamp bounds for the playback-rate multiplier. The unit itself
    // accepts 1/32–32, but speech below 0.5× drags unintelligibly and
    // above 4× turns to mush even with pitch correction — values
    // outside this range are always a caller bug, not a preference.
    nonisolated static let minimumPlaybackRate = 0.5
    nonisolated static let maximumPlaybackRate = 4.0

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let logger = Logger(subsystem: "local.claudecodevoice", category: "StreamingAudioPlayer")

    // Mutable bookkeeping for one playback session. Bundled into a class
    // so we can mutate scheduledBufferCount/streamEnded from callbacks
    // without having to unpack the enum's associated value, and so late
    // callbacks from a superseded session can compare identity (`===`) or
    // the monotonic `id` rather than tracking a parallel sessionID field.
    private final class Session {
        let id: Int
        var consumeTask: Task<Void, Never>?
        var scheduledBufferCount = 0
        var streamEnded = false
        let onFinish: @MainActor () -> Void
        let onError: @MainActor (Error) -> Void

        init(
            id: Int,
            onFinish: @escaping @MainActor () -> Void,
            onError: @escaping @MainActor (Error) -> Void
        ) {
            self.id = id
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
        case engineStartFailed(description: String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedFormat(sampleRate):
                return "Unsupported audio format (sample rate \(sampleRate))."
            case let .engineStartFailed(description):
                return "Audio engine failed to start: \(description)"
            }
        }
    }

    init() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        // The time-pitch stage sits AFTER the mixer
        // (player → mixer → timePitch → output), not between player and
        // mixer: effect audio units only accept standard float formats,
        // and our scheduled buffers are raw interleaved Int16 — wiring
        // player → timePitch directly throws
        // kAudioUnitErr_FormatNotSupported as an NSException. The mixer
        // does the int→float conversion for free, and timePitch then
        // stretches the mixed signal on its way to the output. Only the
        // player feeds the mixer, so stretching "everything" is
        // equivalent to stretching the one utterance.
        engine.connect(engine.mainMixerNode, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.outputNode, format: nil)
    }

    // Throws synchronously on format/engine setup failure; otherwise
    // returns immediately and delivers completion via onFinish / onError.
    // `rate` is a playback-speed multiplier (1.0 = as generated),
    // applied via the time-pitch stage so pitch is preserved. Fixed
    // for the duration of one utterance — matching how voice/rate are
    // resolved per-item at speak() time.
    func play(
        stream: AsyncThrowingStream<Data, Error>,
        sampleRate: Double,
        rate: Double = 1.0,
        onFinish: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) throws {
        teardownWithoutCallback()

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw PlayerError.unsupportedFormat(sampleRate: sampleRate)
        }

        timePitch.rate = Float(min(max(rate, Self.minimumPlaybackRate), Self.maximumPlaybackRate))
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            throw PlayerError.engineStartFailed(description: error.localizedDescription)
        }
        playerNode.play()

        nextSessionID &+= 1
        let session = Session(id: nextSessionID, onFinish: onFinish, onError: onError)
        state = .playing(session)

        let sessionID = session.id
        session.consumeTask = Task { @MainActor [weak self] in
            do {
                for try await chunk in stream {
                    if Task.isCancelled { return }
                    self?.schedule(chunk: chunk, format: format, sessionID: sessionID)
                }
                self?.markStreamEnded(sessionID: sessionID)
            } catch {
                self?.reportError(error, sessionID: sessionID)
            }
        }
    }

    func pause() {
        guard case let .playing(session) = state else { return }
        playerNode.pause()
        state = .paused(session)
    }

    func resume() {
        guard case let .paused(session) = state else { return }
        playerNode.play()
        state = .playing(session)
    }

    // Neither onFinish nor onError fires after stop().
    func stop() {
        teardownWithoutCallback()
    }

    // MARK: -

    private func schedule(chunk: Data, format: AVAudioFormat, sessionID: Int) {
        guard let session = state.session, session.id == sessionID else { return }
        guard let buffer = Self.makeBuffer(from: chunk, format: format) else { return }
        session.scheduledBufferCount += 1
        // The completion handler runs off the main actor on AVFoundation's
        // audio thread; hop back to @MainActor to mutate state.
        //
        // .dataPlayedBack, NOT the legacy scheduleBuffer(_:completionHandler:):
        // the legacy form fires when the buffer has been CONSUMED by the
        // render pipeline, which for the final buffer is up to a couple
        // hundred ms before the audio is audible at the output. Finishing
        // on consumption tears the engine down (and starts the next queued
        // utterance) while the tail of the last word is still in flight —
        // audibly clipping the end of every ElevenLabs utterance.
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.bufferCompleted(sessionID: sessionID)
            }
        }
    }

    private func bufferCompleted(sessionID: Int) {
        guard let session = state.session, session.id == sessionID else { return }
        session.scheduledBufferCount -= 1
        if session.streamEnded && session.scheduledBufferCount <= 0 {
            finishAndCallback()
        }
    }

    private func markStreamEnded(sessionID: Int) {
        guard let session = state.session, session.id == sessionID else { return }
        session.streamEnded = true
        if session.scheduledBufferCount <= 0 {
            finishAndCallback()
        }
    }

    private func reportError(_ error: Error, sessionID: Int) {
        guard let session = state.session, session.id == sessionID else { return }
        let callback = session.onError
        teardownWithoutCallback()
        callback(error)
    }

    private func finishAndCallback() {
        guard let session = state.session else { return }
        let callback = session.onFinish
        teardownWithoutCallback()
        callback()
    }

    // Shared teardown path. Goes to .idle and cancels the stream-consumer
    // task; any late audio-thread callbacks that capture the old session's
    // id will see a different session.id (or idle state) in state.session
    // and no-op.
    private func teardownWithoutCallback() {
        if let session = state.session {
            session.consumeTask?.cancel()
        }
        if playerNode.isPlaying || !state.isIdle {
            playerNode.stop()
        }
        if engine.isRunning {
            engine.stop()
        }
        state = .idle
    }

    private static func makeBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleBytes = MemoryLayout<Int16>.size
        let frameCount = AVAudioFrameCount(data.count / sampleBytes)
        guard frameCount > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        // Copy first, then publish frameLength. If either pointer is nil
        // (int16ChannelData can be nil for e.g. non-interleaved formats or
        // zero-frame buffers), return nil so the caller drops the chunk
        // rather than schedule a buffer full of uninitialized memory.
        let copied = data.withUnsafeBytes { raw -> Bool in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: Int16.self),
                  let dst = buffer.int16ChannelData?.pointee else {
                return false
            }
            dst.update(from: src, count: Int(frameCount))
            return true
        }
        guard copied else { return nil }
        buffer.frameLength = frameCount
        return buffer
    }
}
