import Foundation
import Testing
@testable import AgentsAloud

struct ClaudeStorageServiceTests {
    @Test
    func loadTranscriptIncorporatesAppendedJSONLLines() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AgentsAloud-StorageTests-\(UUID().uuidString)", isDirectory: true)
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

        let initialMessages = try await service.loadTranscript(for: session, filterToFinalOnly: false)
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

        let updatedMessages = try await service.loadTranscript(for: session, filterToFinalOnly: false)
        #expect(updatedMessages.map(\.id) == ["user-1", "assistant-1", "user-2"])
        #expect(updatedMessages.last?.text == "Follow-up prompt.")
    }

    @Test
    func loadTranscriptParsesLineStraddlingTwoRefreshesExactlyOnce() async throws {
        // Claude writes long JSONL lines in several syscalls, so a
        // watcher-triggered refresh can observe the file mid-line. The
        // incremental path must neither drop the straddling line (the
        // old failure: the cached resume offset landed mid-line, so
        // the fragment never decoded as JSON and the message was lost
        // until a full reparse) nor parse any line twice (duplicate
        // message IDs in the cached window).
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AgentsAloud-StorageTests-\(UUID().uuidString)", isDirectory: true)
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

        let initialMessages = try await service.loadTranscript(for: session, filterToFinalOnly: false)
        #expect(initialMessages.map(\.id) == ["user-1", "assistant-1"])

        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: transcriptURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }

        // First half of the next record, no trailing newline — the
        // state a refresh sees mid-append.
        let splitIndex = appendedLine.index(appendedLine.startIndex, offsetBy: 60)
        try await Task.sleep(for: .milliseconds(50))  // ensure mtime advances
        try append(String(appendedLine[..<splitIndex]))

        let midMessages = try await service.loadTranscript(for: session, filterToFinalOnly: false)
        #expect(midMessages.map(\.id) == ["user-1", "assistant-1"])

        // Complete the straddling line and add one more full record.
        try await Task.sleep(for: .milliseconds(50))
        try append(String(appendedLine[splitIndex...]) + secondAppendedLine)

        let finalMessages = try await service.loadTranscript(for: session, filterToFinalOnly: false)
        #expect(finalMessages.map(\.id) == ["user-1", "assistant-1", "user-2", "user-3"])
    }

    @Test
    func escapeEditAcrossRefreshesRemovesTheAbortedPrompt() async throws {
        // The interruption marker's effect reaches BACKWARD: the
        // prompt it cancels is usually already in the cached window
        // from an earlier refresh, where an append-only merge can't
        // remove it. The incremental path must detect the marker in
        // the appended tail and fall back to a full tail-load.
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AgentsAloud-StorageTests-\(UUID().uuidString)", isDirectory: true)
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

        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: transcriptURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }

        // The user sends a prompt — it lands in the cached window via
        // the incremental path.
        try await Task.sleep(for: .milliseconds(50))
        try append(#"{"type":"user","uuid":"user-aborted","timestamp":"2026-04-17T17:00:02Z","sessionId":"session-1","message":{"role":"user","content":"Draft with a mistake."}}"# + "\n")
        let midMessages = try await service.loadTranscript(for: session, filterToFinalOnly: false)
        #expect(midMessages.map(\.id) == ["user-1", "assistant-1", "user-aborted"])

        // Escape-edit: marker + edited resend arrive in the next
        // appended tail. The aborted prompt must disappear.
        try await Task.sleep(for: .milliseconds(50))
        try append(
            #"{"type":"user","uuid":"marker-1","timestamp":"2026-04-17T17:00:08Z","sessionId":"session-1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"# + "\n"
            + #"{"type":"user","uuid":"user-edited","timestamp":"2026-04-17T17:00:09Z","sessionId":"session-1","message":{"role":"user","content":"Draft, corrected."}}"# + "\n"
        )

        let finalMessages = try await service.loadTranscript(for: session, filterToFinalOnly: false)
        #expect(finalMessages.map(\.id) == ["user-1", "assistant-1", "user-edited"])
    }

    @Test
    func loadTranscriptFallsBackToFullParseWhenPrefixMutated() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AgentsAloud-StorageTests-\(UUID().uuidString)", isDirectory: true)
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

        _ = try await service.loadTranscript(for: session, filterToFinalOnly: false)

        // Simulate a rewind / fork / in-place edit by replacing the file with
        // strictly larger but entirely different content. The cache thinks the
        // prefix is intact (fileSize > cached.fileSize triggers the incremental
        // fast path), but the bytes at the cached offset no longer match the
        // stored tail signature, so the code must fall back to a full parse.
        try await Task.sleep(for: .milliseconds(50))
        try rewrittenTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let updatedMessages = try await service.loadTranscript(for: session, filterToFinalOnly: false)
        #expect(updatedMessages.map(\.id) == ["user-A", "assistant-A", "user-B"])
        #expect(updatedMessages.last?.text == "Follow-up on the new branch.")
    }

    @Test
    func loadSessionsFiltersBySinceAndHonorsMinimumFloor() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AgentsAloud-StorageTests-\(UUID().uuidString)", isDirectory: true)
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

    @Test
    func loadSessionsFloorIsNotInflatedByAiTitleOnlyArtifacts() async throws {
        // Regression: the old code precomputed `targetCount` as
        // `max(withinWindowRawCount, floor)` where withinWindowRawCount
        // included ai-title-only CLI rewriter artifacts. With a handful
        // of real sessions and many artifacts clustered at the top of
        // the mtime list, the loop walked much deeper into old history
        // than the 24-hour-plus-floor policy intended. The walk-until-
        // enough fix bases the stop condition on accreted valid-summary
        // count, so artifacts don't inflate anything.
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AgentsAloud-StorageTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)

        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let now = Date()
        // Ten CLI-rewriter artifacts within the last hour — newest
        // mtime, ai-title-only, no real turns.
        for index in 0..<10 {
            let url = projectDirectory.appendingPathComponent("artifact-\(index).jsonl")
            try writeAiTitleOnlyArtifact(at: url, sessionID: "artifact-\(index)",
                                         mtime: now.addingTimeInterval(-60 * Double(index)))
        }
        // Two real sessions inside the 24-hour window.
        try writeTranscript(at: projectDirectory.appendingPathComponent("real-recent-1.jsonl"),
                            mtime: now.addingTimeInterval(-2 * 60 * 60))
        try writeTranscript(at: projectDirectory.appendingPathComponent("real-recent-2.jsonl"),
                            mtime: now.addingTimeInterval(-3 * 60 * 60))
        // Five older real sessions well outside the window. If the old
        // inflation bug resurfaces, some of these would get pulled in.
        for index in 0..<5 {
            let url = projectDirectory.appendingPathComponent("old-\(index).jsonl")
            try writeTranscript(at: url, mtime: now.addingTimeInterval(-Double(10 + index) * 24 * 60 * 60))
        }

        let service = ClaudeStorageService(projectsRoot: projectsRoot)
        let twentyFourHoursAgo = now.addingTimeInterval(-24 * 60 * 60)

        // Floor 2: within-window gives us the two real recent sessions,
        // exactly hitting the floor. Should NOT backfill into old
        // history. Artifacts should be filtered out entirely.
        let result = try await service.loadSessions(since: twentyFourHoursAgo, minimumCount: 2)
        let names = Set(result.map(\.transcriptURL.lastPathComponent))
        #expect(result.count == 2)
        #expect(names == ["real-recent-1.jsonl", "real-recent-2.jsonl"])

        // Floor 5: within-window gives 2, floor requires 5 → backfill
        // three of the older ones, still no artifacts.
        let withFloor = try await service.loadSessions(since: twentyFourHoursAgo, minimumCount: 5)
        let withFloorNames = withFloor.map(\.transcriptURL.lastPathComponent)
        #expect(withFloor.count == 5)
        #expect(withFloorNames.contains("real-recent-1.jsonl"))
        #expect(withFloorNames.contains("real-recent-2.jsonl"))
        #expect(withFloorNames.allSatisfy { !$0.hasPrefix("artifact-") })
    }

    private func writeTranscript(at url: URL, mtime: Date) throws {
        try initialTranscript.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    private func writeAiTitleOnlyArtifact(at url: URL, sessionID: String, mtime: Date) throws {
        // Matches what `claude --print --no-session-persistence` drops:
        // a single-line JSONL with nothing but the post-session ai-title
        // record. No user/assistant turns, no cwd.
        let line = "{\"type\":\"ai-title\",\"sessionId\":\"\(sessionID)\",\"aiTitle\":\"Artifact\"}\n"
        try line.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    @Test
    func loadSessionsRecomputesSummaryWhenMetadataChangesWithoutTranscriptChange() async throws {
        // Regression: the summary cache was keyed on transcript mtime only,
        // so Claude updating a session title in .session_cache.json or
        // sessions-index.json without touching the JSONL left the sidebar
        // showing a stale summary until the transcript was re-touched.
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AgentsAloud-StorageTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-1.jsonl", isDirectory: false)
        let sessionsIndexURL = projectDirectory.appendingPathComponent("sessions-index.json", isDirectory: false)

        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        // Start with a transcript whose first prompt is "Initial prompt.";
        // no metadata yet so the summary falls back to the first prompt.
        try initialTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let service = ClaudeStorageService(projectsRoot: projectsRoot)
        let firstPass = try await service.loadSessions()
        let initialSummary = try #require(firstPass.first?.summary)
        #expect(initialSummary.contains("Initial prompt"))

        // Now write a sessions-index.json with an AI-generated title,
        // WITHOUT touching the transcript. Old cache logic would keep
        // returning the first-prompt fallback.
        let indexJSON = """
        {
          "entries": [
            {
              "sessionId": "session-1",
              "fullPath": "\(transcriptURL.path)",
              "summary": "AI-generated distinctive title"
            }
          ]
        }
        """
        // Small sleep to ensure metadata mtime advances past transcript mtime
        // on filesystems with 1-second mtime resolution.
        try await Task.sleep(for: .milliseconds(50))
        try indexJSON.write(to: sessionsIndexURL, atomically: true, encoding: .utf8)

        let secondPass = try await service.loadSessions()
        let refreshedSummary = try #require(secondPass.first?.summary)
        #expect(refreshedSummary == "AI-generated distinctive title")
    }

    @Test
    func loadTranscriptCapsAtDisplayLimitForLongSessions() async throws {
        // Long-session cold-load contract: only the most recent
        // TranscriptDisplayLimits.messageCapIncludingIntermediates user/assistant messages
        // should come back, and they should be the *last* messages
        // chronologically (not the first cap, not a random slice).
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AgentsAloud-StorageTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-1.jsonl", isDirectory: false)

        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let total = TranscriptDisplayLimits.messageCapIncludingIntermediates + 20  // exceed the cap by enough to be unambiguous
        try generatedTranscript(messageCount: total)
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let service = ClaudeStorageService(projectsRoot: projectsRoot)
        let sessions = try await service.loadSessions()
        let session = try #require(sessions.first)

        let messages = try await service.loadTranscript(for: session, filterToFinalOnly: false)
        #expect(messages.count == TranscriptDisplayLimits.messageCapIncludingIntermediates)
        // Last `cap` of `total` → starts at id index (total - cap).
        let firstReturnedIndex = total - TranscriptDisplayLimits.messageCapIncludingIntermediates
        #expect(messages.first?.id == "msg-\(firstReturnedIndex)")
        #expect(messages.last?.id == "msg-\(total - 1)")
    }

    @Test
    func loadTranscriptKeepsRollingWindowAcrossAppends() async throws {
        // Rolling-cap contract: when the cache is already full and new
        // messages are appended, the oldest cached messages drop out
        // of the returned list so the visible window stays bounded.
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AgentsAloud-StorageTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-1.jsonl", isDirectory: false)

        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        // Start at exactly the cap so the very next append must shift
        // the window — this is the boundary where rolling kicks in.
        let initialCount = TranscriptDisplayLimits.messageCapIncludingIntermediates
        try generatedTranscript(messageCount: initialCount)
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let service = ClaudeStorageService(projectsRoot: projectsRoot)
        let sessions = try await service.loadSessions()
        let session = try #require(sessions.first)

        let initial = try await service.loadTranscript(for: session, filterToFinalOnly: false)
        #expect(initial.count == TranscriptDisplayLimits.messageCapIncludingIntermediates)
        #expect(initial.first?.id == "msg-0")
        #expect(initial.last?.id == "msg-\(initialCount - 1)")

        // Append 5 more messages — should exercise the incremental
        // tail-parse path, not a cold reload.
        try await Task.sleep(for: .milliseconds(50))  // ensure mtime advances
        let extra = 5
        let appendBlock = (initialCount..<(initialCount + extra))
            .map { generatedLine(index: $0) }
            .joined()
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendBlock.utf8))
        try handle.close()

        let updated = try await service.loadTranscript(for: session, filterToFinalOnly: false)
        #expect(updated.count == TranscriptDisplayLimits.messageCapIncludingIntermediates)
        // Window slid forward by `extra`: oldest five are dropped.
        #expect(updated.first?.id == "msg-\(extra)")
        #expect(updated.last?.id == "msg-\(initialCount + extra - 1)")
    }

    @Test
    func loadTranscriptFinalOnlyDropsIntermediateAssistantMessages() async throws {
        // Filter contract: with filterToFinalOnly: true, assistant
        // messages whose stop_reason is "tool_use" are dropped from
        // the returned list. Final assistants (any other stop_reason
        // or none) pass through. The cap is the smaller messageCapFinalOnly,
        // so on a fixture exceeding it, only the most recent finals
        // come back.
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AgentsAloud-StorageTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-1.jsonl", isDirectory: false)

        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        // 15 intermediate assistants (stop_reason "tool_use"), then
        // 12 final assistants (stop_reason "end_turn"). All assistant
        // role for simplicity; the filter keys on isIntermediate, not
        // role.
        var lines: [String] = []
        for i in 0..<15 {
            lines.append(assistantLine(index: i, stopReason: "tool_use"))
        }
        for i in 15..<27 {
            lines.append(assistantLine(index: i, stopReason: "end_turn"))
        }
        try lines.joined().write(to: transcriptURL, atomically: true, encoding: .utf8)

        let service = ClaudeStorageService(projectsRoot: projectsRoot)
        let sessions = try await service.loadSessions()
        let session = try #require(sessions.first)

        let messages = try await service.loadTranscript(for: session, filterToFinalOnly: true)
        #expect(messages.count == TranscriptDisplayLimits.messageCapFinalOnly)
        // 12 finals (indices 15..26), last 10 → indices 17..26.
        #expect(messages.first?.id == "msg-17")
        #expect(messages.last?.id == "msg-26")
        // Sanity: all returned are non-intermediate.
        #expect(messages.allSatisfy { !$0.isIntermediate })
    }

    // Generate a synthetic transcript with `messageCount` user/assistant
    // messages alternating, all timestamped sequentially so the parser's
    // chronological sort is well-defined. IDs are msg-0, msg-1, … so
    // tests can assert which slice came back.
    private func generatedTranscript(messageCount: Int) -> String {
        (0..<messageCount).map { generatedLine(index: $0) }.joined()
    }

    private func generatedLine(index: Int) -> String {
        let role = index.isMultiple(of: 2) ? "user" : "assistant"
        // Pad timestamp seconds so even 1000 messages sort lexically.
        let seconds = String(format: "%05d", index)
        let timestamp = "2026-04-17T17:00:00.\(seconds)Z"
        let id = "msg-\(index)"
        if role == "user" {
            return #"""
            {"type":"user","uuid":"\#(id)","timestamp":"\#(timestamp)","sessionId":"session-1","cwd":"/tmp/demo-project","message":{"role":"user","content":"User message \#(index)."}}
            """# + "\n"
        } else {
            return #"""
            {"type":"assistant","uuid":"\#(id)","timestamp":"\#(timestamp)","sessionId":"session-1","message":{"role":"assistant","content":[{"type":"text","text":"Assistant reply \#(index)."}]}}
            """# + "\n"
        }
    }

    // Assistant-only line generator with explicit stop_reason. Used by
    // the final-only filter test to construct a fixture with a known
    // mix of intermediate and final messages.
    private func assistantLine(index: Int, stopReason: String) -> String {
        let seconds = String(format: "%05d", index)
        let timestamp = "2026-04-17T17:00:00.\(seconds)Z"
        let id = "msg-\(index)"
        return #"""
        {"type":"assistant","uuid":"\#(id)","timestamp":"\#(timestamp)","sessionId":"session-1","cwd":"/tmp/demo-project","message":{"role":"assistant","stop_reason":"\#(stopReason)","content":[{"type":"text","text":"Assistant reply \#(index)."}]}}
        """# + "\n"
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

    private var secondAppendedLine: String {
        #"{"type":"user","uuid":"user-3","timestamp":"2026-04-17T17:00:03Z","sessionId":"session-1","message":{"role":"user","content":"Another follow-up."}}"# + "\n"
    }
}
