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
// Usage pattern from the driver:
//   let player = StreamingAudioPlayer()
//   try player.play(stream: ..., sampleRate: ElevenLabsClient.pcmSampleRate,
//                   onFinish: { ... }, onError: { error in ... })
//   player.pause() / player.resume() / player.stop()
//
// Callbacks are invoked on the main actor. After onFinish or onError
// fires the player returns to idle; you can call play() again.
@MainActor
final class StreamingAudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let logger = Logger(subsystem: "local.claudecodevoice", category: "StreamingAudioPlayer")

    private var consumeTask: Task<Void, Never>?
    private var scheduledBufferCount = 0
    private var streamEnded = false
    private var onFinish: (() -> Void)?
    private var onError: ((Error) -> Void)?
    private var sessionID = 0  // ignore late events from superseded sessions

    enum State {
        case idle
        case playing
        case paused
    }
    private(set) var state: State = .idle

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
    }

    // Throws synchronously on format/engine setup failure; otherwise
    // returns immediately and delivers completion via onFinish / onError.
    func play(
        stream: AsyncThrowingStream<Data, Error>,
        sampleRate: Double,
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

        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            throw PlayerError.engineStartFailed(description: error.localizedDescription)
        }
        playerNode.play()

        self.onFinish = onFinish
        self.onError = onError
        state = .playing
        sessionID &+= 1
        let localSessionID = sessionID

        consumeTask = Task { @MainActor [weak self] in
            do {
                for try await chunk in stream {
                    if Task.isCancelled { return }
                    self?.schedule(chunk: chunk, format: format, sessionID: localSessionID)
                }
                self?.markStreamEnded(sessionID: localSessionID)
            } catch {
                self?.reportError(error, sessionID: localSessionID)
            }
        }
    }

    func pause() {
        guard state == .playing else { return }
        playerNode.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        playerNode.play()
        state = .playing
    }

    // Neither onFinish nor onError fires after stop().
    func stop() {
        teardownWithoutCallback()
    }

    // MARK: -

    private func schedule(chunk: Data, format: AVAudioFormat, sessionID: Int) {
        guard sessionID == self.sessionID else { return }
        guard let buffer = Self.makeBuffer(from: chunk, format: format) else { return }
        scheduledBufferCount += 1
        // The completion handler runs off the main actor on AVFoundation's
        // audio thread; hop back to @MainActor to mutate state.
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                self?.bufferCompleted(sessionID: sessionID)
            }
        }
    }

    private func bufferCompleted(sessionID: Int) {
        guard sessionID == self.sessionID else { return }
        scheduledBufferCount -= 1
        if streamEnded && scheduledBufferCount <= 0 {
            finishAndCallback()
        }
    }

    private func markStreamEnded(sessionID: Int) {
        guard sessionID == self.sessionID else { return }
        streamEnded = true
        if scheduledBufferCount <= 0 {
            finishAndCallback()
        }
    }

    private func reportError(_ error: Error, sessionID: Int) {
        guard sessionID == self.sessionID else { return }
        let callback = onError
        teardownWithoutCallback()
        callback?(error)
    }

    private func finishAndCallback() {
        let callback = onFinish
        teardownWithoutCallback()
        callback?()
    }

    // Shared teardown path. Invalidates the current session so any late
    // audio-thread callbacks or in-flight stream chunks no-op.
    private func teardownWithoutCallback() {
        sessionID &+= 1
        consumeTask?.cancel()
        consumeTask = nil
        scheduledBufferCount = 0
        streamEnded = false
        onFinish = nil
        onError = nil
        if playerNode.isPlaying || state != .idle {
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
