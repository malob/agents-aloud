import Foundation
import Testing
@testable import ClaudeCodeVoice

@MainActor
private final class WatcherRecorder {
    private(set) var changeCount = 0
    private(set) var failures: [TranscriptFileWatcherError] = []

    func recordChange() {
        changeCount += 1
    }

    func recordFailure(_ error: TranscriptFileWatcherError) {
        failures.append(error)
    }
}

struct TranscriptFileWatcherTests {
    @Test
    @MainActor
    func watcherRearmsAfterFileReplacement() async throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-TranscriptFileWatcherTests-\(UUID().uuidString)", isDirectory: true)
        let watchedFileURL = temporaryDirectory.appendingPathComponent("transcript.jsonl", isDirectory: false)
        let oldFileURL = temporaryDirectory.appendingPathComponent("transcript-old.jsonl", isDirectory: false)
        let watcher = TranscriptFileWatcher()
        let recorder = WatcherRecorder()

        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try "initial".write(to: watchedFileURL, atomically: true, encoding: .utf8)
        defer {
            watcher.stop()
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        watcher.startWatching(
            fileURL: watchedFileURL,
            onChange: {
                recorder.recordChange()
            },
            onFailure: { error in
                recorder.recordFailure(error)
            }
        )

        try fileManager.moveItem(at: watchedFileURL, to: oldFileURL)
        try "replacement".write(to: watchedFileURL, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(250))

        try append(" more", to: watchedFileURL)

        try await waitUntil(timeout: .seconds(2)) {
            recorder.changeCount > 0 || !recorder.failures.isEmpty
        }

        #expect(recorder.failures.isEmpty)
        #expect(recorder.changeCount > 0)
    }

    @Test
    @MainActor
    func watcherReportsOpenFailureAfterRetries() async throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-TranscriptFileWatcherTests-\(UUID().uuidString)", isDirectory: true)
        let missingFileURL = temporaryDirectory.appendingPathComponent("missing.jsonl", isDirectory: false)
        let watcher = TranscriptFileWatcher()
        let recorder = WatcherRecorder()

        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            watcher.stop()
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        watcher.startWatching(
            fileURL: missingFileURL,
            onChange: {
                recorder.recordChange()
            },
            onFailure: { error in
                recorder.recordFailure(error)
            }
        )

        try await waitUntil(timeout: .seconds(1)) {
            !recorder.failures.isEmpty
        }

        #expect(recorder.changeCount == 0)
        #expect(recorder.failures == [.openFailed(fileName: "missing.jsonl", errorNumber: ENOENT)])
    }

    private func append(_ string: String, to fileURL: URL) throws {
        let data = try #require(string.data(using: .utf8))
        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            try? handle.close()
        }

        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func waitUntil(
        timeout: Duration,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }

            try await Task.sleep(for: .milliseconds(25))
        }

        Issue.record("Timed out waiting for watcher condition")
    }
}
