import Foundation
import SQLite3
import Testing
@testable import ClaudeCodeVoice

@MainActor
private final class FakeTranscriptFileWatcher: TranscriptFileWatching {
    private var onChange: (@MainActor @Sendable () -> Void)?

    func startWatching(
        fileURL: URL,
        onChange: @escaping @MainActor @Sendable () -> Void,
        onFailure: @escaping @MainActor @Sendable (TranscriptFileWatcherError) -> Void
    ) {
        self.onChange = onChange
    }

    func stop() {
        onChange = nil
    }

    func emitChange() {
        onChange?()
    }
}

// Factored helper: makeTestAppModel returns a fully-wired AppModel with
// test-scoped temp dirs, fake watcher, fake speech drivers, and unique
// UserDefaults + Keychain services so parallel tests don't collide.
// A CodexStorageService pointing at paths that don't exist. The
// service handles missing directories + DBs gracefully (returns [])
// — this keeps AppModel.refreshSessions() from accidentally walking
// the dev machine's real ~/.codex/sessions or reading
// ~/.codex/state_5.sqlite on every test that calls .start().
//
// Note both the sessions roots AND the thread database path must
// be sandboxed; without overriding `threadDatabase`, CodexStorageService
// would use the default DB at ~/.codex/state_5.sqlite and tests
// would see real Codex sessions show up in the model.
@MainActor
private func sandboxedCodexStorageService() -> CodexStorageService {
    let nonexistent = URL(fileURLWithPath: "/var/empty/codex-tests-no-sessions-\(UUID().uuidString)", isDirectory: true)
    let nonexistentDB = URL(fileURLWithPath: "/var/empty/codex-tests-no-db-\(UUID().uuidString).sqlite", isDirectory: false)
    return CodexStorageService(
        sessionsRoot: nonexistent,
        archivedSessionsRoot: nonexistent,
        threadDatabase: CodexThreadDatabase(path: nonexistentDB)
    )
}

private enum TestDatabaseError: Error {
    case setupFailed(String)
}

// Minimal Codex state DB containing ordinary threads, so a test can
// make the Codex source produce sidebar sessions without any rollout
// JSONL on disk. Schema mirrors the fixture in
// CodexThreadDatabaseTests (migration 22).
private func makeCodexStateDatabase(
    at url: URL,
    threads: [(id: String, updatedAt: Date)]
) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        sqlite3_close_v2(db)
        throw TestDatabaseError.setupFailed("sqlite3_open failed for \(url.path)")
    }
    defer { sqlite3_close_v2(db) }

    let rows = threads.map { thread -> String in
        let updatedSeconds = Int64(thread.updatedAt.timeIntervalSince1970)
        return """
        (
            '\(thread.id)',
            '/tmp/rollout-\(thread.id).jsonl',
            '/tmp/project',
            'Codex thread \(thread.id)',
            'Build the thing',
            \(updatedSeconds),
            \(updatedSeconds * 1000),
            0,
            NULL,
            NULL,
            'vscode'
        )
        """
    }
    let sql = """
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
    ) VALUES \(rows.joined(separator: ",\n"));
    """
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? "sqlite3_exec failed"
        sqlite3_free(errorMessage)
        throw TestDatabaseError.setupFailed(message)
    }
}

@MainActor
private struct TestAppModelFixture {
    let model: AppModel
    let watcher: FakeTranscriptFileWatcher
    let liveReadWatcher: FakeTranscriptFileWatcher
    // Single fake driver wired as systemVoiceDriver — the new default
    // backend after AVSpeech was removed. Tests that previously
    // asserted against `avDriver` now read from this same driver
    // (since `.systemVoice` is the default backend, all playback
    // routes here unless a test explicitly switches to ElevenLabs).
    let fakeDriver: FakeSpeechBackendDriver
    let projectsRoot: URL
    let temporaryRoot: URL
    let userDefaultsSuite: String
    let userDefaults: UserDefaults

    func cleanup() {
        userDefaults.removePersistentDomain(forName: userDefaultsSuite)
        try? FileManager.default.removeItem(at: temporaryRoot)
    }
}

@MainActor
private func makeTestAppModel(
    transcripts: [String: String] = [:],
    speechTextProcessor: any SpeechTextProcessor = PassthroughSpeechProcessor()
) throws -> TestAppModelFixture {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)", isDirectory: true)
    let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
    let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
    try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

    for (name, contents) in transcripts {
        let transcriptURL = projectDirectory.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    let defaultsSuiteName = "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
    let watcher = FakeTranscriptFileWatcher()
    let liveReadWatcher = FakeTranscriptFileWatcher()
    let fakeDriver = FakeSpeechBackendDriver(
        availableVoices: [SpeechVoiceOption(id: "system.voice", name: "System", language: "en-US")]
    )
    let speechController = SpeechController(
        systemVoiceDriver: fakeDriver
    )
    // Sandboxed Codex storage pointing at empty temp dirs and a
    // non-existent DB — without these, the default
    // CodexStorageService() points at the real ~/.codex/sessions/
    // and ~/.codex/state_5.sqlite on the dev machine and tests would
    // see real Codex sessions / walk (potentially huge) rollout
    // files for every model.start().
    let codexSessionsRoot = temporaryRoot.appendingPathComponent("codex-sessions", isDirectory: true)
    let codexArchivedRoot = temporaryRoot.appendingPathComponent("codex-archived", isDirectory: true)
    let codexDBPath = temporaryRoot.appendingPathComponent("codex-state.sqlite", isDirectory: false)
    try fileManager.createDirectory(at: codexSessionsRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: codexArchivedRoot, withIntermediateDirectories: true)
    // Intentionally do NOT create codexDBPath — the DB load path
    // returns databaseUnavailable when the file is missing, exercising
    // the filesystem-fallback code path in tests.

    let model = AppModel(
        storageService: ClaudeStorageService(projectsRoot: projectsRoot),
        codexStorageService: CodexStorageService(
            sessionsRoot: codexSessionsRoot,
            archivedSessionsRoot: codexArchivedRoot,
            threadDatabase: CodexThreadDatabase(path: codexDBPath)
        ),
        speechController: speechController,
        userDefaults: userDefaults,
        selectedTranscriptWatcher: watcher,
        liveReadTranscriptWatcher: liveReadWatcher,
        keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"),
        speechTextProcessor: speechTextProcessor
    )

    return TestAppModelFixture(
        model: model,
        watcher: watcher,
        liveReadWatcher: liveReadWatcher,
        fakeDriver: fakeDriver,
        projectsRoot: projectsRoot,
        temporaryRoot: temporaryRoot,
        userDefaultsSuite: defaultsSuiteName,
        userDefaults: userDefaults
    )
}

