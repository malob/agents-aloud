import Foundation
import Testing
@testable import ClaudeCodeVoice

struct ClaudeTranscriptParserTests {
    @Test
    func parseTranscriptReturnsSortedSpeakableMessagesOnly() {
        let rawTranscript = """
        {"type":"assistant","uuid":"assistant-1","timestamp":"2026-04-17T17:00:02Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"First paragraph."},{"type":"tool_use","name":"Read"},{"type":"text","text":"Second paragraph."}]}}
        {"type":"user","uuid":"meta-user","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-123","isMeta":true,"message":{"role":"user","content":"Hook output"}}
        {"type":"assistant","uuid":"assistant-2","timestamp":"2026-04-17T17:00:03Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}
        {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:01Z","sessionId":"session-123","message":{"role":"user","content":"Tell me what happened."}}
        """

        let messages = ClaudeTranscriptParser.parseTranscript(rawTranscript)

        #expect(messages.map(\.id) == ["user-1", "assistant-1"])
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages.map(\.text) == [
            "Tell me what happened.",
            "First paragraph.\n\nSecond paragraph.",
        ])
        #expect(messages.allSatisfy { $0.sessionID == "session-123" })
    }

    @Test
    func parseTranscriptAcceptsFractionalAndStandardISO8601Timestamps() {
        let rawTranscript = """
        {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00.250Z","sessionId":"session-123","message":{"role":"user","content":"Fractional time"}}
        {"type":"assistant","uuid":"assistant-1","timestamp":"2026-04-17T17:00:01Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"Standard time"}]}}
        """

        let messages = ClaudeTranscriptParser.parseTranscript(rawTranscript)

        #expect(messages.count == 2)
        #expect(messages[0].text == "Fractional time")
        #expect(messages[1].text == "Standard time")
    }

    @Test
    func summarizeTranscriptPrefersCustomTitleOverAIAndMetadata() {
        let fileURL = URL(fileURLWithPath: "/tmp/project/session-123.jsonl")
        let modifiedAt = Date(timeIntervalSince1970: 1_713_374_400)
        var metadataIndex = ProjectMetadataIndex()
        metadataIndex.merge(
            SessionMetadata(summary: "Metadata Title", source: .sessionCache),
            forFilePath: fileURL.path,
            sessionID: "session-123"
        )
        let rawTranscript = """
        {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-123","cwd":"/Users/malo/Code/project","message":{"role":"user","content":"Please review this branch."}}
        {"type":"ai-title","sessionId":"session-123","aiTitle":"AI Title"}
        {"type":"custom-title","sessionId":"session-123","customTitle":"Custom Title"}
        """

        let summary = ClaudeTranscriptParser.summarizeTranscript(
            rawTranscript,
            fileURL: fileURL,
            modifiedAt: modifiedAt,
            projectMetadataIndex: metadataIndex
        )

        #expect(summary != nil)
        #expect(summary?.id == "session-123")
        #expect(summary?.summary == "Custom Title")
        #expect(summary?.firstPrompt == "Please review this branch.")
        #expect(summary?.projectPath == "/Users/malo/Code/project")
        #expect(summary?.messageCount == 1)
    }

    @Test
    func summarizeTranscriptFallsBackToMetadataSummaryBeforePrompt() {
        let fileURL = URL(fileURLWithPath: "/tmp/project/session-123.jsonl")
        let modifiedAt = Date(timeIntervalSince1970: 1_713_374_400)
        var metadataIndex = ProjectMetadataIndex()
        metadataIndex.merge(
            SessionMetadata(summary: "Metadata Title", source: .sessionsIndex),
            forFilePath: fileURL.path,
            sessionID: "session-123"
        )
        let rawTranscript = """
        {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-123","message":{"role":"user","content":"Prompt title should lose to metadata."}}
        """

        let summary = ClaudeTranscriptParser.summarizeTranscript(
            rawTranscript,
            fileURL: fileURL,
            modifiedAt: modifiedAt,
            projectMetadataIndex: metadataIndex
        )

        #expect(summary?.summary == "Metadata Title")
        #expect(summary?.firstPrompt == "Prompt title should lose to metadata.")
    }

    @Test
    func summarizeTranscriptSkipsMetaPromptAndFallsBackToVisiblePrompt() {
        let summary = ClaudeTranscriptParser.summarizeTranscript(
            """
            {"type":"user","uuid":"meta-user","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-123","isMeta":true,"message":{"role":"user","content":"Hook output"}}
            {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:01Z","sessionId":"session-123","message":{"role":"user","content":"Real first prompt"}}
            """,
            fileURL: URL(fileURLWithPath: "/tmp/project/session-123.jsonl"),
            modifiedAt: Date(timeIntervalSince1970: 1_713_374_400),
            projectMetadataIndex: ProjectMetadataIndex()
        )

        #expect(summary?.firstPrompt == "Real first prompt")
        #expect(summary?.summary == "Real first prompt")
        #expect(summary?.messageCount == 1)
    }

    @Test
    func summarizeTranscriptUsesFilenameProjectWhenCwdIsMissingAndTruncatesPromptFallback() {
        let longPrompt = String(repeating: "A", count: 120)
        let summary = ClaudeTranscriptParser.summarizeTranscript(
            """
            {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-123","message":{"role":"user","content":"\(longPrompt)"}}
            """,
            fileURL: URL(fileURLWithPath: "/tmp/my-project/session-123.jsonl"),
            modifiedAt: Date(timeIntervalSince1970: 1_713_374_400),
            projectMetadataIndex: ProjectMetadataIndex()
        )

        #expect(summary?.projectPath == "my-project")
        #expect(summary?.summary.count == 88)
        #expect(summary?.summary.hasSuffix("…") == true)
    }
}
