import Foundation
import SQLite3
import Testing
@testable import AgentsAloud

struct CodexThreadDatabaseTests {
    @Test
    func loadThreadsFiltersSourceSubagentsBeforeLimit() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentsAloud-CodexThreadDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let dbURL = temporaryRoot.appendingPathComponent("state_5.sqlite", isDirectory: false)
        try makeCodexStateDatabase(at: dbURL)

        let rows = try CodexThreadDatabase(path: dbURL).loadThreads()

        #expect(rows.map(\.id) == ["normal"])
    }

    // Codex v149 relocated state_5.sqlite into a `sqlite/`
    // subdirectory; the old top-level path lingers and goes stale.
    // Prefer the relocated DB when it exists, else the legacy path.
    @Test
    func preferredDatabaseURLPrefersRelocatedThenLegacy() throws {
        let codexDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentsAloud-CodexPathTests-\(UUID().uuidString)", isDirectory: true)
        let sqliteDir = codexDir.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: sqliteDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexDir) }

        let legacy = codexDir.appendingPathComponent("state_5.sqlite", isDirectory: false)
        let relocated = sqliteDir.appendingPathComponent("state_5.sqlite", isDirectory: false)

        // Neither present yet → falls back to the legacy path (so the
        // missing-file path still triggers the filesystem-walk fallback
        // exactly as before).
        #expect(CodexThreadDatabase.preferredDatabaseURL(codexDirectory: codexDir) == legacy)

        // Legacy only.
        try Data().write(to: legacy)
        #expect(CodexThreadDatabase.preferredDatabaseURL(codexDirectory: codexDir) == legacy)

        // Both present (the post-update reality) → relocated wins.
        try Data().write(to: relocated)
        #expect(CodexThreadDatabase.preferredDatabaseURL(codexDirectory: codexDir) == relocated)
    }

    // Regression: Codex leaves the DB in WAL journal mode. When it
    // exits cleanly, SQLite checkpoints and DELETES the -wal/-shm
    // sidecars, leaving a bare main file whose header still says WAL.
    // A read-only connection cannot open that file (it would need to
    // create the -shm index, which needs write access), so the
    // snapshot must be opened read-write or every load fails with
    // SQLITE_CANTOPEN and the sidebar drops to the filesystem walk.
    @Test
    func loadThreadsOpensCheckpointedWALDatabaseWithoutSidecars() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentsAloud-CodexThreadDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let dbURL = temporaryRoot.appendingPathComponent("state_5.sqlite", isDirectory: false)
        try makeCodexStateDatabase(at: dbURL)

        // Closing the fixture's connection checkpoints the WAL into
        // the main file, but Apple's system SQLite persists the (now
        // drained) sidecar files on close, unlike Codex's bundled
        // SQLite which deletes them. Remove them explicitly to
        // reproduce the state a cleanly-exited Codex leaves behind:
        // a bare main file whose header still says WAL.
        try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
        #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-wal"))

        let rows = try CodexThreadDatabase(path: dbURL).loadThreads()

        #expect(rows.map(\.id) == ["normal"])
    }

    // The other half of the snapshot contract: while a writer holds
    // the DB open, committed rows live in the -wal file (the main
    // file may not even contain the schema yet). The snapshot must
    // copy the sidecars and read through them, or it sees a stale /
    // empty database. This pins the original WAL-staleness fix.
    @Test
    func loadThreadsSeesRowsStillInWALWhileWriterIsOpen() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentsAloud-CodexThreadDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let dbURL = temporaryRoot.appendingPathComponent("state_5.sqlite", isDirectory: false)
        let writer = try openCodexStateDatabase(at: dbURL)
        defer { sqlite3_close_v2(writer) }
        try populateCodexStateDatabase(writer)

        // With the writer still open, nothing has been checkpointed:
        // the schema and rows are only reachable through the -wal.
        #expect(FileManager.default.fileExists(atPath: dbURL.path + "-wal"))

        let rows = try CodexThreadDatabase(path: dbURL).loadThreads()

        #expect(rows.map(\.id) == ["normal"])
    }
}

private enum TestSQLiteError: Error {
    case openFailed(String)
    case execFailed(String)
}

private func makeCodexStateDatabase(at url: URL) throws {
    let db = try openCodexStateDatabase(at: url)
    defer { sqlite3_close_v2(db) }
    try populateCodexStateDatabase(db)
}

private func openCodexStateDatabase(at url: URL) throws -> OpaquePointer {
    var db: OpaquePointer?
    let openResult = sqlite3_open(url.path, &db)
    guard openResult == SQLITE_OK, let db else {
        defer { sqlite3_close_v2(db) }
        throw TestSQLiteError.openFailed(sqliteMessage(db))
    }
    return db
}

private func populateCodexStateDatabase(_ db: OpaquePointer) throws {
    try exec(
        """
        PRAGMA journal_mode=WAL;

        CREATE TABLE _sqlx_migrations (version INTEGER NOT NULL PRIMARY KEY);
        INSERT INTO _sqlx_migrations (version) VALUES (22);

        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            cwd TEXT NOT NULL,
            title TEXT NOT NULL,
            first_user_message TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            updated_at_ms INTEGER,
            archived INTEGER NOT NULL DEFAULT 0,
            agent_nickname TEXT,
            agent_role TEXT,
            source TEXT NOT NULL
        );

        INSERT INTO threads (
            id, rollout_path, cwd, title, first_user_message,
            updated_at, updated_at_ms, archived, agent_nickname, agent_role, source
        ) VALUES
            (
                'guardian',
                '/tmp/guardian.jsonl',
                '/tmp/project',
                'Guardian approval check',
                'The following is the Codex agent history...',
                3000,
                3000000,
                0,
                NULL,
                NULL,
                '{"subagent":{"other":"guardian"}}'
            ),
            (
                'memory',
                '/tmp/memory.jsonl',
                '/tmp/project',
                'Memory consolidation',
                'Consolidate memories',
                2000,
                2000000,
                0,
                NULL,
                NULL,
                '{"subagent":"memory_consolidation"}'
            ),
            (
                'normal',
                '/tmp/normal.jsonl',
                '/tmp/project',
                'Normal thread',
                'Build the thing',
                1000,
                1000000,
                0,
                NULL,
                NULL,
                'vscode'
            );
        """,
        db: db
    )
}

private func exec(_ sql: String, db: OpaquePointer) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? sqliteMessage(db)
        sqlite3_free(errorMessage)
        throw TestSQLiteError.execFailed(message)
    }
}

private func sqliteMessage(_ db: OpaquePointer?) -> String {
    guard let db, let message = sqlite3_errmsg(db) else { return "<no sqlite message>" }
    return String(cString: message)
}
