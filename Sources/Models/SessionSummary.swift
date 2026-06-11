import Foundation

struct SessionSummary: Identifiable, Hashable {
    // Where this transcript came from. Drives sidebar visuals (per-row
    // source icon, filter chip behavior) and lets the unified
    // storage layer route loadTranscript() to the right backend.
    // Default-defaulted to .claude for migration ease — old call
    // sites and tests don't have to be touched all at once.
    let source: TranscriptSource
    let id: String
    let summary: String
    let firstPrompt: String?
    let modifiedAt: Date?
    let projectPath: String
    let transcriptURL: URL
    // Whether a running CLI process currently owns this session.
    // Drives the sidebar status dot and exempts the session from the
    // recency window (an open-but-idle session stays visible however
    // old its transcript's mtime is). Defaults to .notLive so Codex
    // and walk-fallback construction sites don't change.
    let liveness: SessionLiveness

    init(
        source: TranscriptSource = .claude,
        id: String,
        summary: String,
        firstPrompt: String?,
        modifiedAt: Date?,
        projectPath: String,
        transcriptURL: URL,
        liveness: SessionLiveness = .notLive
    ) {
        self.source = source
        self.id = id
        self.summary = summary
        self.firstPrompt = firstPrompt
        self.modifiedAt = modifiedAt
        self.projectPath = projectPath
        self.transcriptURL = transcriptURL
        self.liveness = liveness
    }

    var projectName: String {
        let trimmedPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return "Unknown Project"
        }

        return URL(fileURLWithPath: trimmedPath).lastPathComponent
    }
}
