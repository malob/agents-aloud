import Foundation
import Testing
@testable import ClaudeCodeVoice

// Tests spawn /bin/sh with inline scripts in place of /usr/bin/say to
// exercise lifecycle behavior (normal exit, error exit, stop-mid-run,
// start-while-running) without playing audio on the test machine.
//
// The tests exercise the real subprocess path — terminationHandler,
// stdin pipe, stderr capture — so they're covering the integration
// rather than mocking internals.

@MainActor
private final class EventRecorder {
    private(set) var events: [SpeechDriverEvent] = []

    var handler: @MainActor @Sendable (SpeechDriverEvent) -> Void {
        { [weak self] event in
            self?.events.append(event)
        }
    }
}

@MainActor
private func shellScriptDriver(_ script: String) -> SystemVoiceBackendDriver {
    SystemVoiceBackendDriver(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script]
    )
}

private func request(_ text: String = "hi") -> SpeechRequest {
    SpeechRequest(
        playbackID: UUID(),
        messageID: "m-\(UUID().uuidString)",
        text: text,
        voiceIdentifier: nil,
        rate: 0.4
    )
}

struct SystemVoiceBackendDriverTests {

    @Test
    @MainActor
    func startEmitsDidStartSynchronously() throws {
        let driver = shellScriptDriver("cat > /dev/null; exit 0")
        let recorder = EventRecorder()
        let req = request()

        try driver.start(request: req, eventHandler: recorder.handler)

        #expect(recorder.events.first == .didStart(req.playbackID))
    }

    @Test
    @MainActor
    func normalExitEmitsDidFinish() async throws {
        let driver = shellScriptDriver("cat > /dev/null; exit 0")
        let recorder = EventRecorder()
        let req = request()

        try driver.start(request: req, eventHandler: recorder.handler)

        try await waitUntil(timeout: .seconds(3)) {
            recorder.events.contains(.didFinish(req.playbackID))
        }
    }

    @Test
    @MainActor
    func nonZeroExitEmitsDidFailWithCapturedStderr() async throws {
        // Capture a distinctive marker in stderr so we can verify the
        // driver forwards the actual stderr content (not the fallback).
        let driver = shellScriptDriver(#"cat > /dev/null; echo "boom-marker" >&2; exit 42"#)
        let recorder = EventRecorder()
        let req = request()

        try driver.start(request: req, eventHandler: recorder.handler)

        try await waitUntil(timeout: .seconds(3)) {
            recorder.events.contains(where: { if case .didFail = $0 { return true } else { return false } })
        }

        let failEvent = recorder.events.first { if case .didFail = $0 { return true } else { return false } }
        if case let .didFail(id, description) = failEvent {
            #expect(id == req.playbackID)
            #expect(description.contains("boom-marker"))
        } else {
            Issue.record("expected .didFail, got \(recorder.events)")
        }
    }

    @Test
    @MainActor
    func stopSuppressesDidFinishAndDidFail() async throws {
        // Long-running script: read stdin, then sleep. We'll stop it
        // while it's still sleeping — the termination handler should
        // see outcome == .interruptedByApp and NOT emit any event.
        let driver = shellScriptDriver("cat > /dev/null; sleep 10; exit 0")
        let recorder = EventRecorder()
        let req = request()

        try driver.start(request: req, eventHandler: recorder.handler)

        // Give the process a beat to start + read stdin.
        try await Task.sleep(for: .milliseconds(150))

        driver.stop()

        // Wait long enough for the subprocess to fully exit after
        // termination so the terminationHandler has had its chance to fire.
        try await Task.sleep(for: .milliseconds(400))

        let post = recorder.events.dropFirst()  // drop the initial .didStart
        #expect(!post.contains(.didFinish(req.playbackID)))
        #expect(
            !post.contains(where: {
                if case .didFail = $0, $0.playbackID == req.playbackID { return true } else { return false }
            })
        )
    }

    @Test
    @MainActor
    func startWhileRunningTerminatesThePriorJob() async throws {
        // First job: sleeps indefinitely. Second start() should terminate
        // it and fire .didStart for the new playbackID. The old job's
        // termination should NOT emit .didFinish (it was interrupted).
        let driver = shellScriptDriver("cat > /dev/null; sleep 10; exit 0")
        let recorder = EventRecorder()
        let firstRequest = request("first")

        try driver.start(request: firstRequest, eventHandler: recorder.handler)
        try await Task.sleep(for: .milliseconds(150))

        let secondRequest = request("second")
        try driver.start(request: secondRequest, eventHandler: recorder.handler)

        // Second is /bin/sh -c "cat > /dev/null; exit 0" — but we reused
        // the same driver/script, so `second` is also long-running. Stop
        // it cleanly so the test doesn't hang.
        try await Task.sleep(for: .milliseconds(150))
        driver.stop()
        try await Task.sleep(for: .milliseconds(400))

        let starts = recorder.events.compactMap { event -> UUID? in
            if case let .didStart(id) = event { return id }
            return nil
        }
        #expect(starts.contains(firstRequest.playbackID))
        #expect(starts.contains(secondRequest.playbackID))
        // Neither request should have .didFinish because both were terminated.
        let finishes = recorder.events.compactMap { event -> UUID? in
            if case let .didFinish(id) = event { return id }
            return nil
        }
        #expect(!finishes.contains(firstRequest.playbackID))
        #expect(!finishes.contains(secondRequest.playbackID))
    }

    @Test
    @MainActor
    func pauseAndResumeEmitMatchingEvents() async throws {
        let driver = shellScriptDriver("cat > /dev/null; sleep 10; exit 0")
        let recorder = EventRecorder()
        let req = request()

        try driver.start(request: req, eventHandler: recorder.handler)
        try await Task.sleep(for: .milliseconds(100))

        driver.pause()
        driver.resume()

        #expect(recorder.events.contains(.didPause(req.playbackID)))
        #expect(recorder.events.contains(.didResume(req.playbackID)))

        driver.stop()
        try await Task.sleep(for: .milliseconds(200))
    }
}
