import Foundation
import OSLog
import SQLite3

// Read-only wrapper around Codex CLI's `~/.codex/state_5.sqlite`,
// specifically the `threads` table — which is the authoritative,
// 100%-coverage index of all Codex sessions on the user's machine.
//
// Why we use this directly instead of walking ~/.codex/sessions/
// and parsing each rollout JSONL: a single SELECT query gets us
// every field the sidebar needs (id, rollout_path, cwd, title,
// first user message, mtime), already filtered for archived runs
// and sub-agent rollouts. The walk-and-parse approach reads each
// file just to extract metadata that already lives in this DB.
//
// Schema reference: codex-rs/state in the openai/codex repo. The
// table was introduced as part of the original session-state
// migration set (around v17-22 in `_sqlx_migrations`); we depend on
// columns added by migration 22 ("threads agent path") at the
// latest, so we treat 22 as our minimum supported version.
//
// On macOS this uses libsqlite3, the system C library shipped with
// the OS at /usr/lib/libsqlite3.dylib, exposed to Swift via the
// `SQLite3` module. No third-party dependency, no subprocess —
// just an in-process function call.
//
// Concurrent access: we open with SQLITE_OPEN_READONLY, which lets
// us coexist with the live Codex CLI writing to the same DB (it
// uses WAL mode per the .sqlite-wal/.sqlite-shm files alongside).
// SQLITE_OPEN_NOMUTEX is fine because each call opens its own
// short-lived connection — no shared SQLite handle to protect.
// Concurrent SQLite readers are safe by design.
//
// Plain class (not actor) because there's no per-instance mutable
// state worth serializing; the only stored property is the path,
// which is `let`. Calling actors (CodexStorageService) provide all
// the serialization the rest of the system needs.
final class CodexThreadDatabase: Sendable {
    private static let logger = Logger(subsystem: "local.claudecodevoice", category: "CodexThreadDatabase")

    // Lower bound on `_sqlx_migrations.version` we know works.
    // Migration 22 ("threads agent path") was the last addition we
    // explicitly depend on (the agent_nickname/agent_role/has_user_event
    // columns are older still). Newer schemas should be forward-
    // compatible because we never SELECT * — just the fixed column
    // list below.
    private static let minimumKnownMigration: Int64 = 22

    struct Row {
        let id: String
        let rolloutPath: String
        let cwd: String
        let title: String
        let firstUserMessage: String
        let updatedAt: Date
    }

    enum DBError: Error {
        case databaseUnavailable(URL)
        case schemaUnsupported(latestMigration: Int64)
        case sqlError(String)
    }

    private let path: URL

    init(path: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("state_5.sqlite", isDirectory: false)
    ) {
        self.path = path
    }

    // The single query we run. Returns up to 50 most-recent
    // non-archived non-sub-agent threads modified after `since`.
    func loadThreads(since: Date) throws -> [Row] {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw DBError.databaseUnavailable(path)
        }

        // Open the live DB with `?mode=ro&immutable=1` URI semantics.
        //
        // Plain SQLITE_OPEN_READONLY doesn't work for WAL-mode
        // databases — SQLite still needs write access to the
        // -shm/-wal files for lock coordination, and our read-only
        // flag forbids that, producing SQLITE_CANTOPEN at prepare
        // time. Reproduces from the CLI too: `sqlite3 -readonly`
        // fails identically. The fix is `?immutable=1`, which tells
        // SQLite to skip WAL machinery and read only the main file
        // directly. Officially intended for read-only media but
        // works fine for "I want to peek at a DB another process is
        // writing." See https://www.sqlite.org/uri.html.
        //
        // Tradeoff: we see only checkpointed data. Recent rows still
        // in the WAL (and not yet folded into the main file) won't
        // appear. Codex checkpoints regularly, so the lag is
        // typically seconds; new sessions show up on the next
        // refresh cycle anyway.
        let uri = "file:\(path.path)?mode=ro&immutable=1"

        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        let openResult = sqlite3_open_v2(uri, &db, openFlags, nil)
        guard openResult == SQLITE_OK, let db else {
            sqlite3_close_v2(db)
            throw DBError.sqlError("sqlite3_open_v2 failed: \(openResult) (\(sqlite3StatusMessage(db: db)))")
        }
        defer { sqlite3_close_v2(db) }

