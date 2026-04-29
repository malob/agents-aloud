import Foundation

struct ClaudeSessionSummary: Identifiable, Hashable {
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
    // Optional because not all sources expose message counts cheaply.
    // Codex's `state_5.sqlite` `threads` table doesn't track per-thread
    // counts, and we'd rather hide the badge than read 100s of MB of
    // JSONL on every sidebar refresh just to populate it. nil ⇒ skip
    // the badge in the sidebar.
    let messageCount: Int?

    init(
        source: TranscriptSource = .claude,
        id: String,
        summary: String,
        firstPrompt: String?,
        modifiedAt: Date?,
        projectPath: String,
        transcriptURL: URL,
        messageCount: Int?
    ) {
        self.source = source
        self.id = id
        self.summary = summary
        self.firstPrompt = firstPrompt
        self.modifiedAt = modifiedAt
        self.projectPath = projectPath
        self.transcriptURL = transcriptURL
        self.messageCount = messageCount
    }

    var projectName: String {
        let trimmedPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return "Unknown Project"
        }

        return URL(fileURLWithPath: trimmedPath).lastPathComponent
    }

    // Empty string ⇒ no badge. Sidebar checks isEmpty before
    // rendering. This keeps the data model honest about "we don't
    // know the count" without lying with a placeholder integer.
    var messageCountLabel: String {
        guard let messageCount else { return "" }
        return messageCount == 1 ? "1 msg" : "\(messageCount) msgs"
    }
}
