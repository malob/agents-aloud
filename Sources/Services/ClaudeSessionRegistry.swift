import Darwin
import Foundation
import OSLog

// Reader for Claude Code's live-session registry: ~/.claude/sessions/
// holds one JSON file per running process, named <pid>.json, written
// by the CLI on launch, heartbeated with status updates, and removed
// on clean exit. This is the same data `claude agents --json` prints,
// read directly so the sidebar gets it without spawning a subprocess.
//
// Three hard-won facts about the registry (verified empirically
// against claude CLI 2.1.17x, 2026-06):
//
// - `entrypoint` is the field that separates real conversations from
//   noise. Interactive terminal sessions are "cli", the desktop app
//   is "claude-desktop", and `claude --print` runs register as
//   "sdk-cli" — with `kind` still claiming "interactive"(!). This
//   app's own speech rewriter spawns `claude --print` per message,
//   so without the sdk-cli exclusion the sidebar would flash a
//   phantom session on every rewrite.
//
// - Files can outlive crashed processes (cleanup is on clean exit
//   only), so every entry is validated with kill(pid, 0) before use.
//   `procStart` exists as a PID-reuse guard; at macOS PID-recycling
//   rates the kill check alone is adequate for a sidebar.
//
// - Terminal /name lands in `name`; desktop-app names do NOT (the
//   desktop entry simply has no name field). Callers should fall
//   back to transcript-derived titles.
struct ClaudeSessionRegistry: Sendable {
    private static let logger = Logger(subsystem: "me.malob.agentsaloud", category: "SessionRegistry")

    // Entrypoints that represent a conversation the user is actually
    // having. Exclude-by-default for anything else: the known
    // pollution case is "sdk-cli" (--print / SDK runs, including our
    // own rewriter), and future automation entrypoints are more
    // likely to be noise than conversations.
    private static let conversationEntrypoints: Set<String> = ["cli", "claude-desktop"]

    let directory: URL

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    ) {
        self.directory = directory
    }

    // Returns nil when the registry directory doesn't exist — the
    // signal that this claude version doesn't maintain one and the
    // caller should fall back to the transcript-walk source. An
    // existing-but-empty directory returns [] and means exactly what
    // it says: nothing is running.
    func loadLiveSessions() -> [LiveClaudeSession]? {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let decoder = JSONDecoder()
        var sessions: [LiveClaudeSession] = []
        for fileURL in entries where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let entry = try? decoder.decode(RegistryEntry.self, from: data) else {
                Self.logger.debug("Skipping undecodable registry entry \(fileURL.lastPathComponent, privacy: .public)")
                continue
            }

            guard let entrypoint = entry.entrypoint,
                  Self.conversationEntrypoints.contains(entrypoint) else {
                continue
            }

            // kill(pid, 0) delivers no signal but performs the
            // existence check; EPERM still means "alive, not ours".
            guard kill(entry.pid, 0) == 0 || errno == EPERM else {
                Self.logger.debug("Skipping stale registry entry for dead pid \(entry.pid, privacy: .public)")
                continue
            }

            sessions.append(LiveClaudeSession(
                pid: entry.pid,
                sessionID: entry.sessionId,
                cwd: entry.cwd,
                name: entry.name?.trimmedNonEmpty,
                activity: entry.status.flatMap(LiveClaudeSession.Activity.init(rawValue:)),
                startedAt: Date(timeIntervalSince1970: Double(entry.startedAt) / 1000)
            ))
        }
        return sessions
    }

    // Claude Code's mapping from a session's cwd to its directory
    // under ~/.claude/projects/: every non-alphanumeric character
    // becomes '-'. Verified against real examples including
    // /Users/malo/.config/nix-config -> -Users-malo--config-nix-config
    // (the dot produces the double dash) and underscores in
    // /private/var/folders paths also becoming dashes.
    static func projectDirectoryName(forCWD cwd: String) -> String {
        String(cwd.map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        })
    }

    private struct RegistryEntry: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let startedAt: Int64
        let entrypoint: String?
        let name: String?
        let status: String?
    }
}
