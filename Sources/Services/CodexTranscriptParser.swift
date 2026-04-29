import Foundation
import OSLog

// Parses Codex CLI rollout JSONL files (`~/.codex/sessions/YYYY/MM/DD/
// rollout-<TIMESTAMP>-<UUID>.jsonl`) into TranscriptMessage / summary
// values the rest of the app already understands.
//
// Per-line schema (from the canonical Rust source in
// codex-rs/protocol/src/protocol.rs at `RolloutLine` / `RolloutItem`):
//
//   { "timestamp": "...", "type": "...", "payload": {...} }
//
// Five `type` values exist (snake_case): `session_meta`, `response_item`,
// `compacted`, `turn_context`, `event_msg`. We care about three:
//
// - `session_meta` (always the first line) — header for the conversation.
//   Fields we use: `id`, `timestamp`, `cwd`, `agent_nickname` /
//   `agent_role` (presence ⇒ this is a sub-agent run; we hide those
//   from the sidebar), `originator`, `source`.
// - `response_item` with `payload.type == "message"` — actual
//   conversation turns. We surface roles `user` and `assistant` and
//   drop `developer` (system-prompt-style instructions).
// - `compacted` — Codex auto-summarizes long histories, replacing
//   them with a synthesized assistant summary. We render as a
//   single assistant message so the user sees what was retained.
//
// Boilerplate filtered at the message level (Codex-injected wrappers
// the user didn't actually write):
//   - User messages whose ONLY content is an `<environment_context>`,
//     `<turn_aborted>`, or `<permissions instructions>` block.
//   - Assistant messages with a non-final `phase` (intermediate
//     reasoning / tool-use chatter, not the final user-facing reply).
@MainActor
final class CodexTranscriptParser {
    private let logger = Logger(subsystem: "local.claudecodevoice", category: "CodexTranscriptParser")

    // What we extract from a session file's metadata + first user
    // message, without doing the full transcript parse. Used by the
    // storage service to populate the sidebar without reading every
    // message.
    struct Summary {
        let sessionID: String
        let cwd: String
        let firstUserPrompt: String?
        let messageCount: Int
        let derivedTitle: String
        let isSubagent: Bool
    }

    // MARK: - Public API

    nonisolated func parseTranscript(from url: URL) throws -> [TranscriptMessage] {
        let data = try Data(contentsOf: url)
        return Self.parseTranscript(data: data, sessionID: Self.sessionID(from: url))
    }

    nonisolated func summarize(transcriptAt url: URL) throws -> Summary? {
        let data = try Data(contentsOf: url)
        return Self.summarize(data: data, sessionID: Self.sessionID(from: url))
    }

    // MARK: - Implementation

    nonisolated static func parseTranscript(data: Data, sessionID: String) -> [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        var index = 0
        forEachLine(in: data) { line in
            guard let dict = decodeJSON(line) else { return }
            if let extracted = extractMessage(from: dict, sessionID: sessionID, index: index) {
                messages.append(extracted)
                index += 1
            }
        }
        return messages
    }

    nonisolated static func summarize(data: Data, sessionID: String) -> Summary? {
        var cwd: String?
        var isSubagent = false
        var firstUserPrompt: String?
        var messageCount = 0

        forEachLine(in: data) { line in
            guard let dict = decodeJSON(line) else { return }
            guard let type = dict["type"] as? String else { return }
            let payload = dict["payload"] as? [String: Any]

            switch type {
            case "session_meta":
                if let p = payload {
                    cwd = p["cwd"] as? String
                    if (p["agent_nickname"] as? String) != nil ||
                       (p["agent_role"] as? String) != nil {
                        isSubagent = true
                    }
                    // `source` can be a string OR an object with a
                    // `subagent` key — both indicate a non-user-driven
                    // session we want hidden from the sidebar.
                    if let source = p["source"] as? [String: Any],
                       source["subagent"] != nil {
                        isSubagent = true
                    }
                }
            case "response_item":
                if let extracted = extractMessage(from: dict, sessionID: sessionID, index: messageCount) {
                    messageCount += 1
                    if firstUserPrompt == nil, extracted.role == .user {
                        firstUserPrompt = extracted.text
                    }
                }
            case "compacted":
                if let p = payload, let message = p["message"] as? String, !message.isEmpty {
                    messageCount += 1
                }
            default:
                break
            }
        }

        guard let cwd else { return nil }
        return Summary(
            sessionID: sessionID,
            cwd: cwd,
            firstUserPrompt: firstUserPrompt,
            messageCount: messageCount,
            derivedTitle: deriveTitle(firstUserPrompt: firstUserPrompt, cwd: cwd),
            isSubagent: isSubagent
        )
    }

    // MARK: - Per-line extraction

