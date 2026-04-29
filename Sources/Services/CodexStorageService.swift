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
// - **No incremental tail-signature optimization for v1.** The Claude
//   service tracks tail bytes for fast-path detection of append-only
//   updates. Codex sessions append-only too, but we re-parse the
//   whole file each time for now. Cheap on the bounded date window;
//   we can add an incremental path later if it shows up in profiles.
actor CodexStorageService {
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "local.claudecodevoice", category: "CodexStorage")
    private let parser = CodexTranscriptParser()
    private let sessionsRoot: URL
    private let archivedSessionsRoot: URL

    init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true),
        archivedSessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("archived_sessions", isDirectory: true)
    ) {
        self.sessionsRoot = sessionsRoot
        self.archivedSessionsRoot = archivedSessionsRoot
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
    ) throws -> [ClaudeSessionSummary] {
        try PerfLog.time("CodexStorage.loadSessions") {
            try _loadSessions(since: since, minimumCount: minimumCount)
        }
    }

    private func _loadSessions(since: Date, minimumCount: Int) throws -> [ClaudeSessionSummary] {
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

        var summaries: [ClaudeSessionSummary] = []
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
            // Filter zero-message sessions (rollouts that died before
            // any user/assistant turn happened).
            if summary.messageCount == 0 {
                continue
            }

            summaries.append(ClaudeSessionSummary(
                source: .codex,
                id: summary.sessionID,
                summary: summary.derivedTitle,
                firstPrompt: summary.firstUserPrompt,
                modifiedAt: mtime,
                projectPath: summary.cwd,
                transcriptURL: url,
                messageCount: summary.messageCount
            ))
        }

        return summaries
    }

    func loadTranscript(for session: ClaudeSessionSummary) throws -> [TranscriptMessage] {
        try PerfLog.time("CodexStorage.loadTranscript") {
            try parser.parseTranscript(from: session.transcriptURL)
        }
    }

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
