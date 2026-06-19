import Foundation
import Testing
@testable import AgentsAloud

private func rolloutLine(role: String, text: String, timestamp: String) -> String {
    let contentType = role == "user" ? "input_text" : "output_text"
    return #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"\#(role)","content":[{"type":"\#(contentType)","text":"\#(text)"}]}}"#
}

struct CodexTranscriptParserTests {
    // The storage layer re-parses a sliding tail window of the rollout
    // file, so the same message is routinely parsed with a different
    // amount of preceding context. Its ID must not depend on that —
    // positional IDs renumbered every message whenever the window
    // start moved, which made Live Speak's known-set treat old
    // messages as new (re-speaking them) and reset per-row UI state.
    @Test
    func messageIDsAreStableWhenTheParseWindowSlides() {
        let lines = [
            rolloutLine(role: "user", text: "First question", timestamp: "2026-06-10T10:00:00.000Z"),
            rolloutLine(role: "assistant", text: "First answer", timestamp: "2026-06-10T10:00:01.000Z"),
            rolloutLine(role: "user", text: "Second question", timestamp: "2026-06-10T10:00:02.000Z"),
            rolloutLine(role: "assistant", text: "Second answer", timestamp: "2026-06-10T10:00:03.000Z"),
        ]

        let full = CodexTranscriptParser.parseTranscript(
            data: Data(lines.joined(separator: "\n").utf8),
            sessionID: "session"
        )
        // Same file with the oldest line outside the window.
        let slid = CodexTranscriptParser.parseTranscript(
            data: Data(lines.dropFirst().joined(separator: "\n").utf8),
            sessionID: "session"
        )

        #expect(full.count == 4)
        #expect(slid.count == 3)
        #expect(Array(full.dropFirst()).map(\.id) == slid.map(\.id))
    }

    @Test
    func identicalMessagesGetDistinctIDsWithinOneParse() {
        let line = rolloutLine(role: "assistant", text: "Same text", timestamp: "2026-06-10T10:00:00.000Z")
        let messages = CodexTranscriptParser.parseTranscript(
            data: Data([line, line].joined(separator: "\n").utf8),
            sessionID: "session"
        )

        #expect(messages.count == 2)
        #expect(Set(messages.map(\.id)).count == 2)
    }
}
