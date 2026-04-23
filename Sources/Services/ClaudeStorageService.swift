import Foundation
import OSLog

actor ClaudeStorageService {
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "local.claudecodevoice", category: "Storage")
    private let projectsRoot: URL
    private var sessionSummaryCache: [String: CachedSessionSummary] = [:]
    private var transcriptCache: [String: CachedTranscript] = [:]
    private var projectMetadataCache: [String: CachedProjectMetadata] = [:]

    init(
        projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    ) {
        self.projectsRoot = projectsRoot
    }

    // Load sessions whose transcript files were modified after `since`.
    // If fewer than `minimumCount` sessions qualify, also include enough of
    // the next-most-recent sessions (regardless of age) to reach that floor —
    // so the sidebar never looks empty just because the user hasn't used
    // Claude Code in the last day.
    //
    // Tests pass `since: .distantPast` to load everything they wrote.
    func loadSessions(
        since: Date = .distantPast,
        minimumCount: Int = 5
    ) throws -> [ClaudeSessionSummary] {
        try PerfLog.time("Storage.loadSessions") {
            try _loadSessions(since: since, minimumCount: minimumCount)
        }
    }

    // NB: This runs sequentially by design. An earlier version fanned out the
    // per-session summarize work over a `withThrowingTaskGroup` so cold-start
    // could use multiple cores, but under measurement that REGRESSED wall time
    // by 2-4x on Apple Silicon — each task's individual runtime ballooned
    // 20-50x under any concurrency level (cap=1..10 all tested). Root cause
    // appears to be memory-allocator / Foundation contention when many threads
    // churn through JSON decoder instances, ISO8601DateFormatter construction,
    // and per-line small-object allocation simultaneously. Sequential
    // cold-start is fast enough now that we're only loading a 24-hour window
    // (typically a handful of sessions) plus a floor for the empty-state case.
    // If this ever becomes a bottleneck the right fix is probably an
    // incremental / streaming parser that allocates less per line, not
    // parallelization.
    private func _loadSessions(since: Date, minimumCount: Int) throws -> [ClaudeSessionSummary] {
        let sortedCandidates = try enumerateCandidates()  // sorted mtime desc

        // Prefix-slice covering `since` + the minimum floor. Because the array
        // is sorted descending by mtime, the selected candidates are always
        // contiguous at the front.
        let withinWindow = sortedCandidates.prefix(while: { $0.modifiedAt >= since }).count
        let selectedCount = max(withinWindow, min(minimumCount, sortedCandidates.count))
        let selected = Array(sortedCandidates.prefix(selectedCount))

        var sessions: [ClaudeSessionSummary] = []
        for candidate in selected {
            let projectURL = candidate.url.deletingLastPathComponent()
            let sessionCacheModifiedAt = fileModificationDate(
                for: projectURL.appendingPathComponent(".session_cache.json", isDirectory: false)
            )
            let sessionsIndexModifiedAt = fileModificationDate(
                for: projectURL.appendingPathComponent("sessions-index.json", isDirectory: false)
            )

            if let cached = sessionSummaryCache[candidate.url.path],
               cached.modifiedAt == candidate.modifiedAt,
               cached.sessionCacheModifiedAt == sessionCacheModifiedAt,
               cached.sessionsIndexModifiedAt == sessionsIndexModifiedAt {
                sessions.append(cached.summary)
                continue
            }

            let metadata = try loadProjectMetadataIndex(for: projectURL)
            guard let summary = try Self.summarize(candidate: candidate, metadata: metadata) else {
                continue
            }
            sessionSummaryCache[candidate.url.path] = CachedSessionSummary(
                modifiedAt: candidate.modifiedAt,
                sessionCacheModifiedAt: sessionCacheModifiedAt,
                sessionsIndexModifiedAt: sessionsIndexModifiedAt,
                summary: summary
            )
            sessions.append(summary)
        }

        let validPaths = Set(selected.map { $0.url.path })
        let validProjectPaths = Set(validPaths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        sessionSummaryCache = sessionSummaryCache.filter { validPaths.contains($0.key) }
        transcriptCache = transcriptCache.filter { validPaths.contains($0.key) }
        projectMetadataCache = projectMetadataCache.filter { validProjectPaths.contains($0.key) }

        return sessions
    }

    private func enumerateCandidates() throws -> [TranscriptCandidate] {
        let projectURLs = try fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        )

        var transcriptCandidates: [TranscriptCandidate] = []

        for projectURL in projectURLs {
            do {
                let values = try projectURL.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else {
                    continue
                }

                let childURLs = try fileManager.contentsOfDirectory(
                    at: projectURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )

                for childURL in childURLs where childURL.pathExtension == "jsonl" {
                    let childValues = try childURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                    guard childValues.isRegularFile == true else {
                        continue
                    }

                    transcriptCandidates.append(TranscriptCandidate(
                        url: childURL,
                        modifiedAt: childValues.contentModificationDate ?? .distantPast
                    ))
                }
            } catch {
                logger.error(
                    "Skipping project directory \(projectURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return transcriptCandidates.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // Per-file summarize work. Pure function of its inputs — reads the file,
    // calls the parser, returns a summary. Kept as a nonisolated static to
    // keep the type honest (no actor state needed) and to allow test/diagnostic
    // callers to invoke it directly.
    private nonisolated static func summarize(
        candidate: TranscriptCandidate,
        metadata: ProjectMetadataIndex
    ) throws -> ClaudeSessionSummary? {
        let rawTranscript = try String(contentsOf: candidate.url, encoding: .utf8)
        return ClaudeTranscriptParser.summarizeTranscript(
            rawTranscript,
            fileURL: candidate.url,
            modifiedAt: candidate.modifiedAt,
            projectMetadataIndex: metadata
        )
    }

    func loadTranscript(for session: ClaudeSessionSummary) throws -> [TranscriptMessage] {
        try PerfLog.time("Storage.loadTranscript") {
            // URL caches resourceValues on the instance, which would make
            // mtime/fileSize reads stale when loadTranscript is invoked
            // multiple times for the same session after the file grows.
            // Flush the cache so the subsequent read hits disk.
            var transcriptURL = session.transcriptURL
            transcriptURL.removeAllCachedResourceValues()
            let cacheKey = transcriptURL.path
            let values = try transcriptURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modifiedAt = values.contentModificationDate ?? .distantPast
            let fileSize = values.fileSize ?? 0

            if let cached = transcriptCache[cacheKey] {
                if cached.modifiedAt == modifiedAt {
                    PerfLog.mark("Storage.loadTranscript cacheHit")
                    return cached.messages
                }

                // Incremental path: Claude Code writes JSONL append-only, so when
                // the file only grew AND the bytes we already cached are still
                // intact we can seek past them and parse just the new tail.
                // Brings watcher-triggered refresh from ~280ms (full file parse)
                // down to a few ms for typical single-message appends.
                //
                // The tail-signature check below guards against rewind / edit /
                // session-fork scenarios where the prefix may have been
                // rewritten even though the new fileSize is larger than the
                // old. If the last ~128 cached bytes no longer match, something
                // modified content we had already parsed → fall back to a full
                // re-parse. See ClaudeStorageServiceTests for the forced
                // failure mode.
                if fileSize > cached.fileSize,
                   let currentSignature = try? readTailSignature(transcriptURL, upTo: cached.fileSize),
                   currentSignature == cached.tailSignature,
                   let appended = try? tailMessages(transcriptURL, fromOffset: cached.fileSize) {
                    let merged = mergeInTimestampOrder(cached.messages, appended)
                    let newSignature = (try? readTailSignature(transcriptURL, upTo: fileSize)) ?? Data()
                    transcriptCache[cacheKey] = CachedTranscript(
                        modifiedAt: modifiedAt,
                        fileSize: fileSize,
                        tailSignature: newSignature,
                        messages: merged
                    )
                    PerfLog.mark("Storage.loadTranscript incremental appended=\(appended.count)")
                    return merged
                }
            }

            // Cold read, cache miss, file shrank, prefix mutated, or in-place
            // edit: full parse.
            let rawTranscript = try PerfLog.time("Storage.loadTranscript.read") {
                try String(contentsOf: transcriptURL, encoding: .utf8)
            }
            let sortedMessages = ClaudeTranscriptParser.parseTranscript(rawTranscript)
            let signature = (try? readTailSignature(transcriptURL, upTo: fileSize)) ?? Data()
            transcriptCache[cacheKey] = CachedTranscript(
                modifiedAt: modifiedAt,
                fileSize: fileSize,
                tailSignature: signature,
                messages: sortedMessages
            )
            return sortedMessages
        }
    }

    // Read bytes from `offset` to end of file, decode as UTF-8, parse as JSONL.
    // Returns the messages found in that tail (already timestamp-sorted by the
    // parser). Assumes `offset` is on a clean line boundary — which it is when
    // we cache the file's full byte length after a previous read, because
    // JSONL writers always emit a trailing `\n` per line. If an incomplete
    // write ever leaves the file mid-line, the decode or decode-per-line will
    // drop the partial line; the next refresh catches it once fully written.
    private func tailMessages(_ url: URL, fromOffset offset: Int) throws -> [TranscriptMessage] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.readToEnd(), !data.isEmpty,
              let tail = String(data: data, encoding: .utf8) else {
            return []
        }
        return ClaudeTranscriptParser.parseTranscript(tail)
    }

    // Read up to the last `Self.tailSignatureLength` bytes of the file,
    // ending at byte `size`. Used as a cheap fingerprint of the already-parsed
    // prefix: if the bytes at [size-N, size) change between loads, the file
    // was mutated (edited / rewound / rewritten), not just appended to.
    private func readTailSignature(_ url: URL, upTo size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let windowStart = max(0, size - Self.tailSignatureLength)
        try handle.seek(toOffset: UInt64(windowStart))
        let count = size - windowStart
        return try handle.read(upToCount: count) ?? Data()
    }

    private static let tailSignatureLength = 128

    // Fast path: if the tail's earliest message is at-or-after the cached
    // tail, the merged list is already sorted. Only re-sort when we detect
    // an out-of-order timestamp (should be rare given JSONL is append-only
    // and Claude writes chronologically).
    private func mergeInTimestampOrder(
        _ cached: [TranscriptMessage],
        _ appended: [TranscriptMessage]
    ) -> [TranscriptMessage] {
        guard let lastCached = cached.last,
              let firstNew = appended.first,
              firstNew.timestamp < lastCached.timestamp else {
            return cached + appended
        }
        return (cached + appended).sorted { $0.timestamp < $1.timestamp }
    }

    private func loadProjectMetadataIndex(for projectURL: URL) throws -> ProjectMetadataIndex {
        let sessionCacheURL = projectURL.appendingPathComponent(".session_cache.json", isDirectory: false)
        let sessionsIndexURL = projectURL.appendingPathComponent("sessions-index.json", isDirectory: false)
        let sessionCacheModifiedAt = fileModificationDate(for: sessionCacheURL)
        let sessionsIndexModifiedAt = fileModificationDate(for: sessionsIndexURL)

        if let cachedProjectMetadata = projectMetadataCache[projectURL.path],
           cachedProjectMetadata.sessionCacheModifiedAt == sessionCacheModifiedAt,
           cachedProjectMetadata.sessionsIndexModifiedAt == sessionsIndexModifiedAt {
            return cachedProjectMetadata.index
        }

        var index = ProjectMetadataIndex()

        if let sessionsIndex: SessionsIndexFile = try decodeIfPresent(SessionsIndexFile.self, at: sessionsIndexURL) {
            for entry in sessionsIndex.entries {
                let metadata = SessionMetadata(
                    summary: entry.summary?.trimmed.nilIfEmpty,
                    source: .sessionsIndex
                )
                index.merge(metadata, forFilePath: entry.fullPath, sessionID: entry.sessionID)
            }
        }

        if let sessionCache: SessionCacheFile = try decodeIfPresent(SessionCacheFile.self, at: sessionCacheURL) {
            for (entryPath, entry) in sessionCache.entries {
                guard let session = entry.session else {
                    continue
                }

                let metadata = SessionMetadata(
                    summary: session.summary?.trimmed.nilIfEmpty,
                    source: .sessionCache
                )
                index.merge(
                    metadata,
                    forFilePath: session.filePath ?? entryPath,
                    sessionID: session.actualSessionID
                )
            }
        }

        projectMetadataCache[projectURL.path] = CachedProjectMetadata(
            sessionCacheModifiedAt: sessionCacheModifiedAt,
            sessionsIndexModifiedAt: sessionsIndexModifiedAt,
            index: index
        )
        return index
    }

    private func fileModificationDate(for fileURL: URL) -> Date? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        return try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func decodeIfPresent<T: Decodable>(_ type: T.Type, at fileURL: URL) throws -> T? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Log decode failures loudly so Claude Code schema drift
            // surfaces in Console. Returning nil keeps behavior graceful
            // (falls back to first-prompt summary) but never silent.
            logger.error(
                "Metadata decode failed for \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}

private struct TranscriptCandidate: Sendable {
    let url: URL
    let modifiedAt: Date
}

private struct CachedSessionSummary {
    let modifiedAt: Date
    // Metadata mtimes captured when this summary was computed. If either
    // has changed since, the cached summary may have a stale title / AI
    // summary and must be recomputed even though the transcript mtime is
    // unchanged. (Claude sometimes updates .session_cache.json /
    // sessions-index.json without touching the JSONL.)
    let sessionCacheModifiedAt: Date?
    let sessionsIndexModifiedAt: Date?
    let summary: ClaudeSessionSummary
}

private struct CachedTranscript {
    let modifiedAt: Date
    let fileSize: Int
    let tailSignature: Data
    let messages: [TranscriptMessage]
}

private struct CachedProjectMetadata {
    let sessionCacheModifiedAt: Date?
    let sessionsIndexModifiedAt: Date?
    let index: ProjectMetadataIndex
}

private struct SessionsIndexFile: Decodable {
    let entries: [SessionsIndexEntry]
}

private struct SessionsIndexEntry: Decodable {
    let sessionID: String
    let fullPath: String
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case fullPath
        case summary
    }
}

private struct SessionCacheFile: Decodable {
    let entries: [String: SessionCacheEntry]
}

private struct SessionCacheEntry: Decodable {
    let session: SessionCacheSession?
}

private struct SessionCacheSession: Decodable {
    let actualSessionID: String?
    let filePath: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case actualSessionID = "actual_session_id"
        case filePath = "file_path"
        case summary
    }
}
