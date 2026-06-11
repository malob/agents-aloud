import Foundation

// One running Claude Code process, as reported by the live-session
// registry at ~/.claude/sessions/ (one JSON file per PID). This is
// the sidebar's source of truth for the Claude side: the app shows
// conversations the user is actively having, not a recency window of
// transcript files.
struct LiveClaudeSession: Hashable {
    // `status` from the registry: "busy" while the agent is working,
    // "idle" between turns. Desktop-app entries omit it entirely, so
    // absence means unknown, not idle.
    enum Activity: String {
        case busy
        case idle
    }

    let pid: Int32
    let sessionID: String
    let cwd: String
    // Terminal /name, when set. Desktop-app session names do NOT
    // propagate into the registry (observed 2026-06), so nil here
    // does not mean the session is unnamed everywhere.
    let name: String?
    let activity: Activity?
    let startedAt: Date
}

// Sidebar-facing liveness of a session. Lives on SessionSummary so
// views can render a status indicator without knowing about the
// registry. `.notLive` covers Codex sessions and walk-fallback Claude
// sessions; `.liveUnknown` covers live sessions whose registry entry
// has no status field (desktop app).
enum SessionLiveness: Hashable {
    case notLive
    case liveBusy
    case liveIdle
    case liveUnknown

    var isLive: Bool {
        self != .notLive
    }
}
