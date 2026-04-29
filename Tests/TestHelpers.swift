import Foundation
import Testing
@testable import ClaudeCodeVoice

// Poll a @MainActor-isolated condition until it becomes true or the timeout
// elapses. Preferred over a fixed `Task.sleep(for: .milliseconds(X))` when
// the goal is "wait for an async side effect to complete" — fixed sleeps are
// flaky on loaded CI machines (the side effect may not land in X ms),
// whereas polling returns as soon as the condition holds and only times out
// if something is actually wrong.
//
// Default `pollInterval: 25ms` balances responsiveness against wasted work.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(25),
    file: StaticString = #file,
    line: UInt = #line,
    _ condition: @MainActor @escaping () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }
        try await Task.sleep(for: pollInterval)
    }

    Issue.record("Timed out after \(timeout) waiting for condition")
}

// Shared fake driver for tests that need to drive SpeechController without
// playing real audio. Records started requests + pause/resume/stop calls so
// assertions can check what the controller routed to the driver.
@MainActor
final class FakeSpeechBackendDriver: SpeechBackendDriver {
    struct StartFailure: LocalizedError {
        let description: String
        var errorDescription: String? { description }
    }

    let availableVoices: [SpeechVoiceOption]
    private(set) var startedRequests: [SpeechRequest] = []
    private(set) var pauseCallCount = 0
    private(set) var resumeCallCount = 0
    private(set) var stopCallCount = 0
    var startError: Error?
    private var eventHandler: (@MainActor @Sendable (SpeechDriverEvent) -> Void)?

    init(availableVoices: [SpeechVoiceOption] = []) {
        self.availableVoices = availableVoices
    }

    func resolveVoiceIdentifier(_ identifier: String?) -> String? {
        if let identifier {
            return identifier
        }
        return availableVoices.first?.id
    }

    func start(
        request: SpeechRequest,
        eventHandler: @escaping @MainActor @Sendable (SpeechDriverEvent) -> Void
    ) throws {
        if let startError {
            throw startError
        }

        self.eventHandler = eventHandler
        startedRequests.append(request)
    }

    func pause() { pauseCallCount += 1 }
    func resume() { resumeCallCount += 1 }
    func stop() { stopCallCount += 1 }

    func emit(_ event: SpeechDriverEvent) {
        eventHandler?(event)
    }
}

// Slow fake processor for testing cancellation semantics. Awaits an
// external "release" signal before returning the processed text.
// Tests: spawn a playback, then trigger a user-intent change (stop,
// session switch, Live Speak off), then release — processed text
// should NOT reach the driver.
@MainActor
final class ControllableSpeechTextProcessor: SpeechTextProcessor {
    // `continuations` keyed by invocation id so a test can release
    // specific calls in order.
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var invocationCount = 0

    func process(text: String) async -> String {
        invocationCount += 1
        await withCheckedContinuation { cc in
            waiters.append(cc)
        }
        return text + " [processed]"
    }

    // Release the next-earliest pending process() call.
    func releaseNext() {
        guard !waiters.isEmpty else { return }
        let cc = waiters.removeFirst()
        cc.resume()
    }

    // Release all pending process() calls.
    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        for cc in pending {
            cc.resume()
        }
    }

    var pendingCount: Int { waiters.count }
}
