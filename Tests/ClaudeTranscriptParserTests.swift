import Foundation
import Testing
@testable import AgentsAloud

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
        #expect(messages.map(\.content) == [
            .plainText("Tell me what happened."),
            .plainText("First paragraph.\n\nSecond paragraph."),
        ])
        #expect(messages.allSatisfy { $0.sessionID == "session-123" })
    }

    @Test
    func parseTranscriptRendersImageBearingUserMessagesFromArrayContent() {
        // A user prompt with attached images is stored as an array of
        // content blocks (text + image) rather than a bare string. The
        // text must still render. Sibling records must not surface as
        // user bubbles: the isMeta "[Image: source: …]" annotation and
        // a tool_result envelope (also array content, but no text block).
        let rawTranscript = """
        {"type":"user","uuid":"user-img","timestamp":"2026-04-17T17:00:00Z","sessionId":"s","message":{"role":"user","content":[{"type":"text","text":"Here's a screenshot, any idea?"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}}
        {"type":"user","uuid":"meta-img","timestamp":"2026-04-17T17:00:01Z","sessionId":"s","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"[Image: source: /tmp/shot.png]"}]}}
        {"type":"user","uuid":"tool-res","timestamp":"2026-04-17T17:00:02Z","sessionId":"s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"output"}]}}
        {"type":"assistant","uuid":"a-1","timestamp":"2026-04-17T17:00:03Z","sessionId":"s","message":{"role":"assistant","content":[{"type":"text","text":"Looking now."}]}}
        """

        let messages = ClaudeTranscriptParser.parseTranscript(rawTranscript)

        #expect(messages.map(\.id) == ["user-img", "a-1"])
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages.first?.text == "Here's a screenshot, any idea?")
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
        #expect(messages.allSatisfy {
            if case .plainText = $0.content {
                return true
            }

            return false
        })
    }

    @Test
    func parseTranscriptPrecomputesLiteralAndMarkdownRenderingModes() {
        let rawTranscript = """
        {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-123","message":{"role":"user","content":"<task-notification>Task output</task-notification>"}}
        {"type":"assistant","uuid":"assistant-1","timestamp":"2026-04-17T17:00:01Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"# Heading\\n\\n- one\\n- two"}]}}
        """

        let messages = ClaudeTranscriptParser.parseTranscript(rawTranscript)

        #expect(messages.map(\.content) == [
            .literal("<task-notification>Task output</task-notification>"),
            .markdown("# Heading\n\n- one\n- two"),
        ])
    }

    @Test
    func parseTranscriptRecognizesLiteralPrefixesAndMarkdownEdges() {
        let rawTranscript = """
        {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-123","message":{"role":"user","content":"<command-message>test</command-message>"}}
        {"type":"user","uuid":"user-2","timestamp":"2026-04-17T17:00:01Z","sessionId":"session-123","message":{"role":"user","content":"<local-command-caveat>Heads up</local-command-caveat>"}}
        {"type":"user","uuid":"user-3","timestamp":"2026-04-17T17:00:01.500Z","sessionId":"session-123","message":{"role":"user","content":"<command-name>ship-it</command-name>"}}
        {"type":"user","uuid":"user-4","timestamp":"2026-04-17T17:00:01.750Z","sessionId":"session-123","message":{"role":"user","content":"<command-args>--help</command-args>"}}
        {"type":"assistant","uuid":"assistant-1","timestamp":"2026-04-17T17:00:02Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"1. item"}]}}
        {"type":"assistant","uuid":"assistant-2","timestamp":"2026-04-17T17:00:03Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"1.item"}]}}
        {"type":"assistant","uuid":"assistant-3","timestamp":"2026-04-17T17:00:04Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"`inline code`"}]}}
        {"type":"assistant","uuid":"assistant-4","timestamp":"2026-04-17T17:00:05Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"[link](https://example.com)"}]}}
        {"type":"assistant","uuid":"assistant-5","timestamp":"2026-04-17T17:00:06Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"![alt](https://example.com/image.png)"}]}}
        {"type":"assistant","uuid":"assistant-6","timestamp":"2026-04-17T17:00:07Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"**bold** __underline__ ~~strike~~"}]}}
        {"type":"assistant","uuid":"assistant-7","timestamp":"2026-04-17T17:00:08Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"> quote"}]}}
        {"type":"assistant","uuid":"assistant-8","timestamp":"2026-04-17T17:00:09Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"| head |\\n| --- |\\n| cell |"}]}}
        {"type":"assistant","uuid":"assistant-9","timestamp":"2026-04-17T17:00:10Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"---"}]}}
        {"type":"assistant","uuid":"assistant-10","timestamp":"2026-04-17T17:00:11Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"10. item"}]}}
        {"type":"assistant","uuid":"assistant-11","timestamp":"2026-04-17T17:00:12Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"1.2.3"}]}}
        {"type":"assistant","uuid":"assistant-12","timestamp":"2026-04-17T17:00:13Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"Normal prose paragraph."}]}}
        """

        let messages = ClaudeTranscriptParser.parseTranscript(rawTranscript)

        #expect(messages.map(\.content) == [
            .literal("<command-message>test</command-message>"),
            .literal("<local-command-caveat>Heads up</local-command-caveat>"),
            .literal("<command-name>ship-it</command-name>"),
            .literal("<command-args>--help</command-args>"),
            .markdown("1. item"),
            .plainText("1.item"),
            .markdown("`inline code`"),
            .markdown("[link](https://example.com)"),
            .markdown("![alt](https://example.com/image.png)"),
            .markdown("**bold** __underline__ ~~strike~~"),
            .markdown("> quote"),
            .markdown("| head |\n| --- |\n| cell |"),
            .markdown("---"),
            .markdown("10. item"),
            .plainText("1.2.3"),
            .plainText("Normal prose paragraph."),
        ])
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

    // Our Claude-CLI speech rewriter runs `claude --print --no-session-
    // persistence`, which still writes a tiny one-line JSONL containing just
    // an `ai-title` record (no user/assistant turns). Those would flood the
    // sidebar with 0-message titled sessions; the summarizer drops them.
    @Test
    func summarizeTranscriptDropsAiTitleOnlyArtifacts() {
        let rawTranscript = """
        {"type":"ai-title","sessionId":"session-123","aiTitle":"Compare ML model performance benchmarks"}
        """

        let summary = ClaudeTranscriptParser.summarizeTranscript(
            rawTranscript,
            fileURL: URL(fileURLWithPath: "/tmp/project/session-123.jsonl"),
            modifiedAt: Date(timeIntervalSince1970: 1_713_374_400),
            projectMetadataIndex: ProjectMetadataIndex()
        )

        #expect(summary == nil)
    }

    // A real session that happens to have only one assistant turn (e.g.
    // --print output piped back) should still be summarized — the filter
    // keys on "no turns AND no user prompt," not on turn count alone.
    @Test
    func summarizeTranscriptKeepsSessionsWithOnlyAssistantTurns() {
        let rawTranscript = """
        {"type":"assistant","uuid":"assistant-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-123","message":{"role":"assistant","content":[{"type":"text","text":"Rewritten output."}]}}
        """

        let summary = ClaudeTranscriptParser.summarizeTranscript(
            rawTranscript,
            fileURL: URL(fileURLWithPath: "/tmp/project/session-123.jsonl"),
            modifiedAt: Date(timeIntervalSince1970: 1_713_374_400),
            projectMetadataIndex: ProjectMetadataIndex()
        )

        #expect(summary != nil)
    }

    @Test
    func escapeEditDropsTheAbortedPromptAndTheMarker() {
        // Escape-to-edit-and-resend is recorded linearly: the aborted
        // prompt stays in the JSONL, followed by a
        // "[Request interrupted by user]" entry, followed by the
        // edited resend. Only the resend should display.
        let rawTranscript = """
        {"type":"user","uuid":"user-original","timestamp":"2026-06-11T20:08:52Z","sessionId":"s","message":{"role":"user","content":"First draft with a typo."}}
        {"type":"user","uuid":"marker-1","timestamp":"2026-06-11T20:08:58Z","sessionId":"s","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}
        {"type":"user","uuid":"user-edited","timestamp":"2026-06-11T20:08:59Z","sessionId":"s","message":{"role":"user","content":"First draft, fixed."}}
        {"type":"assistant","uuid":"assistant-1","timestamp":"2026-06-11T20:09:05Z","sessionId":"s","message":{"role":"assistant","content":[{"type":"text","text":"Reply to the fixed draft."}]}}
        """

        let messages = ClaudeTranscriptParser.parseTranscript(rawTranscript)

        #expect(messages.map(\.id) == ["user-edited", "assistant-1"])
    }

    @Test
    func midResponseInterruptionKeepsTheRealTurn() {
        // Escaping while the model is RESPONDING also writes the
        // marker, but the aborted prompt produced real assistant
        // output — that turn happened and must stay. Only the marker
        // itself is hidden.
        let rawTranscript = """
        {"type":"user","uuid":"user-1","timestamp":"2026-06-11T20:00:00Z","sessionId":"s","message":{"role":"user","content":"Long question."}}
        {"type":"assistant","uuid":"assistant-partial","timestamp":"2026-06-11T20:00:05Z","sessionId":"s","message":{"role":"assistant","content":[{"type":"text","text":"Partial answer before the escape."}]}}
        {"type":"user","uuid":"marker-1","timestamp":"2026-06-11T20:00:08Z","sessionId":"s","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}
        {"type":"user","uuid":"user-2","timestamp":"2026-06-11T20:00:15Z","sessionId":"s","message":{"role":"user","content":"New direction."}}
        """

        let messages = ClaudeTranscriptParser.parseTranscript(rawTranscript)

        #expect(messages.map(\.id) == ["user-1", "assistant-partial", "user-2"])
    }
}