        // Extended result codes give diagnostic-friendly errors
        // (SQLITE_CANTOPEN_NOTEMPDIR, etc.) if something does go
        // wrong on prepare/step despite immutable=1.
        sqlite3_extended_result_codes(db, 1)

        try validateSchemaVersion(db: db)

        // `has_user_event` looked like a useful "real conversation"
        // filter from the schema but turned out to be 0 on every
        // thread in practice — Codex never sets it to 1 in the
        // versions we've seen. Filtering on it killed the sidebar.
        // Live with the chance that a few empty-content sessions
        // appear; the user can click past them.
        let sql = """
        SELECT id,
               rollout_path,
               cwd,
               COALESCE(title, ''),
               COALESCE(first_user_message, ''),
               COALESCE(updated_at_ms, updated_at * 1000) AS updated_ms
        FROM threads
        WHERE archived = 0
          AND agent_nickname IS NULL
          AND agent_role IS NULL
          AND CASE
                WHEN json_valid(source) THEN json_extract(source, '$.subagent') IS NULL
                ELSE 1
              END
          AND COALESCE(updated_at_ms, updated_at * 1000) >= ?
        ORDER BY updated_ms DESC
        LIMIT 50;
        """

        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            throw DBError.sqlError("sqlite3_prepare_v2 failed: \(prepareResult) (\(sqlite3StatusMessage(db: db)))")
        }
        defer { sqlite3_finalize(stmt) }

        // Bind the cutoff. SQLite stores `updated_at_ms` in
        // milliseconds-since-epoch; our `since` is a Foundation Date.
        let cutoffMs = Int64(since.timeIntervalSince1970 * 1000)
        let bindResult = sqlite3_bind_int64(stmt, 1, cutoffMs)
        guard bindResult == SQLITE_OK else {
            throw DBError.sqlError("sqlite3_bind_int64 failed: \(bindResult)")
        }

        var rows: [Row] = []
        while true {
            let stepResult = sqlite3_step(stmt)
            switch stepResult {
            case SQLITE_ROW:
                let id = readText(stmt: stmt, column: 0)
                let rolloutPath = readText(stmt: stmt, column: 1)
                let cwd = readText(stmt: stmt, column: 2)
                let title = readText(stmt: stmt, column: 3)
                let firstUserMessage = readText(stmt: stmt, column: 4)
                let updatedMs = sqlite3_column_int64(stmt, 5)
                rows.append(Row(
                    id: id,
                    rolloutPath: rolloutPath,
                    cwd: cwd,
                    title: title,
                    firstUserMessage: firstUserMessage,
                    updatedAt: Date(timeIntervalSince1970: Double(updatedMs) / 1000)
                ))
            case SQLITE_DONE:
                return rows
            default:
                throw DBError.sqlError("sqlite3_step failed: \(stepResult) (\(sqlite3StatusMessage(db: db)))")
            }
        }
    }

    // MARK: - Internals

    private func validateSchemaVersion(db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, "SELECT MAX(version) FROM _sqlx_migrations;", -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            let msg = sqlite3StatusMessage(db: db)
            throw DBError.sqlError("Could not read _sqlx_migrations: code=\(prepareResult) msg=\(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DBError.sqlError("_sqlx_migrations had no rows")
        }
        let latest = sqlite3_column_int64(stmt, 0)

        if latest < Self.minimumKnownMigration {
            throw DBError.schemaUnsupported(latestMigration: latest)
        }
        // Forward-compat: never reject newer schemas. Our SELECT only
        // touches columns that have been stable since migration 22.
        // If that ever changes, the SELECT itself will fail and we'll
        // fall back to the filesystem walk.
    }

    private func readText(stmt: OpaquePointer, column: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, column) else { return "" }
        return String(cString: cString)
    }

    private func sqlite3StatusMessage(db: OpaquePointer?) -> String {
        guard let db, let msg = sqlite3_errmsg(db) else { return "<no message>" }
        return String(cString: msg)
    }
}
