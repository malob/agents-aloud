import Foundation

// Byte-level helper for reading a trailing window of a JSONL file
// without slurping the whole thing into memory. Used by both
// ClaudeStorageService and CodexStorageService so the cold-load
// transcript path stays bounded regardless of session length.
//
// JSONL files are line-delimited and writers always emit a trailing
// '\n' per record, so the right way to start a partial read on a
// clean line boundary is: read [fileSize - windowSize, fileSize),
// then drop everything up to and including the first '\n'. The byte
// after that newline is guaranteed to be the first character of a
// fresh JSON object (i.e. '{').
//
// Multi-byte UTF-8 safety: the trim drops bytes BEFORE the newline,
// keeping bytes AFTER it. JSONL records start with '{' (single-byte
// ASCII) so the kept buffer always begins on a valid UTF-8 boundary.
enum TranscriptTailReader {
    struct Window {
        // Bytes from the file, starting on a clean line boundary.
        // Empty if the file is empty or the requested window had
        // no newline (no complete records to extract).
        let data: Data
        let fileSize: Int
        // True when we read from offset 0 — i.e. the data covers
        // the entire file. Callers iterating with widening windows
        // use this as the "no point expanding further" signal.
        let coversWholeFile: Bool
    }

    static func readTrailingWindow(url: URL, windowSize: Int) throws -> Window {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = values.fileSize ?? 0
        if fileSize == 0 {
            return Window(data: Data(), fileSize: 0, coversWholeFile: true)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let offset = max(0, fileSize - windowSize)
        try handle.seek(toOffset: UInt64(offset))
        guard let raw = try handle.readToEnd() else {
            return Window(data: Data(), fileSize: fileSize, coversWholeFile: offset == 0)
        }

        if offset == 0 {
            return Window(data: raw, fileSize: fileSize, coversWholeFile: true)
        }

        // Drop the partial first line so the kept slice starts at a
        // line boundary. If the window happens to land entirely
        // inside one giant record (no newline), the caller's expand
        // loop will widen and retry.
        guard let firstNewline = raw.firstIndex(of: 0x0A) else {
            return Window(data: Data(), fileSize: fileSize, coversWholeFile: false)
        }
        let trimmed = raw.suffix(from: raw.index(after: firstNewline))
        return Window(data: Data(trimmed), fileSize: fileSize, coversWholeFile: false)
    }
}
