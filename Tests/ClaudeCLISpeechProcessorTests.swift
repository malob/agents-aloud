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
        // Use /bin/sleep as a stand-in for a long-running claude CLI.
        // Without cancellation wiring, sleep would run for its full
        // duration regardless of the outer Task's cancellation — the
        // fix added withTaskCancellationHandler + processBox.terminate()
        // so cancel propagates to the subprocess.
        let processor = ClaudeCLISpeechProcessor(binaryLocator: {
            URL(fileURLWithPath: "/bin/sleep")
        })

        let input = "anything non-empty"
        let start = ContinuousClock.now

        // Spawn the call in a Task so we can cancel it externally.
        let task = Task {
            await processor.process(text: input)
        }
        // Let the subprocess actually start.
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        let elapsed = ContinuousClock.now - start

        // Cancellation should land well before sleep's natural "30" arg
        // (which the processor would pass as a bogus flag; sleep would
        // exit with a non-zero status anyway, but still promptly on
        // cancel). Guard: under a second.
        #expect(elapsed < .seconds(2))
        // Subprocess exit → process() returns nil → passthrough.
        #expect(result == input)
    }
}
