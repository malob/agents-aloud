import Foundation
import OSLog

enum ClaudeTranscriptParser {
    private static let logger = Logger(subsystem: "me.malob.agentsaloud", category: "TranscriptParser")

    // NB: JSONDecoder is documented as NOT thread-safe. Each call creates its
    // own instance so this parser is safe to call concurrently. Allocation
    // is microseconds; the parse itself dominates runtime.

    static func parseTranscript(_ rawTranscript: String) -> [TranscriptMessage] {
        PerfLog.time("Parser.parseTranscript") {
            let decoder = JSONDecoder()
            let dateParsers = ISO8601DateParsers()
            var messages: [TranscriptMessage] = []
            var droppedLineCount = 0

            for lineSlice in rawTranscript.split(whereSeparator: \.isNewline) {
                guard let data = String(lineSlice).data(using: .utf8),
                      let entry = try? decoder.decode(TranscriptLine.self, from: data) else {
                    droppedLineCount += 1
                    continue
                }

                // Escape-to-edit-and-resend is recorded LINEARLY in the
                // JSONL (verified against a live session, 2026-06): the
                // aborted prompt stays in the file, followed by a
                // "[Request interrupted by user]" user entry, followed
                // by the edited resend. The marker is what the real CLI
                // keys on to hide the original. If the message directly
                // before the marker is a user prompt, it's the aborted
                // one — drop it. If an assistant reply landed in
                // between, the user interrupted mid-RESPONSE: that was
                // a real turn and everything stays. (The marker itself
                // is never displayed; the same rule also covers the
                // "...for tool use" marker variant, where the
                // in-between assistant message keeps the turn intact.)
                if Self.isInterruptionMarker(entry) {
                    if messages.last?.role == .user {
                        messages.removeLast()
                    }
                    continue
                }

                guard let message = makeTranscriptMessage(from: entry, using: dateParsers) else {
                    droppedLineCount += 1
                    continue
                }

                messages.append(message)
            }

            logDroppedLineCount(droppedLineCount, operation: "parse")
            PerfLog.mark("Parser.parseTranscript kept=\(messages.count) dropped=\(droppedLineCount)")

            return messages.sorted { $0.timestamp < $1.timestamp }
        }
    }

    // Returns nil when the file is a dead-artifact session — no user turns,
    // no assistant turns, no user prompt. This primarily catches the tiny
    // one-line JSONLs that `claude --print --no-session-persistence` writes
    // to `~/.claude/projects/-private-var-folders-.../` containing only an
    // `ai-title` record. Our own Claude-CLI speech rewriter produces one
    // per invocation; without this filter the sidebar floods with
    // 0-message "sessions" titled after whatever message was rewritten.
    static func summarizeTranscript(
        _ rawTranscript: String,
        fileURL: URL,
        modifiedAt: Date,
        projectMetadataIndex: ProjectMetadataIndex
    ) -> SessionSummary? {
        let decoder = JSONDecoder()
        let dateParsers = ISO8601DateParsers()
        var sessionID = fileURL.deletingPathExtension().lastPathComponent
        var customTitle: String?
        var aiTitle: String?
        var firstPrompt: String?
        var projectPath: String?
        var sawAnyMessage = false
        var droppedLineCount = 0

        for lineSlice in rawTranscript.split(whereSeparator: \.isNewline) {
            guard let data = String(lineSlice).data(using: .utf8),
                  let entry = try? decoder.decode(TranscriptLine.self, from: data) else {
                droppedLineCount += 1
                continue
            }

            if !sawAnyMessage,
               makeTranscriptMessage(from: entry, using: dateParsers) != nil {
                sawAnyMessage = true
            }

            if let decodedSessionID = normalized(entry.sessionID) {
                sessionID = decodedSessionID
            }

            if projectPath == nil, let cwd = normalized(entry.cwd) {
                projectPath = cwd
            }

            if entry.type == "custom-title",
               let decodedTitle = normalized(entry.customTitle) {
                customTitle = decodedTitle
            }

            if aiTitle == nil,
               entry.type == "ai-title",
               let decodedTitle = normalized(entry.aiTitle) {
                aiTitle = decodedTitle
            }

            if firstPrompt == nil,
               entry.type == "user",
               entry.isMeta != true,
               entry.message?.role == "user",
               let prompt = entry.message?.content.plainText?.trimmedNonEmpty {
                firstPrompt = prompt
            }
        }

        logDroppedLineCount(droppedLineCount, operation: "summarize")

        // Drop sessions that are purely metadata (ai-title / custom-title
        // without any real turns and no first prompt). See the comment on
        // this function for the motivating case.
        guard sawAnyMessage || firstPrompt != nil else {
            return nil
        }

        let fallbackProjectPath = fileURL.deletingLastPathComponent().lastPathComponent
        let sessionMetadata = projectMetadataIndex.metadata(
            forFilePath: fileURL.path,
            sessionID: sessionID
        )
        let resolvedSummary =
            normalized(customTitle)
            ?? normalized(aiTitle)
            ?? normalized(sessionMetadata?.summary)
            ?? summarizedPrompt(firstPrompt, fallback: sessionID)

        return SessionSummary(
            id: sessionID,
            summary: resolvedSummary,
            firstPrompt: firstPrompt,
            modifiedAt: modifiedAt,
            projectPath: projectPath ?? fallbackProjectPath,
            transcriptURL: fileURL
        )
    }

