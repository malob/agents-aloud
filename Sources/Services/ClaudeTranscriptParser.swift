import Foundation

enum ClaudeTranscriptParser {
    static func parseTranscript(_ rawTranscript: String) -> [TranscriptMessage] {
        let decoder = JSONDecoder()
        let dateParsers = ISO8601DateParsers()
        var messages: [TranscriptMessage] = []

        for lineSlice in rawTranscript.split(whereSeparator: \.isNewline) {
            guard let data = String(lineSlice).data(using: .utf8),
                  let entry = try? decoder.decode(TranscriptLine.self, from: data),
                  let message = makeTranscriptMessage(from: entry, using: dateParsers) else {
                continue
            }

            messages.append(message)
        }

        return messages.sorted { $0.timestamp < $1.timestamp }
    }

    static func summarizeTranscript(
        _ rawTranscript: String,
        fileURL: URL,
        modifiedAt: Date,
        projectMetadataIndex: ProjectMetadataIndex
    ) -> ClaudeSessionSummary? {
        let decoder = JSONDecoder()
        let dateParsers = ISO8601DateParsers()
        var sessionID = fileURL.deletingPathExtension().lastPathComponent
        var customTitle: String?
        var aiTitle: String?
        var firstPrompt: String?
        var projectPath: String?
        var messageCount = 0

        for lineSlice in rawTranscript.split(whereSeparator: \.isNewline) {
            guard let data = String(lineSlice).data(using: .utf8),
                  let entry = try? decoder.decode(TranscriptLine.self, from: data) else {
                continue
            }

            if makeTranscriptMessage(from: entry, using: dateParsers) != nil {
                messageCount += 1
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

        return ClaudeSessionSummary(
            id: sessionID,
            summary: resolvedSummary,
            firstPrompt: firstPrompt,
            modifiedAt: modifiedAt,
            projectPath: projectPath ?? fallbackProjectPath,
            transcriptPath: fileURL.path,
            messageCount: messageCount
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
                renderingMode: renderingMode(for: text),
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
                renderingMode: renderingMode(for: text),
                timestamp: timestamp,
                sessionID: entry.sessionID ?? ""
            )

        default:
            return nil
        }
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func renderingMode(for text: String) -> TranscriptMessage.RenderingMode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let literalPrefixes = [
            "<task-notification>",
            "<command-message>",
            "<command-name>",
            "<command-args>",
            "<local-command-caveat>",
        ]

        if literalPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return .literal
        }

        if text.contains("```") ||
            text.contains("`") ||
            text.contains("](") ||
            text.contains("![") ||
            text.contains("**") ||
            text.contains("__") ||
            text.contains("~~") {
            return .markdown
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
                return .markdown
            }
        }

        return .plainText
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

    private static func summarizedPrompt(_ prompt: String?, fallback: String) -> String {
        let base = normalized(prompt?.replacingOccurrences(of: "\n", with: " ")) ?? fallback
        let maxLength = 88

        guard base.count > maxLength else {
            return base
        }

        return String(base.prefix(maxLength - 1)) + "…"
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

private struct ISO8601DateParsers {
    let fractionalSeconds: ISO8601DateFormatter
    let standard: ISO8601DateFormatter

    init() {
        let fractionalSeconds = ISO8601DateFormatter()
        fractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fractionalSeconds = fractionalSeconds

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        self.standard = standard
    }

    func date(from value: String) -> Date? {
        fractionalSeconds.date(from: value) ?? standard.date(from: value)
    }
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
        case .items, .unsupported:
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

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedNonEmpty: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}
