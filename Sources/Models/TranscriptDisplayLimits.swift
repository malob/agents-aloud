import Foundation

// Display-side cap on the in-memory transcript window. Each session
// holds at most this many user/assistant messages. On cold load the
// storage layer reads only enough of the JSONL tail to satisfy this
// cap; on live appends the merged list is trimmed back to it,
// dropping the oldest messages from the visible transcript.
//
// This app's job is reading current assistant messages aloud and
// watching for new ones — there is no need for unbounded scrollback
// to render that. A 50-message window covers a few screens of
// context comfortably while bounding parse cost on long sessions
// (1000+ messages, tens of MB) to a fixed ~100ms tail read.
enum TranscriptDisplayLimits {
    static let messageCap = 50
}
