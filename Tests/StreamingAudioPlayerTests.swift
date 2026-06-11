import Foundation
import Testing
@testable import ClaudeCodeVoice

struct StreamingAudioPlayerTests {
    // 0.1s of 44.1kHz mono 16-bit silence. Audibly nothing; safe to run
    // during `swift test` without speaker noise.
    private func silencePCM(milliseconds: Int) -> Data {
        let sampleRate = 44_100
        let sampleCount = (sampleRate * milliseconds) / 1000
        let zeros = [Int16](repeating: 0, count: sampleCount)
        return zeros.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    @Test
    @MainActor
    func playsShortStreamToCompletion() async throws {
        let player = StreamingAudioPlayer()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(silencePCM(milliseconds: 100))
        continuation.finish()

        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
            do {
                try player.play(
                    stream: stream,
                    sampleRate: 44_100,
                    onFinish: { cc.resume() },
                    onError: { cc.resume(throwing: $0) }
                )
            } catch {
                cc.resume(throwing: error)
            }
        }

        #expect(player.isIdle)
    }

    @Test
    @MainActor
    func playsToCompletionAtAcceleratedRate() async throws {
        // Exercises the time-pitch stage in the graph: if the
        // mixer → timePitch → output wiring is wrong, the engine fails
        // to start (or throws an NSException at connect time, as the
        // rejected player → timePitch Int16 wiring did) or the final
        // buffer's playedBack callback never fires and this test times
        // out instead of finishing.
        let player = StreamingAudioPlayer()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(silencePCM(milliseconds: 200))
        continuation.finish()

        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
            do {
                try player.play(
                    stream: stream,
                    sampleRate: 44_100,
                    rate: 2.0,
                    onFinish: { cc.resume() },
                    onError: { cc.resume(throwing: $0) }
                )
            } catch {
                cc.resume(throwing: error)
            }
        }

        #expect(player.isIdle)
    }

    @Test
    @MainActor
    func stopBeforeFinishSuppressesCallbacks() async throws {
        let player = StreamingAudioPlayer()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        // Large buffer so playback takes real time
        continuation.yield(silencePCM(milliseconds: 2_000))

        var finishedCalls = 0
        var errorCalls = 0
        try player.play(
            stream: stream,
            sampleRate: 44_100,
            onFinish: { finishedCalls += 1 },
            onError: { _ in errorCalls += 1 }
        )
        #expect(player.isPlaying)

        // Let a couple of buffers get scheduled, then stop.
        try await Task.sleep(for: .milliseconds(50))
        player.stop()
        continuation.finish()

        #expect(player.isIdle)

        // Wait past the natural completion time to confirm no late callback fires.
        try await Task.sleep(for: .milliseconds(200))
        #expect(finishedCalls == 0)
        #expect(errorCalls == 0)
    }

    @Test
    @MainActor
    func pauseAndResumeTransitionState() async throws {
        let player = StreamingAudioPlayer()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(silencePCM(milliseconds: 500))

        try player.play(
            stream: stream,
            sampleRate: 44_100,
            onFinish: {},
            onError: { _ in }
        )
        #expect(player.isPlaying)

        player.pause()
        #expect(player.isPaused)

        player.resume()
        #expect(player.isPlaying)

        // pause() from .paused should be a no-op, not a state flip
        player.pause()
        player.pause()
        #expect(player.isPaused)

        player.stop()
        continuation.finish()
        #expect(player.isIdle)
    }

    @Test
    @MainActor
    func streamErrorFiresOnError() async throws {
        struct SyntheticError: Error, Equatable {}

        let player = StreamingAudioPlayer()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(silencePCM(milliseconds: 20))
        continuation.finish(throwing: SyntheticError())

        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
            do {
                try player.play(
                    stream: stream,
                    sampleRate: 44_100,
                    onFinish: { cc.resume(throwing: SyntheticError()) },
                    onError: { _ in cc.resume() }
                )
            } catch {
                cc.resume(throwing: error)
            }
        }

        #expect(player.isIdle)
    }
}
