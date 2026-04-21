import Foundation
import Testing

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
