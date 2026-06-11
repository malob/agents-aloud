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
    ) async throws -> [SessionSummary] {
        try await PerfLog.time("Storage.loadSessions") {
            try await _loadSessions(since: since, minimumCount: minimumCount)
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
    private func _loadSessions(since: Date, minimumCount: Int) async throws -> [SessionSummary] {
        let sortedCandidates = try enumerateCandidates()  // sorted mtime desc

        // Walk-until-enough policy:
        //  - Always process everything within the `since` window
        //    (whatever valid summaries those produce).
        //  - If the valid count ends up below `minimumCount`, keep
        //    walking past the window into older candidates until
        //    the floor is met or we run out.
        //
        // We deliberately do NOT precompute a target from a count of
        // raw within-window candidates — a burst of ai-title-only
        // artifacts from the CLI rewriter could make `withinWindow`
        // much larger than the number of real sessions there, then
        // force the loop to walk far into old history making up the
        // difference. Instead, the stop condition reads the accreted
        // `sessions.count` directly against `minimumCount`.
        var sessions: [SessionSummary] = []
        var walkedPaths: [String] = []
        for candidate in sortedCandidates {
            let withinWindow = candidate.modifiedAt >= since
            // Stop once we're outside the window AND we've collected
            // enough valid sessions for the floor.
            if !withinWindow && sessions.count >= minimumCount {
                break
            }
            walkedPaths.append(candidate.url.path)

            if let summary = try await cachedOrComputedSummary(for: candidate) {
                sessions.append(summary)
            }
            // nil = artifact — walk past it
        }

        let validPaths = Set(walkedPaths)
        let validProjectPaths = Set(walkedPaths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        sessionSummaryCache = sessionSummaryCache.filter { validPaths.contains($0.key) }
        transcriptCache = transcriptCache.filter { validPaths.contains($0.key) }
        projectMetadataCache = projectMetadataCache.filter { validProjectPaths.contains($0.key) }

        return sessions
    }

    // Live-registry path: summarize exactly the running sessions —
    // no directory walking, no recency window. The transcript path is
    // constructed from the registry's cwd + sessionID; a session whose
    // JSONL doesn't exist yet (brand-new, nothing said) still gets a
    // placeholder summary so it appears in the sidebar immediately.
    // Summary-cache entries are shared with the walk path (the cache
    // stores base summaries; live name/liveness overrides are applied
    // after retrieval) and deliberately NOT evicted here — live mode
    // sees only a handful of paths per refresh, and evicting to that
    // set would cold-start the walk fallback.
    func loadSessions(live liveSessions: [LiveClaudeSession]) async throws -> [SessionSummary] {
        try await PerfLog.time("Storage.loadSessionsLive") {
            var summaries: [SessionSummary] = []
            for live in liveSessions {
                summaries.append(try await summaryForLiveSession(live))
            }
            return summaries.sorted {
                ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
        }
    }

    private func summaryForLiveSession(_ live: LiveClaudeSession) async throws -> SessionSummary {
        let expectedURL = projectsRoot
            .appendingPathComponent(
                ClaudeSessionRegistry.projectDirectoryName(forCWD: live.cwd),
                isDirectory: true
            )
            .appendingPathComponent("\(live.sessionID).jsonl", isDirectory: false)

        // The munged-cwd guess can miss (the registry reports the
        // process cwd, which can drift from where the transcript was
        // created). One cheap directory-name sweep for the session's
        // file before falling back to a placeholder.
        let transcriptURL: URL
        if fileManager.fileExists(atPath: expectedURL.path) {
            transcriptURL = expectedURL
        } else if let found = findTranscript(sessionID: live.sessionID) {
            transcriptURL = found
        } else {
            // No JSONL on disk yet. Show the session anyway — it's
            // live — with the registry's own metadata. The transcript
            // view's watcher retries ENOENT, so the row becomes
            // readable as soon as Claude writes the first line.
            return SessionSummary(
                id: live.sessionID,
                summary: live.name ?? "New session",
                firstPrompt: nil,
                modifiedAt: live.startedAt,
                projectPath: live.cwd,
                transcriptURL: expectedURL,
                liveness: Self.liveness(for: live)
            )
        }

        let modifiedAt = fileModificationDate(for: transcriptURL) ?? live.startedAt
        let candidate = TranscriptCandidate(url: transcriptURL, modifiedAt: modifiedAt)
        guard let summary = try await cachedOrComputedSummary(for: candidate) else {
            // The artifact filter rejected the file's content (e.g.
            // nothing speakable yet) — but a live session is never an
            // artifact; placeholder until real content lands.
            return SessionSummary(
                id: live.sessionID,
                summary: live.name ?? "New session",
                firstPrompt: nil,
                modifiedAt: modifiedAt,
                projectPath: live.cwd,
                transcriptURL: transcriptURL,
                liveness: Self.liveness(for: live)
            )
        }

        return SessionSummary(
            source: summary.source,
            id: summary.id,
            summary: live.name ?? summary.summary,
            firstPrompt: summary.firstPrompt,
            modifiedAt: summary.modifiedAt,
            projectPath: summary.projectPath,
            transcriptURL: summary.transcriptURL,
            liveness: Self.liveness(for: live)
        )
    }

    private nonisolated static func liveness(for live: LiveClaudeSession) -> SessionLiveness {
        switch live.activity {
        case .busy: return .liveBusy
        case .idle: return .liveIdle
        case nil: return .liveUnknown
        }
    }

    private func findTranscript(sessionID: String) -> URL? {
        guard let projectURLs = try? fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for projectURL in projectURLs {
            let candidate = projectURL.appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // Shared summary lookup for the walk and live paths: cache hit
    // keyed on (transcript mtime, project metadata mtimes), else a
    // fresh head+tail summarize. Returns nil for artifact files (the
    // ai-title-only JSONLs the CLI rewriter leaves behind).
    private func cachedOrComputedSummary(for candidate: TranscriptCandidate) async throws -> SessionSummary? {
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
            return cached.summary
        }

        let metadata = try loadProjectMetadataIndex(for: projectURL)
        guard let summary = try await Self.summarize(candidate: candidate, metadata: metadata) else {
            return nil
        }
        sessionSummaryCache[candidate.url.path] = CachedSessionSummary(
            modifiedAt: candidate.modifiedAt,
            sessionCacheModifiedAt: sessionCacheModifiedAt,
            sessionsIndexModifiedAt: sessionsIndexModifiedAt,
            summary: summary
        )
        return summary
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

    // Per-file summarize work. Reads only a head chunk + a tail
    // chunk of the JSONL — far cheaper than slurping the whole file
    // (some active sessions are tens of MB), and gets us everything
    // the sidebar needs:
    //
    //   - Head (first N lines via URL.lines): first user message
    //     (L2-3), optional ai-title (L6-7), cwd (any record).
    //   - Tail (final ~32KB via FileHandle): the most recent
    //     `custom-title` record, which Claude writes whenever the
    //     user renames a session AND re-affirms periodically as the
    //     session continues. The first rename can be thousands of
    //     lines deep, but the *most recent* custom-title is always
    //     near the end of the file (frequency observed: roughly one
    //     per assistant turn). Reading the tail catches it without
    //     forcing us to parse everything in between.
    //
    // The parser's customTitle/aiTitle accumulators are last-wins,
    // so feeding it head + tail (including the rare overlap on small
    // files) just works; the most recent custom-title beats the
    // ai-title which beats the first-prompt fallback.
    //
    // `nonisolated` because no actor state is read; `async throws`
    // because URL.lines is an AsyncLineSequence.
    private static let summaryHeadLineLimit = 20
    private static let summaryTailMaxBytes = 32 * 1024

    private nonisolated static func summarize(
        candidate: TranscriptCandidate,
        metadata: ProjectMetadataIndex
    ) async throws -> SessionSummary? {
        var headLines: [String] = []
        for try await line in candidate.url.lines {
            headLines.append(line)
            if headLines.count >= summaryHeadLineLimit { break }
        }
        let tailLines = try await readTailLines(of: candidate.url, fromBackBytes: summaryTailMaxBytes)

        let combined = (headLines + tailLines).joined(separator: "\n")
        return ClaudeTranscriptParser.summarizeTranscript(
            combined,
            fileURL: candidate.url,
            modifiedAt: candidate.modifiedAt,
            projectMetadataIndex: metadata
        )
    }

    // Read all complete lines from the final `fromBackBytes` of the
    // file. There's no "tail-by-lines" API in Foundation directly,
    // but FileHandle.bytes.lines is an AsyncLineSequence that
    // respects the current file pointer — seek to a near-end offset
    // first, then iterate. Foundation handles UTF-8 decoding and
    // line-splitting; we only have to drop the partial first line
    // when we've seeked into the middle of one.
    private nonisolated static func readTailLines(of url: URL, fromBackBytes: Int) async throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let endOffset = try handle.seekToEnd()
        guard endOffset > 0 else { return [] }
        let chunkSize = min(UInt64(fromBackBytes), endOffset)
        let startOffset = endOffset - chunkSize
        try handle.seek(toOffset: startOffset)

        var lines: [String] = []
        var droppedPartialPrefix = (startOffset == 0)  // only drop the leading partial line when we seeked into the middle of one
        for try await line in handle.bytes.lines {
            if !droppedPartialPrefix {
                droppedPartialPrefix = true
                continue
            }
            lines.append(line)
        }
        return lines
    }

    func loadTranscript(
        for session: SessionSummary,
        filterToFinalOnly: Bool
    ) throws -> [TranscriptMessage] {
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
            let messageCap = TranscriptDisplayLimits.messageCap(filterToFinalOnly: filterToFinalOnly)

            // Cache mode-aware: a cached entry produced for one filter
            // mode can't satisfy the other (different cap, different
            // filter applied during widening). On mode change we fall
            // through to a fresh tail-load.
            if let cached = transcriptCache[cacheKey],
               cached.filterToFinalOnly == filterToFinalOnly {
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
                // All offsets here are line-snapped: `parsedEndOffset`
                // always sits just after a '\n', and tailMessages only
                // consumes up to the last complete line it sees. That's
                // what keeps this path correct while Claude is mid-append:
                // a long JSONL line is written in several syscalls, and a
                // refresh can land between them. Resuming from a raw stat
                // size instead would either re-parse bytes twice (duplicate
                // messages) or resume mid-line (the straddling message
                // silently dropped forever).
                if fileSize > cached.parsedEndOffset,
                   let currentSignature = try? readTailSignature(transcriptURL, upTo: cached.parsedEndOffset),
                   currentSignature == cached.tailSignature,
                   let appended = try? tailMessages(
                       transcriptURL,
                       fromOffset: cached.parsedEndOffset,
                       upTo: fileSize
                   ) {
                    // Roll the visible window forward: append the new
                    // messages, filter if needed, then trim back to the
                    // display cap. Drops the oldest messages from the
                    // cached list when a long-running session keeps
                    // growing past the cap.
                    let appendedFiltered = filterToFinalOnly
                        ? appended.messages.filter { !$0.isIntermediate }
                        : appended.messages
                    let merged = mergeInTimestampOrder(cached.messages, appendedFiltered)
                    let capped = Array(merged.suffix(messageCap))
                    let newSignature = (try? readTailSignature(transcriptURL, upTo: appended.endOffset)) ?? Data()
                    transcriptCache[cacheKey] = CachedTranscript(
                        modifiedAt: modifiedAt,
                        parsedEndOffset: appended.endOffset,
                        tailSignature: newSignature,
                        messages: capped,
                        filterToFinalOnly: filterToFinalOnly
                    )
                    PerfLog.mark("Storage.loadTranscript incremental appended=\(appended.messages.count) capped=\(capped.count) filterFinalOnly=\(filterToFinalOnly)")
                    return capped
                }
            }

            // Cold read, cache miss, file shrank, prefix mutated, or in-place
            // edit: tail-load only as much of the file as we need to fill the
            // display cap. Long sessions parse a fixed-size tail (~256 KB)
            // instead of the whole multi-MB JSONL, which is the dominant
            // cold-load win for chatty sessions.
            let tailLoad = try PerfLog.time("Storage.loadTranscript.tailLoad") {
                try loadTranscriptTail(
                    url: transcriptURL,
                    targetCount: messageCap,
                    filterToFinalOnly: filterToFinalOnly
                )
            }
            let signature = (try? readTailSignature(transcriptURL, upTo: tailLoad.endOffset)) ?? Data()
            transcriptCache[cacheKey] = CachedTranscript(
                modifiedAt: modifiedAt,
                parsedEndOffset: tailLoad.endOffset,
                tailSignature: signature,
                messages: tailLoad.messages,
                filterToFinalOnly: filterToFinalOnly
            )
            return tailLoad.messages
        }
    }

    // Read the file backward in expanding windows until we have at least
    // `targetCount` user/assistant messages (after applying the optional
    // intermediate-filter), or until we've read the entire file. The
    // window starts at 256 KB and doubles each iteration — bounding the
    // worst case (a session full of giant code-block messages, or a
    // chatty tool-use-heavy session under final-only mode where the
    // filter eats most of each window) without paying the huge-window
    // cost in the common case.
    private func loadTranscriptTail(
        url: URL,
        targetCount: Int,
        filterToFinalOnly: Bool
    ) throws -> (messages: [TranscriptMessage], endOffset: Int) {
        var windowSize = Self.initialTailWindowBytes
        while true {
            let window = try TranscriptTailReader.readTrailingWindow(url: url, windowSize: windowSize)
            if window.data.isEmpty {
                if window.coversWholeFile { return ([], window.endOffset) }
                // Single record longer than the window — widen.
                windowSize = max(windowSize * 2, windowSize + Self.initialTailWindowBytes)
                continue
            }
            guard let raw = String(data: window.data, encoding: .utf8) else {
                // Should not happen given the line-boundary trim, but if
                // the file contains invalid UTF-8 in the middle of the
                // window, widen and retry.
                if window.coversWholeFile { return ([], window.endOffset) }
                windowSize *= 2
                continue
            }
            let allMessages = ClaudeTranscriptParser.parseTranscript(raw)
            let filtered = filterToFinalOnly
                ? allMessages.filter { !$0.isIntermediate }
                : allMessages
            if filtered.count >= targetCount || window.coversWholeFile {
                return (Array(filtered.suffix(targetCount)), window.endOffset)
            }
            windowSize *= 2
        }
    }

    private static let initialTailWindowBytes = 256 * 1024

    // Read bytes [offset, limit), trim back to the last complete line, decode
    // as UTF-8, parse as JSONL. Returns the parsed messages plus the absolute
    // offset just past the last consumed newline — the caller stores that as
    // the resume point, so a line that straddles two reads (Claude mid-append)
    // is parsed exactly once, when it's complete. `offset` is always on a
    // clean line boundary because every stored resume point is itself
    // newline-snapped. Bounding the read at `limit` (the stat'd size) keeps
    // the parse window consistent with the size recorded alongside it even
    // when the file grows during the read.
    private func tailMessages(
        _ url: URL,
        fromOffset offset: Int,
        upTo limit: Int
    ) throws -> (messages: [TranscriptMessage], endOffset: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard limit > offset,
              let data = try handle.read(upToCount: limit - offset),
              !data.isEmpty,
              let lastNewline = data.lastIndex(of: 0x0A) else {
            // Nothing readable, or only a partial line so far — consume
            // nothing; the next refresh resumes from the same offset.
            return ([], offset)
        }
        guard let tail = String(data: Data(data[...lastNewline]), encoding: .utf8) else {
            return ([], offset)
        }
        return (ClaudeTranscriptParser.parseTranscript(tail), offset + lastNewline + 1)
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
    let summary: SessionSummary
}

private struct CachedTranscript {
    let modifiedAt: Date
    // Absolute byte offset just past the last '\n' we parsed — NOT the
    // raw stat'd file size. Always newline-snapped so the incremental
    // path can resume mid-append without duplicating or dropping the
    // line in flight.
    let parsedEndOffset: Int
    let tailSignature: Data
    let messages: [TranscriptMessage]
    // Mode this entry was produced under. The tail-loader widens
    // until it has enough post-filter messages for the right cap;
    // a cache entry produced for the other mode can't satisfy
    // current callers (different cap, different filtered set).
    let filterToFinalOnly: Bool
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
