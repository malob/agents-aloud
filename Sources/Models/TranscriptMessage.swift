import Foundation

struct TranscriptMessage: Identifiable, Hashable {
    enum Role: String, Hashable {
        case user
        case assistant
    }

    enum Content: Hashable {
        case literal(String)
        case plainText(String)
        case markdown(String)

        // XML-ish envelopes Claude Code injects into prompts (hook
        // notifications, slash-command metadata, etc.). Rendered verbatim
        // because they aren't user-intended content — skipping markdown
        // detection keeps them from getting mangled by asterisks or
        // pipe-table heuristics further below.
        private static let literalPrefixes = [
            "<task-notification>",
            "<command-message>",
            "<command-name>",
            "<command-args>",
            "<local-command-caveat>",
        ]

        static func detect(from text: String) -> Self {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if literalPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
                return .literal(text)
            }

            if text.contains("`") ||
                text.contains("](") ||
                text.contains("![") ||
                text.contains("**") ||
                text.contains("__") ||
                text.contains("~~") {
                return .markdown(text)
            }

            for line in text.split(whereSeparator: \.isNewline) {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if trimmedLine.isEmpty {
                    continue
                }

                if trimmedLine.hasPrefix("#") ||
                    trimmedLine.hasPrefix(">") ||
                    trimmedLine.hasPrefix("- ") ||
                    trimmedLine.hasPrefix("* ") ||
                    trimmedLine.hasPrefix("+ ") ||
                    trimmedLine == "---" ||
                    trimmedLine == "***" ||
                    trimmedLine.contains("| ---") ||
                    trimmedLine.contains(" | ") ||
                    orderedListPrefix(in: trimmedLine) {
                    return .markdown(text)
                }
            }

            return .plainText(text)
        }

        var text: String {
            switch self {
            case let .literal(text), let .plainText(text), let .markdown(text):
                return text
            }
        }

        private static func orderedListPrefix(in line: String) -> Bool {
            var digits = 0

            for character in line {
                if character.isNumber {
                    digits += 1
                    continue
                }

                return digits > 0 && character == "." && line.dropFirst(digits + 1).first == " "
            }

            return false
        }
    }

    let id: String
    let role: Role
    let content: Content
    let timestamp: Date
    let sessionID: String
    // True when this is an assistant message that ended its turn by
    // calling a tool (Claude `stop_reason == "tool_use"`) or that's
    // marked as a non-final phase (Codex `phase != "final_answer"`).
    // Intermediate assistant messages are noisy work-in-progress
    // chatter relative to natural turn-ends; the storage layer
    // optionally filters them out before applying the display cap.
    // Always false for user messages.
    let isIntermediate: Bool

    init(
        id: String,
        role: Role,
        text: String,
        timestamp: Date,
        sessionID: String,
        isIntermediate: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = Content.detect(from: text)
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.isIntermediate = isIntermediate
    }

    var text: String {
        content.text
    }

    var isAssistant: Bool {
        role == .assistant
    }
}
