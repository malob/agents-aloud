import Foundation
import OSLog

actor ClaudeStorageService {
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "local.claudecodevoice", category: "Storage")
    private var sessionSummaryCache: [String: CachedSessionSummary] = [:]
    private var transcriptCache: [String: CachedTranscript] = [:]
    private var projectMetadataCache: [String: CachedProjectMetadata] = [:]

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
        let sortedMessages = ClaudeTranscriptParser.parseTranscript(rawTranscript)
        transcriptCache[session.transcriptPath] = CachedTranscript(
            modifiedAt: modifiedAt,
            messages: sortedMessages
        )
        logger.debug(
            "Loaded transcript \(session.id, privacy: .public) with \(sortedMessages.count, privacy: .public) speakable messages"
        )
        return sortedMessages
    }

    private func summarizeTranscriptFile(at fileURL: URL, modifiedAt: Date) throws -> ClaudeSessionSummary? {
        let rawTranscript = try String(contentsOf: fileURL, encoding: .utf8)
        let projectURL = fileURL.deletingLastPathComponent()
        let projectMetadataIndex = try loadProjectMetadataIndex(for: projectURL)
        return ClaudeTranscriptParser.summarizeTranscript(
            rawTranscript,
            fileURL: fileURL,
            modifiedAt: modifiedAt,
            projectMetadataIndex: projectMetadataIndex
        )
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
                        summary: entry.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
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
                        summary: session.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
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
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
