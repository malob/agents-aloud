import Foundation
import SQLite3
import Testing
@testable import ClaudeCodeVoice

struct CodexThreadDatabaseTests {
    @Test
    func loadThreadsFiltersSourceSubagentsBeforeLimit() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-CodexThreadDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let dbURL = temporaryRoot.appendingPathComponent("state_5.sqlite", isDirectory: false)
        try makeCodexStateDatabase(at: dbURL)

        let rows = try CodexThreadDatabase(path: dbURL).loadThreads(since: .distantPast)

        #expect(rows.map(\.id) == ["normal"])
    }
}

private enum TestSQLiteError: Error {
    case openFailed(String)
    case execFailed(String)
}

private func makeCodexStateDatabase(at url: URL) throws {
    var db: OpaquePointer?
    let openResult = sqlite3_open(url.path, &db)
    guard openResult == SQLITE_OK, let db else {
        defer { sqlite3_close_v2(db) }
        throw TestSQLiteError.openFailed(sqliteMessage(db))
    }
    defer { sqlite3_close_v2(db) }

    try exec(
        """
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
