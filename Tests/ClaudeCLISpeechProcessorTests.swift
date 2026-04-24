import Foundation
import Testing
@testable import ClaudeCodeVoice

struct ClaudeCLISpeechProcessorTests {

    @Test
    func passthroughWhenBinaryMissing() async throws {
        // Inject a locator that always returns nil (binary not on PATH).
        let processor = ClaudeCLISpeechProcessor(binaryLocator: { nil })
        let input = "Any text with `code` and | tables"

        let output = await processor.process(text: input)

        #expect(output == input)
    }

    @Test
    func passthroughOnEmptyInput() async throws {
        let processor = ClaudeCLISpeechProcessor(binaryLocator: {
            // Should never get this far — short-circuit on empty happens
            // before the binary check.
            URL(fileURLWithPath: "/does/not/exist")
        })

        #expect(await processor.process(text: "") == "")
        #expect(await processor.process(text: "   \n  ") == "   \n  ")
    }

    @Test
    func passthroughOnOversizedInput() async throws {
        let processor = ClaudeCLISpeechProcessor(binaryLocator: {
            URL(fileURLWithPath: "/does/not/exist")
        })
        // Processor caps at 4000 chars.
        let input = String(repeating: "x", count: 5000)

        let output = await processor.process(text: input)

        #expect(output == input)
    }

    @Test
    func cancelledTaskTerminatesSubprocessAndReturnsPassthrough() async throws {
        // Stand-in for a long-running `claude` — a shell script that
        // ignores all arguments and sleeps. Using /bin/sleep directly
        // doesn't work because the processor passes claude-style
        // flags (--print --model …) which sleep rejects with an
        // invalid-argument error, exiting immediately, so the test
        // would pass even if the cancellation plumbing didn't work.
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-cli-cancel-test-\(UUID().uuidString).sh")
        try """
        #!/bin/sh
        # Ignore all args — we're a cancellation-test stand-in for
        # `claude`. Sleep for long enough that only cancellation can
        # end the process before the test's own timeout.
        exec /bin/sleep 30
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let processor = ClaudeCLISpeechProcessor(binaryLocator: { scriptURL })
        let input = "anything non-empty"

        let task = Task {
            await processor.process(text: input)
        }
        // Let the subprocess actually start. Without a real wait the
        // cancellation could land in the pre-launch window, which the
        // ProcessBox.cancelledFlag check also handles — but we want
        // to exercise the in-flight termination path here.
        try await Task.sleep(for: .milliseconds(150))

        let start = ContinuousClock.now
        task.cancel()
        let result = await task.value
        let elapsed = ContinuousClock.now - start

        // If cancellation is wired correctly, SIGTERM reaches the
        // shell's `exec sleep 30` and the process exits within a
        // few hundred ms. If it's broken, the task would block for
        // the full 30s sleep.
        #expect(elapsed < .seconds(2))
        // Subprocess exit → process() returns nil → passthrough.
        #expect(result == input)
    }

    @Test
    func cancelledBeforeLaunchDoesNotHang() async throws {
        // Near-immediate cancellation after the process() call — the
        // detached worker typically hasn't reached process.run() yet.
        // Without ProcessBox.cancelledFlag + the pre-launch check,
        // the worker would launch the subprocess anyway and we'd
        // block on waitUntilExit for the full 30s sleep. The fix
        // closes both the pre-launch window (flag skips launch) and
        // the post-launch race (flag re-check SIGTERMs if we just
        // launched).
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-cli-prelaunch-test-\(UUID().uuidString).sh")
        try """
        #!/bin/sh
        exec /bin/sleep 30
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let processor = ClaudeCLISpeechProcessor(binaryLocator: { scriptURL })
        let start = ContinuousClock.now
        let task = Task {
            await processor.process(text: "non-empty")
        }
        task.cancel()

        let result = await task.value
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .seconds(2))
        #expect(result == "non-empty")
    }
}