    // Returns a TranscriptMessage if the line is a user/assistant
    // text turn worth showing, nil otherwise. Handles both
    // `response_item` and `compacted` line types.
    private nonisolated static func extractMessage(
        from dict: [String: Any],
        sessionID: String,
        index: Int
    ) -> TranscriptMessage? {
        guard let type = dict["type"] as? String else { return nil }
        let timestamp = (dict["timestamp"] as? String).flatMap(parseTimestamp) ?? Date()

        switch type {
        case "response_item":
            return extractResponseItem(
                payload: dict["payload"] as? [String: Any],
                timestamp: timestamp,
                sessionID: sessionID,
                index: index
            )
        case "compacted":
            return extractCompacted(
                payload: dict["payload"] as? [String: Any],
                timestamp: timestamp,
                sessionID: sessionID,
                index: index
            )
        default:
            return nil
        }
    }

    private nonisolated static func extractResponseItem(
        payload: [String: Any]?,
        timestamp: Date,
        sessionID: String,
        index: Int
    ) -> TranscriptMessage? {
        guard let payload, payload["type"] as? String == "message",
              let role = payload["role"] as? String else { return nil }

        // Skip `developer` (system-prompt-style instructions Codex
        // injects pre-conversation).
        let mappedRole: TranscriptMessage.Role
        switch role {
        case "user": mappedRole = .user
        case "assistant": mappedRole = .assistant
        default: return nil
        }

        // For assistant messages, skip non-final phases (intermediate
        // tool-use / reasoning chatter, not the user-facing reply).
        if mappedRole == .assistant {
            if let phase = payload["phase"] as? String, phase != "final_answer" {
                return nil
            }
        }

        let text = collectText(from: payload["content"])
        guard !text.isEmpty else { return nil }
        // Skip user messages that are wholly Codex-injected boilerplate.
        if mappedRole == .user, isBoilerplate(text) { return nil }

        return TranscriptMessage(
            id: "\(sessionID)-\(index)",
            role: mappedRole,
            text: text,
            timestamp: timestamp,
            sessionID: sessionID
        )
    }

    private nonisolated static func extractCompacted(
        payload: [String: Any]?,
        timestamp: Date,
        sessionID: String,
        index: Int
    ) -> TranscriptMessage? {
        guard let payload, let message = payload["message"] as? String,
              !message.isEmpty else { return nil }
        return TranscriptMessage(
            id: "\(sessionID)-compacted-\(index)",
            role: .assistant,
            text: message,
            timestamp: timestamp,
            sessionID: sessionID
        )
    }

    // Pull the user-visible text out of a content array. Each item is
    // a dict with a `type` ("input_text" / "output_text" / others) and
    // a `text` field. We concatenate text-bearing items in order.
    private nonisolated static func collectText(from contentValue: Any?) -> String {
        guard let content = contentValue as? [[String: Any]] else {
            // Some older lines have content as a plain String.
            if let plain = contentValue as? String {
                return plain.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }
        let texts: [String] = content.compactMap { item in
            guard let type = item["type"] as? String,
                  type == "input_text" || type == "output_text" else { return nil }
            return item["text"] as? String
        }
        return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Heuristic: a user message is boilerplate if its trimmed content
    // is a single XML-style block matching one of the known wrappers
    // Codex injects. Anything that combines a wrapper with real prose
    // still surfaces (the user's prose is what matters).
    private nonisolated static func isBoilerplate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers = [
            "<environment_context>",
            "<turn_aborted>",
            "<permissions instructions>",
        ]
        for w in wrappers {
            if trimmed.hasPrefix(w) {
                // Treat as boilerplate iff the WHOLE message is just
                // that wrapper (no extra user prose appended). We
                // check by finding the closing tag and seeing if any
                // non-whitespace remains after it.
                let closeTag = w.replacingOccurrences(of: "<", with: "</")
                if let closeRange = trimmed.range(of: closeTag) {
                    let tail = trimmed[closeRange.upperBound...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return tail.isEmpty
                }
                return true  // open without close = malformed; hide
            }
        }
        return false
    }

    // MARK: - Helpers

    nonisolated static func sessionID(from url: URL) -> String {
        // Filename pattern: rollout-<ISO_TIMESTAMP>-<UUID>.jsonl
        let stem = url.deletingPathExtension().lastPathComponent
        // The UUID is the last hyphen-separated 5-section block; look
        // for the suffix that matches "<8>-<4>-<4>-<4>-<12>".
        let parts = stem.split(separator: "-")
        if parts.count >= 5 {
            let last5 = parts.suffix(5).joined(separator: "-")
            return last5
        }
        return stem
    }

    private nonisolated static func parseTimestamp(_ s: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: s) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: s)
    }

    private nonisolated static func decodeJSON(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // Minimal-allocation line iterator over UTF-8 JSONL data.
    private nonisolated static func forEachLine(
        in data: Data,
        body: (String) -> Void
    ) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { body(trimmed) }
        }
    }

    private nonisolated static func deriveTitle(firstUserPrompt: String?, cwd: String) -> String {
        if let prompt = firstUserPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            // Take the first non-empty line, capped at ~80 chars.
            let firstLine = prompt
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init) ?? prompt
            return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
        }
        // Fallback: project name from cwd.
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? "Untitled session" : "Session in \(name)"
    }
}
