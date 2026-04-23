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
}