private let fourMessageTranscript = """
{"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-1","cwd":"/Users/malo/Code/demo-project","message":{"role":"user","content":"First question."}}
{"type":"assistant","uuid":"assistant-1","timestamp":"2026-04-17T17:00:01Z","sessionId":"session-1","message":{"role":"assistant","content":[{"type":"text","text":"Reply one."}]}}
{"type":"user","uuid":"user-2","timestamp":"2026-04-17T17:00:02Z","sessionId":"session-1","message":{"role":"user","content":"Second question."}}
{"type":"assistant","uuid":"assistant-2","timestamp":"2026-04-17T17:00:03Z","sessionId":"session-1","message":{"role":"assistant","content":[{"type":"text","text":"Reply two."}]}}

"""

struct AppModelTests {
    @Test
    @MainActor
    func transcriptFailurePreservesLastKnownMessages() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-1.jsonl", isDirectory: false)
        let watcher = FakeTranscriptFileWatcher()
        let defaultsSuiteName = "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))

        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try initialTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        defer {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
            try? fileManager.removeItem(at: temporaryRoot)
        }

        // Pass a test-scoped Keychain service so AppModel.init doesn't
        // read from the real app's Keychain item. Without this, every
        // `swift test` run prompts "swiftpm-testing-helper wants to
        // access local.claudecodevoice" because the test binary's
        // identity doesn't match the real app's ACL.
        let model = AppModel(
            storageService: ClaudeStorageService(projectsRoot: projectsRoot),
            codexStorageService: sandboxedCodexStorageService(),
            speechController: SpeechController(),
            userDefaults: userDefaults,
            selectedTranscriptWatcher: watcher,
            keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)")
        )

        await model.start()

        let firstSession = try #require(model.sessions.first)
        model.selectedSessionID = firstSession.id

        // Wait for the async refreshTranscript kicked off by selectedSessionID.didSet.
        try await waitUntil { model.transcriptState.messages(for: firstSession.id).count == 2 }

        let selectedSessionID = try #require(model.selectedSessionID)
        let originalMessages = model.transcriptState.messages(for: selectedSessionID)

        try fileManager.removeItem(at: transcriptURL)
        watcher.emitChange()

        // Wait for the file-read error to propagate into .failed state.
        try await waitUntil {
            model.transcriptState.errorMessage(for: selectedSessionID) != nil
        }

        #expect(model.transcriptState.messages(for: selectedSessionID) == originalMessages)
        #expect(model.transcriptState.errorMessage(for: selectedSessionID)?.contains("Unable to load transcript") == true)
        #expect(model.errorMessage == nil)
    }

    // MARK: - Session load failures

    @Test
    @MainActor
    func sessionLoadFailureWithEmptySidebarReportsFailingSource() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        // Never created — ClaudeStorageService throws on the missing
        // directory, and the sandboxed Codex service returns [].
        let projectsRoot = temporaryRoot.appendingPathComponent("missing-projects", isDirectory: true)
        let defaultsSuiteName = "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
            try? fileManager.removeItem(at: temporaryRoot)
        }

        let model = AppModel(
            storageService: ClaudeStorageService(projectsRoot: projectsRoot),
            codexStorageService: sandboxedCodexStorageService(),
            speechController: SpeechController(),
            userDefaults: userDefaults,
            selectedTranscriptWatcher: FakeTranscriptFileWatcher(),
            keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)")
        )

        await model.start()

        #expect(model.sessions.isEmpty)
        let message = try #require(model.errorMessage)
        #expect(message.contains("Unable to load sessions"))
        #expect(message.contains("Claude:"))
    }

    @Test
    @MainActor
    func singleSourceFailureKeepsSurvivingSourcesSessions() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        // Claude's projects root is never created → that source throws.
        // Codex serves one thread from its state DB → the sidebar
        // should show it, and the Claude failure stays log-only.
        let projectsRoot = temporaryRoot.appendingPathComponent("missing-projects", isDirectory: true)
        let codexDBPath = temporaryRoot.appendingPathComponent("codex-state.sqlite", isDirectory: false)
        try makeCodexStateDatabase(at: codexDBPath, threads: [(id: "codex-thread-1", updatedAt: Date())])
        let missingCodexRoot = temporaryRoot.appendingPathComponent("missing-codex-sessions", isDirectory: true)
        let defaultsSuiteName = "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
            try? fileManager.removeItem(at: temporaryRoot)
        }

        let model = AppModel(
            storageService: ClaudeStorageService(projectsRoot: projectsRoot),
            codexStorageService: CodexStorageService(
                sessionsRoot: missingCodexRoot,
                archivedSessionsRoot: missingCodexRoot,
                threadDatabase: CodexThreadDatabase(path: codexDBPath)
            ),
            speechController: SpeechController(),
            userDefaults: userDefaults,
            selectedTranscriptWatcher: FakeTranscriptFileWatcher(),
            keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)")
        )

        await model.start()

        #expect(model.sessions.map(\.id) == ["codex-thread-1"])
        #expect(model.sessions.first?.source == .codex)
        #expect(model.errorMessage == nil)
    }

    // MARK: - Unified sidebar floor

    @Test
    @MainActor
    func unifiedFloorTrimsStaleSourcePaddingWhenWindowIsFull() async throws {
        // Five fresh Codex sessions fill the 24h window; Claude has
        // only a stale session. Per-source padding still hands that
        // stale session to the merge as a candidate, but the unified
        // floor must trim it — the sidebar already has enough fresh
        // content. This is the "five ancient Codex sessions at the
        // bottom of the sidebar" bug, with the sources swapped.
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let defaultsSuiteName = "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
            try? fileManager.removeItem(at: temporaryRoot)
        }

        let staleClaudeURL = projectDirectory.appendingPathComponent("stale-claude.jsonl", isDirectory: false)
        try fourMessageTranscript
            .replacingOccurrences(of: "session-1", with: "stale-claude")
            .write(to: staleClaudeURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-10 * 24 * 60 * 60)],
            ofItemAtPath: staleClaudeURL.path
        )

        let codexDBPath = temporaryRoot.appendingPathComponent("codex-state.sqlite", isDirectory: false)
        let freshCodexIDs = (1...5).map { "codex-fresh-\($0)" }
        try makeCodexStateDatabase(
            at: codexDBPath,
            threads: freshCodexIDs.enumerated().map { offset, id in
                // Stagger by a minute so the sort order is deterministic.
                (id: id, updatedAt: Date().addingTimeInterval(TimeInterval(-60 * offset)))
            }
        )
        let missingCodexRoot = temporaryRoot.appendingPathComponent("missing-codex-sessions", isDirectory: true)

        let model = AppModel(
            storageService: ClaudeStorageService(projectsRoot: projectsRoot),
            codexStorageService: CodexStorageService(
                sessionsRoot: missingCodexRoot,
                archivedSessionsRoot: missingCodexRoot,
                threadDatabase: CodexThreadDatabase(path: codexDBPath)
            ),
            speechController: SpeechController(),
            userDefaults: userDefaults,
            selectedTranscriptWatcher: FakeTranscriptFileWatcher(),
            keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)")
        )

        await model.start()

        #expect(model.sessions.map(\.id) == freshCodexIDs)
        #expect(model.sessions.allSatisfy { $0.source == .codex })
    }

    @Test
    @MainActor
    func unifiedFloorPadsWithMostRecentStaleSessionsWhenWindowIsSparse() async throws {
        // One fresh Claude session, one stale Claude session, one
        // stale Codex thread. The window alone (1) is under the
        // floor, so the stale sessions should pad the sidebar —
        // newest first, across sources.
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let defaultsSuiteName = "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
            try? fileManager.removeItem(at: temporaryRoot)
        }

        for (name, age) in [("fresh-claude", TimeInterval(0)), ("stale-claude", 10 * 24 * 60 * 60)] {
            let url = projectDirectory.appendingPathComponent("\(name).jsonl", isDirectory: false)
            try fourMessageTranscript
                .replacingOccurrences(of: "session-1", with: name)
                .write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)],
                ofItemAtPath: url.path
            )
        }

        let codexDBPath = temporaryRoot.appendingPathComponent("codex-state.sqlite", isDirectory: false)
        try makeCodexStateDatabase(
            at: codexDBPath,
            threads: [(id: "stale-codex", updatedAt: Date().addingTimeInterval(-5 * 24 * 60 * 60))]
        )
        let missingCodexRoot = temporaryRoot.appendingPathComponent("missing-codex-sessions", isDirectory: true)

        let model = AppModel(
            storageService: ClaudeStorageService(projectsRoot: projectsRoot),
            codexStorageService: CodexStorageService(
                sessionsRoot: missingCodexRoot,
                archivedSessionsRoot: missingCodexRoot,
                threadDatabase: CodexThreadDatabase(path: codexDBPath)
            ),
            speechController: SpeechController(),
            userDefaults: userDefaults,
            selectedTranscriptWatcher: FakeTranscriptFileWatcher(),
            keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)")
        )

        await model.start()

        #expect(model.sessions.map(\.id) == ["fresh-claude", "stale-codex", "stale-claude"])
    }

    // MARK: - playMessagesFromHere

    @Test
    @MainActor
    func playMessagesFromHereStartingAtAssistantPlaysAllSubsequentAssistants() async throws {
        let fixture = try makeTestAppModel(transcripts: ["session-1.jsonl": fourMessageTranscript])
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let firstAssistant = try #require(messages.first(where: { $0.id == "assistant-1" }))

        fixture.model.playMessagesFromHere(firstAssistant)

        // Both assistant messages should be driven: first via playNow (started),
        // second via enqueue (started once first finishes). The fake driver
        // doesn't auto-finish, so only the first reaches the driver.
        // Wait for the async processing + playNow to land.
        try await waitUntil { fixture.fakeDriver.startedRequests.map(\.messageID) == ["assistant-1"] }
        // And the next message must have been enqueued before we emit didFinish.
        try await waitUntil { fixture.model.speechController.currentMessageID == "assistant-1" }

        fixture.fakeDriver.emit(.didFinish(fixture.fakeDriver.startedRequests[0].playbackID))

        try await waitUntil {
            fixture.fakeDriver.startedRequests.map(\.messageID) == ["assistant-1", "assistant-2"]
        }
    }

    @Test
    @MainActor
    func playMessagesFromHereStartingAtUserSkipsToNextAssistant() async throws {
        let fixture = try makeTestAppModel(transcripts: ["session-1.jsonl": fourMessageTranscript])
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let secondUser = try #require(messages.first(where: { $0.id == "user-2" }))

        fixture.model.playMessagesFromHere(secondUser)

        // user-2 should be skipped; assistant-2 is the first speakable
        // message at-or-after the anchor.
        try await waitUntil { fixture.fakeDriver.startedRequests.map(\.messageID) == ["assistant-2"] }
    }

    @Test
    @MainActor
    func playMessagesFromHereWithNoSubsequentAssistantsIsNoOp() async throws {
        let fixture = try makeTestAppModel(transcripts: ["session-1.jsonl": fourMessageTranscript])
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let lastAssistant = try #require(messages.first(where: { $0.id == "assistant-2" }))

        fixture.model.playMessagesFromHere(lastAssistant)

        // Last assistant plays; nothing queued after.
        try await waitUntil { fixture.fakeDriver.startedRequests.map(\.messageID) == ["assistant-2"] }

        fixture.fakeDriver.emit(.didFinish(fixture.fakeDriver.startedRequests[0].playbackID))
        // Still only one started — queue drained.
        #expect(fixture.fakeDriver.startedRequests.count == 1)
    }

    // MARK: - Live Speak seeding

    @Test
    @MainActor
    func liveSpeakEnabledDuringColdLoadDoesNotReplayHistory() async throws {
        // Select a never-loaded session and toggle Live Speak before
        // the first transcript load lands. The toggle must not seed an
        // explicit empty known-set — that would make the entire loaded
        // history look "new" and speak up to a full window of old
        // messages. New arrivals after the load should still speak.
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-1.jsonl", isDirectory: false)
        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try fourMessageTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let defaultsSuiteName = "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        let watcher = FakeTranscriptFileWatcher()
        let fakeDriver = FakeSpeechBackendDriver(
            availableVoices: [SpeechVoiceOption(id: "system.voice", name: "System", language: "en-US")]
        )
        let controller = SpeechController(systemVoiceDriver: fakeDriver)
        let model = AppModel(
            storageService: ClaudeStorageService(projectsRoot: projectsRoot),
            codexStorageService: sandboxedCodexStorageService(),
            speechController: controller,
            userDefaults: userDefaults,
            selectedTranscriptWatcher: watcher,
            keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)")
        )
        defer {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
            try? fileManager.removeItem(at: temporaryRoot)
        }

        await model.start()
        let firstSession = try #require(model.sessions.first)

        // Toggle Live Speak synchronously after selecting, before the
        // selection's load task has had a chance to run — the cold-load
        // race window.
        model.selectedSessionID = firstSession.id
        model.setLiveReadEnabled(true)

        try await waitUntil { model.transcriptState.messages(for: firstSession.id).count == 4 }

        // The two historical assistant messages must not have entered
        // the speech pipeline.
        #expect(controller.currentMessageID == nil)
        #expect(controller.queue.isEmpty)

        // A genuinely new arrival should still speak.
        let assistantLine = "{\"type\":\"assistant\",\"uuid\":\"assistant-3\",\"timestamp\":\"2026-04-17T17:00:04Z\",\"sessionId\":\"session-1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Reply three.\"}]}}\n"
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(assistantLine.utf8))
        try handle.close()

        watcher.emitChange()

        try await waitUntil { controller.currentMessageID == "assistant-3" }
    }

    @Test
    @MainActor
    func liveSpeakOnEmptySessionSpeaksFirstNewAssistantMessage() async throws {
        // Session starts with only a user prompt; the assistant hasn't
        // responded yet. User enables Live Speak, then a new assistant
        // message arrives. The old `!previousIDs.isEmpty` guard would
        // incorrectly skip this first message and mark it "known" forever.
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-1.jsonl", isDirectory: false)
        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

        // Start with a session that has only a user prompt, no assistant reply.
        let initialContent = """
        {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-1","cwd":"/Users/malo/Code/demo-project","message":{"role":"user","content":"Start question."}}

        """
        try initialContent.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let defaultsSuiteName = "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        let watcher = FakeTranscriptFileWatcher()
        let fakeDriver = FakeSpeechBackendDriver(
            availableVoices: [SpeechVoiceOption(id: "system.voice", name: "System", language: "en-US")]
        )
        let controller = SpeechController(systemVoiceDriver: fakeDriver)
        let model = AppModel(
            storageService: ClaudeStorageService(projectsRoot: projectsRoot),
            codexStorageService: sandboxedCodexStorageService(),
            speechController: controller,
            userDefaults: userDefaults,
            selectedTranscriptWatcher: watcher,
            keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)")
        )
        defer {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
            try? fileManager.removeItem(at: temporaryRoot)
        }

        await model.start()
        let firstSession = try #require(model.sessions.first)
        model.selectedSessionID = firstSession.id
        try await waitUntil { model.transcriptState.messages(for: firstSession.id).count == 1 }

        // Enable Live Speak — seeds knownAssistantMessageIDsBySession
        // with the empty set (no assistant messages yet).
        model.setLiveReadEnabled(true)

        // Append the first assistant reply to the session.
        let assistantLine = "{\"type\":\"assistant\",\"uuid\":\"assistant-1\",\"timestamp\":\"2026-04-17T17:00:01Z\",\"sessionId\":\"session-1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"First reply.\"}]}}\n"
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(assistantLine.utf8))
        try handle.close()

        watcher.emitChange()

        try await waitUntil {
            fakeDriver.startedRequests.contains(where: { $0.messageID == "assistant-1" })
        }
    }

    // MARK: - isPreparingPlayback flag lifecycle

    @Test
    @MainActor
    func stopPlaybackClearsPreparingFlagImmediately() async throws {
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let first = try #require(messages.first(where: { $0.id == "assistant-1" }))

        fixture.model.playMessage(first)
        try await waitUntil { processor.pendingCount == 1 }
        #expect(fixture.model.isPreparingPlayback)

        fixture.model.stopPlayback()

        // Flag MUST clear synchronously — otherwise the Stop button
        // appears briefly still-enabled after user pressed it.
        #expect(!fixture.model.isPreparingPlayback)

        // Resume the suspended continuation so the prep Task can exit
        // cleanly (its guard `!Task.isCancelled` then bails). Otherwise
        // the Task lingers until process exit, holding references.
        processor.releaseAll()
    }

    @Test
    @MainActor
    func sessionSwitchDoesNotClearPlaybackQueue() async throws {
        // The queue is cross-session. Navigating away from session A
        // — even to nil (no selection) — leaves A's queued and in-
        // flight items alone. User's "Stop" button is the only way
        // to clear them.
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let first = try #require(messages.first(where: { $0.id == "assistant-1" }))

        fixture.model.playMessage(first)
        try await waitUntil { processor.pendingCount == 1 }
        #expect(fixture.model.isPreparingPlayback)

        fixture.model.selectedSessionID = nil

        // Queue + in-flight rewrite survive the navigation. Flag stays
        // true because the item is still being prepared.
        #expect(fixture.model.isPreparingPlayback)
        #expect(fixture.model.speechController.queue.contains(where: { $0.id == "assistant-1" }))

        processor.releaseAll()
    }

    @Test
    @MainActor
    func disablingLiveSpeakPreservesManualQueuedItems() async throws {
        // When the user disables Live Speak, auto-queued Live Speak
        // arrivals should drain — but manual clicks shouldn't, since
        // they're independent of the auto feature. Manual Speak
        // already in flight must keep going.
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let first = try #require(messages.first(where: { $0.id == "assistant-1" }))

        fixture.model.setLiveReadEnabled(true)
        fixture.model.playMessage(first)
        try await waitUntil { processor.pendingCount == 1 }
        #expect(fixture.model.isPreparingPlayback)

        fixture.model.setLiveReadEnabled(false)

        // Manual click survives: its queue entry and in-flight rewrite
        // are preserved. isPreparingPlayback stays true.
        #expect(fixture.model.isPreparingPlayback)
        #expect(fixture.model.speechController.queue.contains(where: { $0.id == "assistant-1" }))

        processor.releaseAll()
    }

    // MARK: - Preprocessing cancellation

    @Test
    @MainActor
    func stopDuringPreprocessingCancelsPendingPlayback() async throws {
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let firstAssistant = try #require(messages.first(where: { $0.id == "assistant-1" }))

        fixture.model.playMessage(firstAssistant)

        // Wait for the processor to start processing the message.
        try await waitUntil { processor.invocationCount == 1 }
        #expect(processor.pendingCount == 1)

        // User presses Stop before processing completes.
        fixture.model.stopPlayback()

        // Release the processor. The pending task should have been
        // cancelled — playNow must NOT be called.
        processor.releaseAll()

        // Give any would-be stale Task time to land if the cancellation
        // didn't take.
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.fakeDriver.startedRequests.isEmpty)
    }

    @Test
    @MainActor
    func rapidSpeakReclickQueuesBothMessagesInOrder() async throws {
        // Clicking Speak on two messages back-to-back lands both in
        // the queue. The queue's single serial rewriter works on
        // the first, then the second — ordering is determined by
        // queue position, not by rewrite-completion order.
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let first = try #require(messages.first(where: { $0.id == "assistant-1" }))
        let second = try #require(messages.first(where: { $0.id == "assistant-2" }))

        fixture.model.playMessage(first)
        try await waitUntil { processor.pendingCount == 1 }
        #expect(fixture.model.speechController.queue.map(\.id) == ["assistant-1"])

        // Second click: goes after the first manual (FIFO). Rewriter
        // stays on assistant-1; pendingCount does NOT grow to 2.
        fixture.model.playMessage(second)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fixture.model.speechController.queue.map(\.id) == ["assistant-1", "assistant-2"])
        #expect(processor.pendingCount == 1)
        #expect(fixture.model.isPreparingPlayback)

        // Release assistant-1's rewrite. It gets promoted to playing;
        // rewriter moves on to assistant-2.
        processor.releaseNext()
        try await waitUntil { fixture.model.speechController.currentMessageID == "assistant-1" }
        try await waitUntil { processor.pendingCount == 1 }  // assistant-2 now rewriting

        // Release assistant-2. It becomes .ready in the queue (waits
        // behind the still-playing assistant-1).
        processor.releaseAll()
        try await waitUntil {
            fixture.model.speechController.queue.first?.readyText != nil
        }

        // Finish assistant-1's playback → assistant-2 promotes.
        let firstPlaybackID = try #require(fixture.fakeDriver.startedRequests.first?.playbackID)
        fixture.fakeDriver.emit(.didFinish(firstPlaybackID))
        try await waitUntil { fixture.model.speechController.currentMessageID == "assistant-2" }
    }

    @Test
    @MainActor
    func clickingSpeakOnSecondMessageDoesNotCancelFirstsRewrite() async throws {
        // Regression: earlier implementations either cancelled the
        // first rewrite on second click, or ran both concurrently
        // producing out-of-order playback. Current queue model: both
        // enter the queue, the serial rewriter works on them in
        // queue-position order, both play in queue order.
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let assistantOne = try #require(messages.first(where: { $0.id == "assistant-1" }))
        let assistantTwo = try #require(messages.first(where: { $0.id == "assistant-2" }))

        fixture.model.playMessage(assistantOne)
        try await waitUntil { processor.pendingCount == 1 }

        // Click on the second message. It lands in the queue after
        // the first. The first's rewrite keeps going (not cancelled).
        fixture.model.playMessage(assistantTwo)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fixture.model.speechController.queue.map(\.id) == ["assistant-1", "assistant-2"])
        #expect(processor.pendingCount == 1)

        // Serial rewriter: release one at a time. Releasing assistant-1
        // promotes it to active playback, then the rewriter begins
        // work on assistant-2. Releasing again completes assistant-2
        // (which then waits in the queue behind the playing first).
        processor.releaseNext()
        try await waitUntil { fixture.model.speechController.currentMessageID == "assistant-1" }
        try await waitUntil { processor.pendingCount == 1 }
        processor.releaseNext()
        try await waitUntil { fixture.model.speechController.queue.first?.readyText != nil }
    }

    @Test
    @MainActor
    func liveSpeakAutoEnqueuesArrivalsOnNonSelectedSession() async throws {
        // Cross-session Live Speak: Live Speak stays enabled for A
        // even after the user navigates to B. New assistant messages
        // on A's file auto-enqueue via the dedicated live-read
        // watcher, independent of which session the user is viewing.
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

        // Two sessions on disk, each with a user prompt seed.
        let sessionA = projectDirectory.appendingPathComponent("session-a.jsonl", isDirectory: false)
        let sessionB = projectDirectory.appendingPathComponent("session-b.jsonl", isDirectory: false)
        try """
        {"type":"user","uuid":"u-a","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-a","cwd":"/x","message":{"role":"user","content":"A's prompt."}}

        """.write(to: sessionA, atomically: true, encoding: .utf8)
        try """
        {"type":"user","uuid":"u-b","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-b","cwd":"/x","message":{"role":"user","content":"B's prompt."}}

        """.write(to: sessionB, atomically: true, encoding: .utf8)

        let defaultsSuiteName = "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        let selectedWatcher = FakeTranscriptFileWatcher()
        let liveReadWatcher = FakeTranscriptFileWatcher()
        let fakeDriver = FakeSpeechBackendDriver(
            availableVoices: [SpeechVoiceOption(id: "system.voice", name: "System", language: "en-US")]
        )
        let controller = SpeechController(systemVoiceDriver: fakeDriver)
        let model = AppModel(
            storageService: ClaudeStorageService(projectsRoot: projectsRoot),
            codexStorageService: sandboxedCodexStorageService(),
            speechController: controller,
            userDefaults: userDefaults,
            selectedTranscriptWatcher: selectedWatcher,
            liveReadTranscriptWatcher: liveReadWatcher,
            keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)")
        )
        defer {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
            try? fileManager.removeItem(at: temporaryRoot)
        }

        await model.start()
        try await waitUntil { model.sessions.count == 2 }

        // Select A, enable Live Speak, switch to B.
        let aID = try #require(model.sessions.first(where: { $0.id == "session-a" })?.id)
        let bID = try #require(model.sessions.first(where: { $0.id == "session-b" })?.id)
        model.selectedSessionID = aID
        try await waitUntil { model.transcriptState.messages(for: aID).count == 1 }
        model.setLiveReadEnabled(true)
        #expect(model.liveReadSessionID == aID)

        model.selectedSessionID = bID
        #expect(model.liveReadSessionID == aID)  // survives navigation
        try await waitUntil { model.transcriptState.messages(for: bID).count == 1 }

        // Append an assistant message to A's file. liveReadWatcher is
        // the one watching it now (selected != live).
        let newAssistantLine = "{\"type\":\"assistant\",\"uuid\":\"a-reply-1\",\"timestamp\":\"2026-04-17T17:00:02Z\",\"sessionId\":\"session-a\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"A's background reply.\"}]}}\n"
        let handle = try FileHandle(forWritingTo: sessionA)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(newAssistantLine.utf8))
        try handle.close()
        liveReadWatcher.emitChange()

        // A's new message auto-enqueued despite B being selected.
        try await waitUntil {
            fakeDriver.startedRequests.contains(where: { $0.messageID == "a-reply-1" })
        }
    }

    @Test
    @MainActor
    func enablingLiveSpeakOnNewSessionTransfersWithoutDrainingQueue() async throws {
        // The "transfer" case: A has Live Speak with auto items in
        // the queue. User navigates to B and enables Live Speak for
        // B. Ownership moves; A's queued auto items stay (just no
        // new A arrivals).
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        // Seed an auto item in the queue by pretending Live Speak
        // caught a new arrival on A.
        fixture.model.speechController.insertAuto(
            messageID: "auto-from-a",
            sourceText: "auto",
            sessionID: firstSession.id
        )
        fixture.model.setLiveReadEnabled(true)
        #expect(fixture.model.liveReadSessionID == firstSession.id)

        // Simulate viewing a different session (for test purposes we
        // just set selectedSessionID to nil — represents navigation
        // away). liveReadSessionID stays.
        fixture.model.selectedSessionID = nil
        #expect(fixture.model.liveReadSessionID == firstSession.id)

        // Re-enter the session and re-toggle — equivalent to
        // "transfer to same session" which should be a no-op.
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }
        fixture.model.setLiveReadEnabled(true)
        // The auto item we seeded is still in the queue (not drained).
        #expect(fixture.model.speechController.queue.contains(where: { $0.id == "auto-from-a" })
                || fixture.model.speechController.currentMessageID == "auto-from-a")

        // Release any pending rewriter work to tidy up.
        processor.releaseAll()
    }

    @Test
    @MainActor
    func explicitLiveSpeakOffDrainsOnlyThatSessionsAutoItems() async throws {
        // Explicit off: user toggles Live Speak off while viewing
        // the session that has it. Drain THAT session's auto items
        // from the queue. Manual items (from any session) stay.
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        fixture.model.setLiveReadEnabled(true)

        // Seed both a manual and an auto item in the queue.
        fixture.model.speechController.insertManual(
            messageID: "manual-1",
            sourceText: "m",
            sessionID: firstSession.id
        )
        fixture.model.speechController.insertAuto(
            messageID: "auto-1",
            sourceText: "a",
            sessionID: firstSession.id
        )
        try await waitUntil {
            // Queue should contain at least the manual item; the auto
            // may still be rewriting or in queue depending on timing.
            fixture.model.speechController.queue.contains(where: { $0.id == "manual-1" })
                || fixture.model.speechController.currentMessageID == "manual-1"
        }

        fixture.model.setLiveReadEnabled(false)

        // auto-1 drained; manual-1 preserved (may be in queue or
        // active depending on rewrite progress).
        #expect(!fixture.model.speechController.queue.contains(where: { $0.id == "auto-1" }))
        #expect(fixture.model.speechController.currentMessageID != "auto-1")
        let manualStillPresent = fixture.model.speechController.queue.contains(where: { $0.id == "manual-1" })
            || fixture.model.speechController.currentMessageID == "manual-1"
        #expect(manualStillPresent)

        processor.releaseAll()
    }

    @Test
    @MainActor
    func clickingSpeakOnSameMessageTwiceDoesNotDoubleRewrite() async throws {
        // Dedupe: a second click on a message that's already in the
        // queue is a no-op.
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let assistantOne = try #require(
            fixture.model.transcriptState.messages(for: firstSession.id)
                .first(where: { $0.id == "assistant-1" })
        )

        fixture.model.playMessage(assistantOne)
        try await waitUntil { processor.pendingCount == 1 }

        fixture.model.playMessage(assistantOne)
        fixture.model.playMessage(assistantOne)
        try await Task.sleep(for: .milliseconds(20))
        // Still exactly one rewrite in flight; still one item in queue.
        #expect(processor.pendingCount == 1)
        #expect(fixture.model.speechController.queue.map(\.id) == ["assistant-1"])

        processor.releaseAll()
        try await waitUntil { fixture.model.speechController.queue.isEmpty }
    }

    @Test
    @MainActor
    func liveSpeakArrivalsEnterTheQueueInRewritingState() async throws {
        // Live Speak arrivals flow through the speech queue's rewriter
        // pipeline (insertAuto). This test pins that when a new
        // assistant message lands via the file watcher, the item shows
        // up in the queue as `.rewriting` while the processor call is
        // in flight — giving the UI a "Rewriting…" signal during the
        // 5–10s CLI wait instead of feeling like the click was dropped.
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-1.jsonl", isDirectory: false)
        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

        let initialContent = """
        {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-1","cwd":"/Users/malo/Code/demo-project","message":{"role":"user","content":"Start question."}}

        """
        try initialContent.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let defaultsSuiteName = "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        let watcher = FakeTranscriptFileWatcher()
        let fakeDriver = FakeSpeechBackendDriver(
            availableVoices: [SpeechVoiceOption(id: "system.voice", name: "System", language: "en-US")]
        )
        let controller = SpeechController(systemVoiceDriver: fakeDriver)
        let processor = ControllableSpeechTextProcessor()
        let model = AppModel(
            storageService: ClaudeStorageService(projectsRoot: projectsRoot),
            codexStorageService: sandboxedCodexStorageService(),
            speechController: controller,
            userDefaults: userDefaults,
            selectedTranscriptWatcher: watcher,
            keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"),
            speechTextProcessor: processor
        )
        defer {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
            try? fileManager.removeItem(at: temporaryRoot)
        }

        await model.start()
        let firstSession = try #require(model.sessions.first)
        model.selectedSessionID = firstSession.id
        try await waitUntil { model.transcriptState.messages(for: firstSession.id).count == 1 }

        model.setLiveReadEnabled(true)

        // Append the first assistant reply — live-read should pick it up
        // and call the processor.
        let assistantLine = "{\"type\":\"assistant\",\"uuid\":\"assistant-1\",\"timestamp\":\"2026-04-17T17:00:01Z\",\"sessionId\":\"session-1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"First reply.\"}]}}\n"
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(assistantLine.utf8))
        try handle.close()
        watcher.emitChange()

        // Processor is suspended — we should see the row marked as
        // preparing for the duration of the rewrite.
        try await waitUntil { processor.pendingCount == 1 }
        #expect(model.speechController.status(for: "assistant-1") == .rewriting)
        #expect(model.isPreparingPlayback)

        // Resolve the rewrite; the item promotes out of the queue into
        // active playback, so it leaves the "rewriting" set.
        processor.releaseAll()
        try await waitUntil { model.speechController.status(for: "assistant-1") != .rewriting }
        try await waitUntil { fakeDriver.startedRequests.contains(where: { $0.messageID == "assistant-1" }) }
    }

    @Test
    @MainActor
    func speakFromHereQueuesSequenceAndRewritesHeadFirst() async throws {
        // playMessagesFromHere inserts the whole sequence into the
        // queue as a contiguous manual block. The queue's serial
        // rewriter works on head first, so the UI sees the first
        // message as `.rewriting` while subsequent items sit in
        // `.pending`; when head promotes to active, the rewriter
        // moves to the next item.
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let assistantOne = try #require(messages.first(where: { $0.id == "assistant-1" }))

        fixture.model.playMessagesFromHere(assistantOne)
        try await waitUntil { processor.pendingCount == 1 }

        // Both messages land in the queue up front; the rewriter
        // serially works on assistant-1 first. From the UI's
        // perspective both show "Rewriting…" — assistant-2 because
        // it's still .pending (not yet started but committed to play).
        #expect(fixture.model.speechController.queue.map(\.id) == ["assistant-1", "assistant-2"])

        // Release assistant-1: it promotes out (becomes active), and
        // the rewriter moves on to assistant-2.
        processor.releaseNext()
        try await waitUntil { fixture.model.speechController.currentMessageID == "assistant-1" }
        try await waitUntil { processor.pendingCount == 1 }

        processor.releaseAll()
        try await waitUntil { fixture.model.speechController.queue.first?.readyText != nil }
    }

    @Test
    @MainActor
    func sessionSwitchDuringPreprocessingDoesNotCancelPendingPlayback() async throws {
        // Session switch is cross-session-safe now — an in-flight
        // rewrite continues even if the user navigates away, and
        // when it completes the item plays normally.
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let firstAssistant = try #require(messages.first(where: { $0.id == "assistant-1" }))

        fixture.model.playMessage(firstAssistant)
        try await waitUntil { processor.invocationCount == 1 }

        // User switches away mid-process. Queue should persist.
        fixture.model.selectedSessionID = nil

        processor.releaseAll()
        // Item should land in the driver's started requests once the
        // rewrite completes — queue didn't get cancelled.
        try await waitUntil {
            fixture.fakeDriver.startedRequests.contains(where: { $0.messageID == "assistant-1" })
        }
    }

    // MARK: - Backend switch preserves ElevenLabs voice preference

    @Test
    @MainActor
    func switchingBackendDoesNotClobberPreferredElevenLabsVoiceID() async throws {
        let fixture = try makeTestAppModel()
        defer { fixture.cleanup() }

        fixture.model.preferredElevenLabsVoiceID = "11l.voice"

        fixture.model.preferredSpeechBackend = .systemVoice
        #expect(fixture.model.preferredElevenLabsVoiceID == "11l.voice")

        fixture.model.preferredSpeechBackend = .elevenLabs
        #expect(fixture.model.preferredElevenLabsVoiceID == "11l.voice")

        fixture.model.preferredSpeechBackend = .systemVoice
        #expect(fixture.model.preferredElevenLabsVoiceID == "11l.voice")
    }

    // MARK: - currentVoiceIdentifier backend routing

    @Test
    @MainActor
    func currentVoiceIdentifierRoutesThroughActiveBackendDriver() async throws {
        let fixture = try makeTestAppModel()
        defer { fixture.cleanup() }

        fixture.model.preferredElevenLabsVoiceID = "explicit.eleven"

        fixture.model.preferredSpeechBackend = .systemVoice
        // SystemVoice ignores app-level voice IDs entirely.
        #expect(fixture.model.currentVoiceIdentifier == nil)

        fixture.model.preferredSpeechBackend = .elevenLabs
        // ElevenLabs driver has no voices loaded in tests;
        // resolveVoiceIdentifier falls back to availableVoices.first
        // which is nil. That's the contract: a first-time user
        // without voices loaded gets nil (and would throw
        // noVoiceSelected at the driver).
        #expect(fixture.model.currentVoiceIdentifier == nil)
    }

    // MARK: - Fixtures

    private var initialTranscript: String {
        """
        {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-1","cwd":"/Users/malo/Code/demo-project","message":{"role":"user","content":"Please review this branch."}}
        {"type":"assistant","uuid":"assistant-1","timestamp":"2026-04-17T17:00:01Z","sessionId":"session-1","message":{"role":"assistant","content":[{"type":"text","text":"Happy to."}]}}

        """
    }
}
