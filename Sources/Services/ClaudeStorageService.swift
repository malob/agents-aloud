import Foundation
import OSLog

actor ClaudeStorageService {
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "local.claudecodevoice", category: "Storage")
    private let projectsRoot: URL
    private var sessionSummaryCache: [String: CachedSessionSummary] = [:]
    private var transcriptCache: [String: CachedTranscript] = [:]
    private var projectMetadataCache: [String: CachedProjectMetadata] = [:]

    init(
        projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    ) {
        self.projectsRoot = projectsRoot
    }

    func loadSessions(limit: Int = 200) throws -> [ClaudeSessionSummary] {
        try PerfLog.time("Storage.loadSessions") {
            try _loadSessions(limit: limit)
        }
    }

    private func _loadSessions(limit: Int) throws -> [ClaudeSessionSummary] {
        let projectURLs = try fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        )

        var transcriptCandidates: [(url: URL, modifiedAt: Date)] = []

        for projectURL in projectURLs {
            do {
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
            } catch {
                logger.error(
                    "Skipping project directory \(projectURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
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
        let validProjectPaths = Set(validPaths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        sessionSummaryCache = sessionSummaryCache.filter { validPaths.contains($0.key) }
        transcriptCache = transcriptCache.filter { validPaths.contains($0.key) }
        projectMetadataCache = projectMetadataCache.filter { validProjectPaths.contains($0.key) }

        return sessions
    }

    func loadTranscript(for session: ClaudeSessionSummary) throws -> [TranscriptMessage] {
        try PerfLog.time("Storage.loadTranscript") {
            let transcriptURL = URL(fileURLWithPath: session.transcriptPath)
            let values = try transcriptURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modifiedAt = values.contentModificationDate ?? .distantPast
            let fileSize = values.fileSize ?? 0

            if let cached = transcriptCache[session.transcriptPath] {
                if cached.modifiedAt == modifiedAt {
                    PerfLog.mark("Storage.loadTranscript cacheHit")
                    return cached.messages
                }

                // Incremental path: Claude Code writes JSONL append-only, so when
                // the file only grew we can seek past the already-parsed prefix
                // and parse just the new tail. Brings watcher-triggered refresh
                // from ~280ms (full file parse) down to a few ms for typical
                // single-message appends. See `tailMessages(_:fromOffset:)` for
                // the correctness constraints (clean line boundaries, UTF-8).
                if fileSize > cached.fileSize,
                   let appended = try? tailMessages(transcriptURL, fromOffset: cached.fileSize) {
                    let merged = mergeInTimestampOrder(cached.messages, appended)
                    transcriptCache[session.transcriptPath] = CachedTranscript(
                        modifiedAt: modifiedAt,
                        fileSize: fileSize,
                        messages: merged
                    )
                    PerfLog.mark("Storage.loadTranscript incremental appended=\(appended.count)")
                    return merged
                }
            }

            // Cold read, or the file shrank / changed in-place: full parse.
            let rawTranscript = try PerfLog.time("Storage.loadTranscript.read") {
                try String(contentsOf: transcriptURL, encoding: .utf8)
            }
            let sortedMessages = ClaudeTranscriptParser.parseTranscript(rawTranscript)
            transcriptCache[session.transcriptPath] = CachedTranscript(
                modifiedAt: modifiedAt,
                fileSize: fileSize,
                messages: sortedMessages
            )
            return sortedMessages
        }
    }

    // Read bytes from `offset` to end of file, decode as UTF-8, parse as JSONL.
    // Returns the messages found in that tail (already timestamp-sorted by the
    // parser). Assumes `offset` is on a clean line boundary — which it is when
    // we cache the file's full byte length after a previous read, because
    // JSONL writers always emit a trailing `\n` per line. If an incomplete
    // write ever leaves the file mid-line, the decode or decode-per-line will
    // drop the partial line; the next refresh catches it once fully written.
    private func tailMessages(_ url: URL, fromOffset offset: Int) throws -> [TranscriptMessage] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.readToEnd(), !data.isEmpty,
              let tail = String(data: data, encoding: .utf8) else {
            return []
        }
        return ClaudeTranscriptParser.parseTranscript(tail)
    }

    // Fast path: if the tail's earliest message is at-or-after the cached
    // tail, the merged list is already sorted. Only re-sort when we detect
    // an out-of-order timestamp (should be rare given JSONL is append-only
    // and Claude writes chronologically).
    private func mergeInTimestampOrder(
        _ cached: [TranscriptMessage],
        _ appended: [TranscriptMessage]
    ) -> [TranscriptMessage] {
        guard let lastCached = cached.last,
              let firstNew = appended.first,
              firstNew.timestamp < lastCached.timestamp else {
            return cached + appended
        }
        return (cached + appended).sorted { $0.timestamp < $1.timestamp }
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

        if let sessionsIndex: SessionsIndexFile = try decodeIfPresent(SessionsIndexFile.self, at: sessionsIndexURL) {
            for entry in sessionsIndex.entries {
                let metadata = SessionMetadata(
                    summary: entry.summary?.trimmed.nilIfEmpty,
                    source: .sessionsIndex
                )
                index.merge(metadata, forFilePath: entry.fullPath, sessionID: entry.sessionID)
            }
        }

        if let sessionCache: SessionCacheFile = try decodeIfPresent(SessionCacheFile.self, at: sessionCacheURL) {
            for (entryPath, entry) in sessionCache.entries {
                guard let session = entry.session else {
                    continue
                }

                let metadata = SessionMetadata(
                    summary: session.summary?.trimmed.nilIfEmpty,
                    source: .sessionCache
                )
                index.merge(
                    metadata,
                    forFilePath: session.filePath ?? entryPath,
                    sessionID: session.actualSessionID
                )
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

    private func decodeIfPresent<T: Decodable>(_ type: T.Type, at fileURL: URL) throws -> T? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let rawValue = try String(contentsOf: fileURL, encoding: .utf8)
        guard let data = rawValue.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }
}

private struct CachedSessionSummary {
    let modifiedAt: Date
    let summary: ClaudeSessionSummary
}

private struct CachedTranscript {
    let modifiedAt: Date
    let fileSize: Int
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
