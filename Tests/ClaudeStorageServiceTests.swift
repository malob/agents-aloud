import Foundation
import Testing
@testable import ClaudeCodeVoice

struct ClaudeStorageServiceTests {
    @Test
    func loadTranscriptIncorporatesAppendedJSONLLines() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-StorageTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-1.jsonl", isDirectory: false)

        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try initialTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        defer {
            try? fileManager.removeItem(at: temporaryRoot)
        }

        let service = ClaudeStorageService(projectsRoot: projectsRoot)
        let sessions = try await service.loadSessions()
        let session = try #require(sessions.first)

        let initialMessages = try await service.loadTranscript(for: session)
        #expect(initialMessages.map(\.id) == ["user-1", "assistant-1"])

        // Appending a new line exercises the incremental tail-parse path: the
        // cached file length is preserved, we seek past it, parse the new
        // suffix, and merge. If this test ever fails after the `.jsonl`
        // content is appended to, the incremental path in
        // ClaudeStorageService.loadTranscript has regressed.
        try await Task.sleep(for: .milliseconds(50))  // ensure mtime advances
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendedLine.utf8))
        try handle.close()

        let updatedMessages = try await service.loadTranscript(for: session)
        #expect(updatedMessages.map(\.id) == ["user-1", "assistant-1", "user-2"])
        #expect(updatedMessages.last?.text == "Follow-up prompt.")
    }

    @Test
    func loadTranscriptFallsBackToFullParseWhenPrefixMutated() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-StorageTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-1.jsonl", isDirectory: false)

        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try initialTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        defer {
            try? fileManager.removeItem(at: temporaryRoot)
        }

        let service = ClaudeStorageService(projectsRoot: projectsRoot)
        let sessions = try await service.loadSessions()
        let session = try #require(sessions.first)

        _ = try await service.loadTranscript(for: session)

        // Simulate a rewind / fork / in-place edit by replacing the file with
        // strictly larger but entirely different content. The cache thinks the
        // prefix is intact (fileSize > cached.fileSize triggers the incremental
        // fast path), but the bytes at the cached offset no longer match the
        // stored tail signature, so the code must fall back to a full parse.
        try await Task.sleep(for: .milliseconds(50))
        try rewrittenTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let updatedMessages = try await service.loadTranscript(for: session)
        #expect(updatedMessages.map(\.id) == ["user-A", "assistant-A", "user-B"])
        #expect(updatedMessages.last?.text == "Follow-up on the new branch.")
    }

    @Test
    func loadSessionsFiltersBySinceAndHonorsMinimumFloor() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-StorageTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)

        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        // Write three transcripts at three different mtimes.
        let now = Date()
        let ancient = now.addingTimeInterval(-10 * 24 * 60 * 60)  // 10 days ago
        let old = now.addingTimeInterval(-2 * 24 * 60 * 60)       // 2 days ago
        let fresh = now.addingTimeInterval(-60 * 60)              // 1 hour ago

        try writeTranscript(at: projectDirectory.appendingPathComponent("ancient.jsonl"), mtime: ancient)
        try writeTranscript(at: projectDirectory.appendingPathComponent("old.jsonl"), mtime: old)
        try writeTranscript(at: projectDirectory.appendingPathComponent("fresh.jsonl"), mtime: fresh)

        let service = ClaudeStorageService(projectsRoot: projectsRoot)

        // 24h window with no minimum floor → only the fresh one.
        let twentyFourHoursAgo = now.addingTimeInterval(-24 * 60 * 60)
        let recentOnly = try await service.loadSessions(since: twentyFourHoursAgo, minimumCount: 0)
        #expect(recentOnly.count == 1)
        #expect(recentOnly.first?.transcriptURL.lastPathComponent == "fresh.jsonl")

        // Same window, minimum floor of 2 → falls back to the two most recent
        // (fresh + old), even though `old` is outside the window.
        let withFloor = try await service.loadSessions(since: twentyFourHoursAgo, minimumCount: 2)
        #expect(withFloor.count == 2)
        let names = withFloor.map(\.transcriptURL.lastPathComponent)
        #expect(names.contains("fresh.jsonl"))
        #expect(names.contains("old.jsonl"))
        #expect(!names.contains("ancient.jsonl"))
    }

    private func writeTranscript(at url: URL, mtime: Date) throws {
        try initialTranscript.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    private var rewrittenTranscript: String {
        """
        {"type":"user","uuid":"user-A","timestamp":"2026-04-17T18:00:00Z","sessionId":"session-1","cwd":"/tmp/demo-project","message":{"role":"user","content":"A different first prompt after the rewind."}}
        {"type":"assistant","uuid":"assistant-A","timestamp":"2026-04-17T18:00:01Z","sessionId":"session-1","message":{"role":"assistant","content":[{"type":"text","text":"A different reply that takes the conversation a new direction."}]}}
        {"type":"user","uuid":"user-B","timestamp":"2026-04-17T18:00:02Z","sessionId":"session-1","message":{"role":"user","content":"Follow-up on the new branch."}}

        """
    }

    private var initialTranscript: String {
        """
        {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-1","cwd":"/tmp/demo-project","message":{"role":"user","content":"Initial prompt."}}
        {"type":"assistant","uuid":"assistant-1","timestamp":"2026-04-17T17:00:01Z","sessionId":"session-1","message":{"role":"assistant","content":[{"type":"text","text":"Reply."}]}}

        """
    }

    private var appendedLine: String {
        #"{"type":"user","uuid":"user-2","timestamp":"2026-04-17T17:00:02Z","sessionId":"session-1","message":{"role":"user","content":"Follow-up prompt."}}"# + "\n"
    }
}
