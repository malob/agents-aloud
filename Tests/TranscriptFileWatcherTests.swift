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

        // Poke the new file repeatedly until the watcher's rearm takes
        // hold. If rearm already happened, the first append fires onChange;
        // if not, subsequent appends catch the newly-armed watcher.
        try await waitUntil(timeout: .seconds(2)) {
            try? append(" more", to: watchedFileURL)
            return recorder.changeCount > 0 || !recorder.failures.isEmpty
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

        // Retries: 3 × 100ms = ~300ms floor, but main-queue scheduling
        // under load can easily push this past 1s. 3s gives enough
        // headroom that CI flakes are caused by real bugs, not by the
        // test being tighter than the code it's exercising.
        try await waitUntil(timeout: .seconds(3)) {
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

}
