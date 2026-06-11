import Foundation
import OSLog

// Codex CLI storage layer. Walks `~/.codex/sessions/YYYY/MM/DD/` (and
// optionally archived_sessions) to enumerate rollout files, parses
// session metadata via CodexTranscriptParser, and exposes the same
// load-sessions / load-transcript surface AppModel uses for the
// Claude side.
//
// Differences from the Claude flow worth knowing about:
//
// - **Date-bucketed paths.** Codex layout is `YYYY/MM/DD/rollout-*.jsonl`
//   instead of Claude's per-project subdirectories. We walk three
//   levels (year → month → day) but bound the walk by the date filter
//   to avoid scanning years of sessions for a 24-hour sidebar window.
//
// - **No project association in the path.** A Codex session's
//   "project" lives inside the file as `session_meta.cwd`. We have to
//   peek at the first line to derive it.
//
// - **Subagent sessions are noise.** AgentControl-spawned sub-agents
//   (guardian, etc.) leave rollout files, but they aren't user
//   conversations. CodexTranscriptParser flags them via
//   `Summary.isSubagent` based on `session_meta.agent_nickname` /
//   `agent_role` / `source.subagent`; we filter them out here.
//
// - **mtime-keyed cache, no incremental-append fast path.** We cache
//   the parsed message window keyed by file path, valid as long as
//   mtime is unchanged. Re-clicks of an unchanged session and watcher
//   ticks that don't actually advance mtime become sub-millisecond
//   cache hits. On any mtime change we redo the full tail load (vs.
//   Claude, which also has a tail-signature check to parse only the
//   appended bytes). Codex's append cadence is low enough that the
//   simpler invalidation is fine for now; the same byte-signature
//   machinery from ClaudeStorageService can be lifted in here later
//   if profiling ever shows the redundant tail-load on append events.
actor CodexStorageService {
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "local.claudecodevoice", category: "CodexStorage")
    private let parser = CodexTranscriptParser()
    private let sessionsRoot: URL
    private let archivedSessionsRoot: URL
    private let threadDatabase: CodexThreadDatabase
    // mtime-keyed cache: keyed by transcript file path, valid while
    // mtime is unchanged. Repeat clicks of an unchanged session and
    // watcher ticks that don't actually advance mtime become
    // sub-millisecond cache hits instead of re-parsing 256 KB+ of
    // JSONL. We don't track fileSize / tail signature here (unlike
    // ClaudeStorageService) — Codex doesn't get an incremental-append
    // fast path; on any mtime change we redo the full tail load.
    // The win is on no-op refreshes, which the watcher fires plenty
    // of due to atomic rename / coalesced write events.
    private var transcriptCache: [String: CachedTranscript] = [:]

    private struct CachedTranscript {
        let modifiedAt: Date
        let messages: [TranscriptMessage]
        // Mode this entry was produced under. The tail-loader widens
        // until enough post-filter messages are in hand for the right
        // cap; a cache entry produced for the other mode can't satisfy
        // current callers (different cap, different filtered set).
        let filterToFinalOnly: Bool
    }

    init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true),
        archivedSessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("archived_sessions", isDirectory: true),
        threadDatabase: CodexThreadDatabase = CodexThreadDatabase()
    ) {
        self.sessionsRoot = sessionsRoot
        self.archivedSessionsRoot = archivedSessionsRoot
        self.threadDatabase = threadDatabase
    }

    // Same shape as ClaudeStorageService.loadSessions: only return
    // sessions whose transcript was modified since `since`, padded
    // up to `minimumCount` from the next-most-recent set if too few
    // qualify.
    //
    // No-op (returns []) if the sessions directory doesn't exist —
    // user might not have Codex installed at all.
    func loadSessions(
        since: Date = .distantPast,
        minimumCount: Int = 5
    ) throws -> [SessionSummary] {
        try PerfLog.time("CodexStorage.loadSessions") {
            // Try the SQLite fast path first. Codex maintains
            // ~/.codex/state_5.sqlite as the authoritative index of
            // all threads — one query gets us everything we need
            // for the sidebar, no JSONL parsing required.
            do {
                let rows = try threadDatabase.loadThreads(since: since)
                logger.info("Codex DB returned \(rows.count, privacy: .public) thread rows")
                return rows.map(Self.summary(from:))
            } catch {
                // DB missing, schema too old, or any other read
                // failure ⇒ fall back to the original filesystem
                // walk. Logs at info level (not error) because the
                // most common cause is "user doesn't have Codex
                // installed and the file doesn't exist."
                logger.info(
                    "Codex DB unavailable (\(String(describing: error), privacy: .public)); falling back to filesystem walk"
                )
                return try _loadSessionsFromFilesystem(since: since, minimumCount: minimumCount)
            }
        }
    }

    private nonisolated static func summary(from row: CodexThreadDatabase.Row) -> SessionSummary {
        SessionSummary(
            source: .codex,
            id: row.id,
            summary: deriveTitle(row: row),
            firstPrompt: row.firstUserMessage.isEmpty ? nil : row.firstUserMessage,
            modifiedAt: row.updatedAt,
            projectPath: row.cwd,
            transcriptURL: URL(fileURLWithPath: row.rolloutPath)
        )
    }

    // Fallback when title is empty in the DB (very fresh sessions
    // before Codex generates one). Use the first user message or
    // the project basename, mirroring CodexTranscriptParser's
    // own deriveTitle.
    private nonisolated static func deriveTitle(row: CodexThreadDatabase.Row) -> String {
        let trimmedTitle = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle.count > 80 ? String(trimmedTitle.prefix(80)) + "…" : trimmedTitle
        }
        let trimmedPrompt = row.firstUserMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            let firstLine = trimmedPrompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmedPrompt
            return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
        }
        let name = URL(fileURLWithPath: row.cwd).lastPathComponent
        return name.isEmpty ? "Untitled session" : "Session in \(name)"
    }

    private func _loadSessionsFromFilesystem(since: Date, minimumCount: Int) throws -> [SessionSummary] {
        var allCandidates: [URL] = []
        if fileManager.fileExists(atPath: sessionsRoot.path) {
            allCandidates.append(contentsOf: try enumerateRolloutFiles(under: sessionsRoot))
        }
        if fileManager.fileExists(atPath: archivedSessionsRoot.path) {
            allCandidates.append(contentsOf: try enumerateRolloutFiles(under: archivedSessionsRoot))
        }

        // Sort by mtime desc — same ordering policy as Claude.
        let sorted = try allCandidates
            .map { url -> (URL, Date) in
                let mtime = try fileMTime(of: url) ?? .distantPast
                return (url, mtime)
            }
            .sorted { $0.1 > $1.1 }

        var summaries: [SessionSummary] = []
        for (url, mtime) in sorted {
            // Walk-until-enough policy mirroring Claude: include
            // everything within window, then keep walking older
            // entries until we hit minimumCount valid summaries.
            let withinWindow = mtime >= since
            if !withinWindow && summaries.count >= minimumCount {
                break
            }

            guard let summary = try? parser.summarize(transcriptAt: url) else {
                continue
            }
            // Filter sub-agent runs from the sidebar.
            if summary.isSubagent {
                continue
            }
            // Filter rollouts that died before any user/assistant
            // turn (or compacted summary) happened.
            if !summary.hasContent {
                continue
            }

            summaries.append(SessionSummary(
                source: .codex,
                id: summary.sessionID,
                summary: summary.derivedTitle,
                firstPrompt: summary.firstUserPrompt,
                modifiedAt: mtime,
                projectPath: summary.cwd,
                transcriptURL: url
            ))
        }

        return summaries
    }

    func loadTranscript(
        for session: SessionSummary,
        filterToFinalOnly: Bool
    ) throws -> [TranscriptMessage] {
        try PerfLog.time("CodexStorage.loadTranscript") {
            // URL caches resourceValues on the instance; flush so we
            // see the current mtime even after the file has grown
            // since the URL was first constructed.
            var transcriptURL = session.transcriptURL
            transcriptURL.removeAllCachedResourceValues()
            let cacheKey = transcriptURL.path
            let modifiedAt = (try? transcriptURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            let messageCap = TranscriptDisplayLimits.messageCap(filterToFinalOnly: filterToFinalOnly)

            if let cached = transcriptCache[cacheKey],
               cached.modifiedAt == modifiedAt,
               cached.filterToFinalOnly == filterToFinalOnly {
                PerfLog.mark("CodexStorage.loadTranscript cacheHit")
                return cached.messages
            }

            // Tail-only read keyed off the filter-aware cap. For long
            // Codex sessions this avoids re-parsing the whole multi-MB
            // rollout JSONL. Codex's first line is `session_meta` which
            // the parser doesn't strictly need (sessionID comes from
            // the filename), so dropping the file's prefix is safe.
            let messages = try loadTranscriptTail(
                url: transcriptURL,
                targetCount: messageCap,
                filterToFinalOnly: filterToFinalOnly
            )
            transcriptCache[cacheKey] = CachedTranscript(
                modifiedAt: modifiedAt,
                messages: messages,
                filterToFinalOnly: filterToFinalOnly
            )
            return messages
        }
    }

    // Mirror of ClaudeStorageService's loadTranscriptTail: read the file
    // backward in widening windows until we have enough user/assistant
    // messages (after applying the optional intermediate-filter) or the
    // window covers the whole file. Codex transcripts typically include
    // lots of non-message lines (tool calls, reasoning events,
    // turn_context, event_msg) plus, in final-only mode, intermediate
    // assistant messages that the filter drops — so we may need to
    // widen past the initial 256 KB on long sessions to gather the cap.
    private func loadTranscriptTail(
        url: URL,
        targetCount: Int,
        filterToFinalOnly: Bool
    ) throws -> [TranscriptMessage] {
        let sessionID = CodexTranscriptParser.sessionID(from: url)
        var windowSize = Self.initialTailWindowBytes
        while true {
            let window = try TranscriptTailReader.readTrailingWindow(url: url, windowSize: windowSize)
            if window.data.isEmpty {
                if window.coversWholeFile { return [] }
                windowSize = max(windowSize * 2, windowSize + Self.initialTailWindowBytes)
                continue
            }
            let allMessages = CodexTranscriptParser.parseTranscript(data: window.data, sessionID: sessionID)
            let filtered = filterToFinalOnly
                ? allMessages.filter { !$0.isIntermediate }
                : allMessages
            if filtered.count >= targetCount || window.coversWholeFile {
                return Array(filtered.suffix(targetCount))
            }
            windowSize *= 2
        }
    }

    private static let initialTailWindowBytes = 256 * 1024

    // MARK: - Filesystem walk

    private func enumerateRolloutFiles(under root: URL) throws -> [URL] {
        var results: [URL] = []
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        while let next = enumerator?.nextObject() as? URL {
            // Codex rollout file: `rollout-*.jsonl`.
            let name = next.lastPathComponent
            if name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                results.append(next)
            }
        }
        return results
    }

    private func fileMTime(of url: URL) throws -> Date? {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return values.contentModificationDate
    }
}
