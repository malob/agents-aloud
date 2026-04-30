import Foundation

// Display-side cap on the in-memory transcript window. Each session
// holds at most this many user/assistant messages. On cold load the
// storage layer reads only enough of the JSONL tail to satisfy the
// cap; on live appends the merged list is trimmed back to it,
// dropping the oldest messages from the visible transcript.
//
// Two caps because the toggle for "show only final assistant
// messages" changes the information density of each row:
//
//  - With intermediates included (the noisier mode): tool-use lines
//    like "I'll edit this file" / "Let me run that command" inflate
//    the count without adding much per-row signal. 50 is roughly
//    "5-22 final turns visible" depending on the session's tool-use
//    ratio (10-45% in the wild).
//  - Final-only: each row is a complete user→assistant exchange
//    handoff. 10 rows is comfortably 2-3 screens of scrollback,
//    matching the same effective screen real estate as the 50-cap
//    in the chatty long-session case (where final-ratio is ~10%).
//
// This app's job is reading current assistant messages aloud and
// watching for new ones — there is no need for unbounded scrollback
// to render that.
enum TranscriptDisplayLimits {
    static let messageCapIncludingIntermediates = 50
    static let messageCapFinalOnly = 10

    static func messageCap(filterToFinalOnly: Bool) -> Int {
        filterToFinalOnly ? messageCapFinalOnly : messageCapIncludingIntermediates
    }
}
