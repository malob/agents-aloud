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
// The END of the window needs the same care: the file may be
// mid-append when we read it (a multi-KB assistant message line is
// written in several syscalls), so the window is also trimmed back
// to the last complete '\n'. The trailing partial line is excluded
// and `endOffset` reports exactly how far the window consumed — a
// caller that resumes an incremental read from `endOffset` later
// will parse the straddling line exactly once, when it's complete.
//
// Multi-byte UTF-8 safety: both trims cut at '\n' (single-byte
// ASCII), and JSONL records start with '{', so the kept buffer
// always begins and ends on valid UTF-8 boundaries.
enum TranscriptTailReader {
    struct Window {
        // Bytes from the file, starting on a clean line boundary and
        // ending just after a '\n'. Empty if the file is empty or the
        // requested window held no complete records.
        let data: Data
        let fileSize: Int
        // Absolute file offset one past the last byte included in
        // `data` (just after its final newline). Cache bookkeeping
        // that resumes incremental reads must use THIS, not
        // `fileSize`: the file can grow between our stat and read,
        // and the window deliberately excludes any trailing partial
        // line. Equals the resume point even when `data` is empty.
        let endOffset: Int
        // True when we read from offset 0 — i.e. the data covers
        // every complete record in the file. Callers iterating with
        // widening windows use this as the "no point expanding
        // further" signal.
        let coversWholeFile: Bool
    }

    static func readTrailingWindow(url: URL, windowSize: Int) throws -> Window {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = values.fileSize ?? 0
        if fileSize == 0 {
            return Window(data: Data(), fileSize: 0, endOffset: 0, coversWholeFile: true)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let offset = max(0, fileSize - windowSize)
        try handle.seek(toOffset: UInt64(offset))
        // Bound the read to the stat'd size. The file may be growing
        // concurrently; reading to the live EOF would make the window
        // inconsistent with the size callers cache alongside it.
        guard let raw = try handle.read(upToCount: fileSize - offset), !raw.isEmpty else {
            return Window(data: Data(), fileSize: fileSize, endOffset: offset, coversWholeFile: offset == 0)
        }

        // Drop the partial first line so the kept slice starts at a
        // line boundary. If the window happens to land entirely
        // inside one giant record (no newline), the caller's expand
        // loop will widen and retry.
        let bodyStart: Data.Index
        if offset == 0 {
            bodyStart = raw.startIndex
        } else {
            guard let firstNewline = raw.firstIndex(of: 0x0A) else {
                return Window(data: Data(), fileSize: fileSize, endOffset: offset, coversWholeFile: false)
            }
            bodyStart = raw.index(after: firstNewline)
        }

        // Trim back to the last complete line. A window with no
        // complete record (single partial line still being written)
        // yields empty data; coversWholeFile still reflects whether
        // widening could help.
        guard let lastNewline = raw[bodyStart...].lastIndex(of: 0x0A) else {
            return Window(data: Data(), fileSize: fileSize, endOffset: offset, coversWholeFile: offset == 0)
        }

        let kept = raw[bodyStart...lastNewline]
        let endOffset = offset + lastNewline + 1  // raw.startIndex == 0 for fresh Data
        return Window(data: Data(kept), fileSize: fileSize, endOffset: endOffset, coversWholeFile: offset == 0)
    }
}
