import Foundation
import Testing
@testable import ClaudeCodeVoice

@MainActor
private final class FakeTranscriptFileWatcher: TranscriptFileWatching {
    private var onChange: (@MainActor @Sendable () -> Void)?

    func startWatching(
        fileURL: URL,
        onChange: @escaping @MainActor @Sendable () -> Void,
        onFailure: @escaping @MainActor @Sendable (TranscriptFileWatcherError) -> Void
    ) {
        self.onChange = onChange
    }

    func stop() {
        onChange = nil
    }

    func emitChange() {
        onChange?()
    }
}

struct AppModelTests {
    @Test
    @MainActor
    func transcriptFailurePreservesLastKnownMessages() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-1.jsonl", isDirectory: false)
        let watcher = FakeTranscriptFileWatcher()
        let defaultsSuiteName = "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))

        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try initialTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        defer {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
            try? fileManager.removeItem(at: temporaryRoot)
        }

        // Pass a test-scoped Keychain service so AppModel.init doesn't
        // read from the real app's Keychain item. Without this, every
        // `swift test` run prompts "swiftpm-testing-helper wants to
        // access local.claudecodevoice" because the test binary's
        // identity doesn't match the real app's ACL.
        let model = AppModel(
            storageService: ClaudeStorageService(projectsRoot: projectsRoot),
            speechController: SpeechController(),
            userDefaults: userDefaults,
            selectedTranscriptWatcher: watcher,
            keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)")
        )

        await model.start()

        let firstSession = try #require(model.sessions.first)
        model.selectedSessionID = firstSession.id
        try await Task.sleep(for: .milliseconds(250))

        let selectedSessionID = try #require(model.selectedSessionID)
        let originalMessages = model.transcriptState.messages(for: selectedSessionID)
        #expect(originalMessages.count == 2)

        try fileManager.removeItem(at: transcriptURL)
        watcher.emitChange()
        try await Task.sleep(for: .milliseconds(250))

        #expect(model.transcriptState.messages(for: selectedSessionID) == originalMessages)
        #expect(model.transcriptState.errorMessage(for: selectedSessionID)?.contains("Unable to load transcript") == true)
        #expect(model.errorMessage == nil)
    }

    private var initialTranscript: String {
        """
        {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-1","cwd":"/Users/malo/Code/demo-project","message":{"role":"user","content":"Please review this branch."}}
        {"type":"assistant","uuid":"assistant-1","timestamp":"2026-04-17T17:00:01Z","sessionId":"session-1","message":{"role":"assistant","content":[{"type":"text","text":"Happy to."}]}}
        """
    }
}