    private static func makeTranscriptMessage(
        from entry: TranscriptLine,
        using dateParsers: ISO8601DateParsers
    ) -> TranscriptMessage? {
        guard let timestampValue = entry.timestamp,
              let timestamp = dateParsers.date(from: timestampValue),
              let uuid = entry.uuid else {
            return nil
        }

        guard entry.isMeta != true else {
            return nil
        }

        guard let envelope = entry.message else {
            return nil
        }

        switch (entry.type, envelope.role) {
        case ("user", "user"):
            guard let text = envelope.content.plainUserText?.trimmedNonEmpty else {
                return nil
            }

            return TranscriptMessage(
                id: uuid,
                role: .user,
                text: text,
                timestamp: timestamp,
                sessionID: entry.sessionID ?? ""
            )

        case ("assistant", "assistant"):
            let joinedText = envelope.content.assistantTextSegments
                .map(\.trimmed)
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")

            guard let text = joinedText.trimmedNonEmpty else {
                return nil
            }

            return TranscriptMessage(
                id: uuid,
                role: .assistant,
                text: text,
                timestamp: timestamp,
                sessionID: entry.sessionID ?? "",
                isIntermediate: envelope.stopReason == "tool_use"
            )

        default:
            return nil
        }
    }

    // The marker Claude Code appends when the user escapes a turn —
    // either to edit-and-resend (no assistant output yet) or to stop a
    // response in flight. Matched as a prefix so the "...for tool use"
    // variant is covered too. Both content shapes are checked because
    // the marker has appeared as a plain string and as a single text
    // item across CLI versions.
    static let interruptionMarkerPrefix = "[Request interrupted by user"

    private static func isInterruptionMarker(_ entry: TranscriptLine) -> Bool {
        guard entry.type == "user",
              entry.message?.role == "user",
              let text = entry.message?.content.plainText else {
            return false
        }
        return text.hasPrefix(interruptionMarkerPrefix)
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func summarizedPrompt(_ prompt: String?, fallback: String) -> String {
        let base = normalized(prompt?.replacingOccurrences(of: "\n", with: " ")) ?? fallback
        let maxLength = 88

        guard base.count > maxLength else {
            return base
        }

        return String(base.prefix(maxLength - 1)) + "…"
    }

    private static func logDroppedLineCount(_ droppedLineCount: Int, operation: String) {
        guard droppedLineCount > 0 else {
            return
        }

        logger.debug("Dropped \(droppedLineCount, privacy: .public) JSONL lines while \(operation, privacy: .public) transcript content")
    }
}

struct ProjectMetadataIndex {
    private(set) var byFilePath: [String: SessionMetadata] = [:]
    private(set) var bySessionID: [String: SessionMetadata] = [:]

    mutating func merge(_ metadata: SessionMetadata, forFilePath filePath: String?, sessionID: String?) {
        guard metadata.summary != nil else {
            return
        }

        if let filePath {
            Self.merge(metadata, into: &byFilePath, key: filePath)
        }

        if let sessionID {
            Self.merge(metadata, into: &bySessionID, key: sessionID)
        }
    }

    func metadata(forFilePath filePath: String, sessionID: String) -> SessionMetadata? {
        byFilePath[filePath] ?? bySessionID[sessionID]
    }

    private static func merge(
        _ metadata: SessionMetadata,
        into storage: inout [String: SessionMetadata],
        key: String
    ) {
        if let existing = storage[key],
           existing.source == .sessionCache,
           metadata.source == .sessionsIndex {
            return
        }

        storage[key] = metadata
    }
}

struct SessionMetadata {
    enum Source {
        case sessionsIndex
        case sessionCache
    }

    let summary: String?
    let source: Source
}

private struct TranscriptLine: Decodable {
    let type: String?
    let uuid: String?
    let timestamp: String?
    let sessionID: String?
    let cwd: String?
    let aiTitle: String?
    let customTitle: String?
    let isMeta: Bool?
    let message: TranscriptEnvelope?

    enum CodingKeys: String, CodingKey {
        case type
        case uuid
        case timestamp
        case sessionID = "sessionId"
        case cwd
        case aiTitle
        case customTitle
        case isMeta
        case message
    }
}

private struct TranscriptEnvelope: Decodable {
    let role: String?
    let content: TranscriptContent
    // Anthropic API stop reason; `tool_use` means the model ended
    // this turn by calling a tool (more turns coming). Other values
    // (`end_turn`, `stop_sequence`, `max_tokens`, nil) all represent
    // model-finished states and are treated as final for display.
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case stopReason = "stop_reason"
    }
}

private enum TranscriptContent: Decodable {
    case string(String)
    case items([TranscriptContentItem])
    case unsupported

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }

        if let itemValue = try? container.decode([TranscriptContentItem].self) {
            self = .items(itemValue)
            return
        }

        self = .unsupported
    }

    var plainText: String? {
        switch self {
        case let .string(value):
            return value
        case let .items(items):
            let text = items
                .compactMap(\.text)
                .joined(separator: "\n\n")
                .trimmed
            return text.isEmpty ? nil : text
        case .unsupported:
            return nil
        }
    }

    var plainUserText: String? {
        switch self {
        case let .string(value):
            return value
        case let .items(items):
            // Image-bearing user prompts arrive as a content array
            // (text block(s) + image block(s)) instead of a bare
            // string. Join the text blocks so the message still renders.
            // A tool_result envelope is also array content but carries
            // no text block, so it correctly yields nil and stays hidden
            // (as do image-only blocks).
            let text = items
                .filter { $0.type == "text" }
                .compactMap(\.text)
                .joined(separator: "\n\n")
                .trimmed
            return text.isEmpty ? nil : text
        case .unsupported:
            return nil
        }
    }

    var assistantTextSegments: [String] {
        switch self {
        case let .items(items):
            return items.compactMap { item in
                guard item.type == "text" else {
                    return nil
                }

                return item.text
            }
        case .string, .unsupported:
            return []
        }
    }
}

private struct TranscriptContentItem: Decodable {
    let type: String?
    let text: String?
}
