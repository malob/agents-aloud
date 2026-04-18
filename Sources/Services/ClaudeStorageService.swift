import Foundation
import OSLog

actor ClaudeStorageService {
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "local.claudecodevoice", category: "Storage")
    private let fractionalDateFormatter: ISO8601DateFormatter
    private let standardDateFormatter: ISO8601DateFormatter
    private let summaryDecoder = JSONDecoder()
    private let transcriptDecoder: JSONDecoder
    private var sessionSummaryCache: [String: CachedSessionSummary] = [:]
    private var transcriptCache: [String: CachedTranscript] = [:]
    private var projectMetadataCache: [String: CachedProjectMetadata] = [:]

    init() {
        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fractionalDateFormatter = fractionalDateFormatter

        let standardDateFormatter = ISO8601DateFormatter()
        standardDateFormatter.formatOptions = [.withInternetDateTime]
        self.standardDateFormatter = standardDateFormatter

        transcriptDecoder = JSONDecoder()
    }

    func loadSessions(limit: Int = 200) throws -> [ClaudeSessionSummary] {
        let startedAt = ContinuousClock.now
        let projectsRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)

        let projectURLs = try fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        )

        var transcriptCandidates: [(url: URL, modifiedAt: Date)] = []

        for projectURL in projectURLs {
            let values = try projectURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }

            let childURLs = try fileManager.contentsOfDirectory(
                at: projectURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            for childURL in childURLs where childURL.pathExtension == "jsonl" {
                let childValues = try childURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard childValues.isRegularFile == true else {
                    continue
                }

                transcriptCandidates.append((childURL, childValues.contentModificationDate ?? .distantPast))
            }
        }

        let sortedCandidates = transcriptCandidates.sorted { lhs, rhs in
            lhs.modifiedAt > rhs.modifiedAt
        }

        var sessions: [ClaudeSessionSummary] = []

        for candidate in sortedCandidates.prefix(limit) {
            if let cachedSummary = sessionSummaryCache[candidate.url.path],
               cachedSummary.modifiedAt == candidate.modifiedAt {
                sessions.append(cachedSummary.summary)
                continue
            }

            guard let sessionSummary = try summarizeTranscriptFile(
                at: candidate.url,
                modifiedAt: candidate.modifiedAt
            ) else {
                continue
            }

            sessionSummaryCache[candidate.url.path] = CachedSessionSummary(
                modifiedAt: candidate.modifiedAt,
                summary: sessionSummary
            )
            sessions.append(sessionSummary)
        }

        let validPaths = Set(sortedCandidates.prefix(limit).map { $0.url.path })
        sessionSummaryCache = sessionSummaryCache.filter { validPaths.contains($0.key) }

        logger.info(
            "Loaded \(sessions.count, privacy: .public) session summaries from \(sortedCandidates.count, privacy: .public) candidates in \(startedAt.duration(to: .now).components.seconds, privacy: .public)s"
        )

        return sessions
    }

    func loadTranscript(for session: ClaudeSessionSummary) throws -> [TranscriptMessage] {
        let transcriptURL = URL(fileURLWithPath: session.transcriptPath)
        let modifiedAt = try transcriptURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast

        if let cachedTranscript = transcriptCache[session.transcriptPath],
           cachedTranscript.modifiedAt == modifiedAt {
            return cachedTranscript.messages
        }

        let rawTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)

        var messages: [TranscriptMessage] = []

        for lineSlice in rawTranscript.split(whereSeparator: \.isNewline) {
            let line = String(lineSlice)
            guard !line.isEmpty, let data = line.data(using: .utf8) else {
                continue
            }

            do {
                let entry = try transcriptDecoder.decode(TranscriptLine.self, from: data)
                guard let message = self.makeTranscriptMessage(from: entry) else {
                    continue
                }

                messages.append(message)
            } catch {
                // Ignore lines that are not speakable transcript entries.
            }
        }

        let sortedMessages = messages.sorted { $0.timestamp < $1.timestamp }
        transcriptCache[session.transcriptPath] = CachedTranscript(
            modifiedAt: modifiedAt,
            messages: sortedMessages
        )
        logger.debug(
            "Loaded transcript \(session.id, privacy: .public) with \(sortedMessages.count, privacy: .public) speakable messages"
        )
        return sortedMessages
    }

    private func makeTranscriptMessage(from entry: TranscriptLine) -> TranscriptMessage? {
        guard let timestampValue = entry.timestamp,
              let timestamp = parseISO8601Date(timestampValue),
              let uuid = entry.uuid else {
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
                sessionID: entry.sessionID ?? ""
            )

        default:
            return nil
        }
    }

    private func normalized(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func parseISO8601Date(_ value: String) -> Date? {
        if let date = fractionalDateFormatter.date(from: value) {
            return date
        }

        return standardDateFormatter.date(from: value)
    }

    private func summarizeTranscriptFile(at fileURL: URL, modifiedAt: Date) throws -> ClaudeSessionSummary? {
        let rawTranscript = try String(contentsOf: fileURL, encoding: .utf8)
        let projectURL = fileURL.deletingLastPathComponent()
        let projectMetadataIndex = try loadProjectMetadataIndex(for: projectURL)
        var sessionID = fileURL.deletingPathExtension().lastPathComponent
        var customTitle: String?
        var aiTitle: String?
        var firstPrompt: String?
        var projectPath: String?
        var messageCount = 0

        for lineSlice in rawTranscript.split(whereSeparator: \.isNewline) {
            let line = String(lineSlice)
            guard let data = line.data(using: .utf8) else {
                continue
            }

            if let transcriptEntry = try? transcriptDecoder.decode(TranscriptLine.self, from: data),
               makeTranscriptMessage(from: transcriptEntry) != nil {
                messageCount += 1
            }

            guard Self.mayContainSessionMetadata(line, needsFirstPrompt: firstPrompt == nil, needsProjectPath: projectPath == nil) else {
                continue
            }

            guard let entry = try? self.summaryDecoder.decode(SummaryTranscriptLine.self, from: data) else {
                continue
            }

            if let decodedSessionID = self.normalized(entry.sessionID) {
                sessionID = decodedSessionID
            }

            if projectPath == nil, let cwd = self.normalized(entry.cwd) {
                projectPath = cwd
            }

            if entry.type == "custom-title",
               let decodedTitle = self.normalized(entry.customTitle) {
                customTitle = decodedTitle
            }

            if aiTitle == nil,
               entry.type == "ai-title",
               let decodedTitle = self.normalized(entry.aiTitle) {
                aiTitle = decodedTitle
            }

            if firstPrompt == nil,
               entry.type == "user",
               entry.message?.role == "user",
               let prompt = entry.message?.content?.plainText?.trimmedNonEmpty {
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
            createdAt: nil,
            modifiedAt: modifiedAt,
            projectPath: projectPath ?? fallbackProjectPath,
            transcriptPath: fileURL.path,
            messageCount: messageCount
        )
    }

    private func summarizedPrompt(_ prompt: String?, fallback: String) -> String {
        let base = normalized(prompt?.replacingOccurrences(of: "\n", with: " ")) ?? fallback
        let maxLength = 88

        guard base.count > maxLength else {
            return base
        }

        return String(base.prefix(maxLength - 1)) + "…"
    }

    private static func mayContainSessionMetadata(_ line: String, needsFirstPrompt: Bool, needsProjectPath: Bool) -> Bool {
        if line.contains(#""type":"custom-title""#) || line.contains(#""type": "custom-title""#) {
            return true
        }

        if line.contains(#""type":"ai-title""#) || line.contains(#""type": "ai-title""#) {
            return true
        }

        if needsFirstPrompt && (line.contains(#""type":"user""#) || line.contains(#""type": "user""#)) {
            return true
        }

        if needsProjectPath && (line.contains(#""cwd":"#) || line.contains(#""cwd": "#)) {
            return true
        }

        return false
    }

    private func loadProjectMetadataIndex(for projectURL: URL) throws -> ProjectMetadataIndex {
        let sessionCacheURL = projectURL.appendingPathComponent(".session_cache.json", isDirectory: false)
        let sessionsIndexURL = projectURL.appendingPathComponent("sessions-index.json", isDirectory: false)
        let sessionCacheModifiedAt = fileModificationDate(for: sessionCacheURL)
        let sessionsIndexModifiedAt = fileModificationDate(for: sessionsIndexURL)

        if let cachedProjectMetadata = projectMetadataCache[projectURL.path],
           cachedProjectMetadata.sessionCacheModifiedAt == sessionCacheModifiedAt,
           cachedProjectMetadata.sessionsIndexModifiedAt == sessionsIndexModifiedAt {
            return cachedProjectMetadata.index
        }

        var index = ProjectMetadataIndex()

        if fileManager.fileExists(atPath: sessionsIndexURL.path) {
            let rawSessionsIndex = try String(contentsOf: sessionsIndexURL, encoding: .utf8)
            if let data = rawSessionsIndex.data(using: .utf8),
               let sessionsIndex = try? JSONDecoder().decode(SessionsIndexFile.self, from: data) {
                for entry in sessionsIndex.entries {
                    let metadata = SessionMetadata(
                        summary: normalized(entry.summary),
                        source: .sessionsIndex
                    )
                    index.merge(metadata, forFilePath: entry.fullPath, sessionID: entry.sessionID)
                }
            }
        }

        if fileManager.fileExists(atPath: sessionCacheURL.path) {
            let rawSessionCache = try String(contentsOf: sessionCacheURL, encoding: .utf8)
            if let data = rawSessionCache.data(using: .utf8),
               let sessionCache = try? JSONDecoder().decode(SessionCacheFile.self, from: data) {
                for (entryPath, entry) in sessionCache.entries {
                    guard let session = entry.session else {
                        continue
                    }

                    let metadata = SessionMetadata(
                        summary: normalized(session.summary),
                        source: .sessionCache
                    )
                    index.merge(
                        metadata,
                        forFilePath: session.filePath ?? entryPath,
                        sessionID: session.actualSessionID
                    )
                }
            }
        }

        projectMetadataCache[projectURL.path] = CachedProjectMetadata(
            sessionCacheModifiedAt: sessionCacheModifiedAt,
            sessionsIndexModifiedAt: sessionsIndexModifiedAt,
            index: index
        )
        return index
    }

    private func fileModificationDate(for fileURL: URL) -> Date? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        return try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

private struct CachedSessionSummary {
    let modifiedAt: Date
    let summary: ClaudeSessionSummary
}

private struct CachedTranscript {
    let modifiedAt: Date
    let messages: [TranscriptMessage]
}

private struct CachedProjectMetadata {
    let sessionCacheModifiedAt: Date?
    let sessionsIndexModifiedAt: Date?
    let index: ProjectMetadataIndex
}

private struct ProjectMetadataIndex {
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

private struct SessionMetadata {
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
    let message: TranscriptEnvelope?

    enum CodingKeys: String, CodingKey {
        case type
        case uuid
        case timestamp
        case sessionID = "sessionId"
        case cwd
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

private struct SummaryTranscriptLine: Decodable {
    let type: String?
    let sessionID: String?
    let cwd: String?
    let aiTitle: String?
    let customTitle: String?
    let message: SummaryTranscriptEnvelope?

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "sessionId"
        case cwd
        case aiTitle
        case customTitle
        case message
    }
}

private struct SummaryTranscriptEnvelope: Decodable {
    let role: String?
    let content: SummaryTranscriptContent?
}

private enum SummaryTranscriptContent: Decodable {
    case string(String)
    case items([SummaryTranscriptContentItem])
    case unsupported

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }

        if let itemValue = try? container.decode([SummaryTranscriptContentItem].self) {
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
}

private struct SummaryTranscriptContentItem: Decodable {
    let text: String?
}

private struct SessionsIndexFile: Decodable {
    let entries: [SessionsIndexEntry]
}

private struct SessionsIndexEntry: Decodable {
    let sessionID: String
    let fullPath: String
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case fullPath
        case summary
    }
}

private struct SessionCacheFile: Decodable {
    let entries: [String: SessionCacheEntry]
}

private struct SessionCacheEntry: Decodable {
    let session: SessionCacheSession?
}

private struct SessionCacheSession: Decodable {
    let actualSessionID: String?
    let filePath: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case actualSessionID = "actual_session_id"
        case filePath = "file_path"
        case summary
    }
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
