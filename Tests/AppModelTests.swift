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

// Factored helper: makeTestAppModel returns a fully-wired AppModel with
// test-scoped temp dirs, fake watcher, fake speech drivers, and unique
// UserDefaults + Keychain services so parallel tests don't collide.
@MainActor
private struct TestAppModelFixture {
    let model: AppModel
    let watcher: FakeTranscriptFileWatcher
    let avDriver: FakeSpeechBackendDriver
    let systemDriver: FakeSpeechBackendDriver
    let projectsRoot: URL
    let temporaryRoot: URL
    let userDefaultsSuite: String
    let userDefaults: UserDefaults

    func cleanup() {
        userDefaults.removePersistentDomain(forName: userDefaultsSuite)
        try? FileManager.default.removeItem(at: temporaryRoot)
    }
}

@MainActor
private func makeTestAppModel(
    transcripts: [String: String] = [:]
) throws -> TestAppModelFixture {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)", isDirectory: true)
    let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
    let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
    try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

    for (name, contents) in transcripts {
        let transcriptURL = projectDirectory.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    let defaultsSuiteName = "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
    let watcher = FakeTranscriptFileWatcher()
    let avDriver = FakeSpeechBackendDriver(
        availableVoices: [SpeechVoiceOption(id: "av.voice", name: "AV", language: "en-US", quality: .enhanced)]
    )
    let systemDriver = FakeSpeechBackendDriver(wordsPerMinute: 400)
    let speechController = SpeechController(
        avSpeechDriver: avDriver,
        systemVoiceDriver: systemDriver
    )
    let model = AppModel(
        storageService: ClaudeStorageService(projectsRoot: projectsRoot),
        speechController: speechController,
        userDefaults: userDefaults,
        selectedTranscriptWatcher: watcher,
        keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)")
    )

    return TestAppModelFixture(
        model: model,
        watcher: watcher,
        avDriver: avDriver,
        systemDriver: systemDriver,
        projectsRoot: projectsRoot,
        temporaryRoot: temporaryRoot,
        userDefaultsSuite: defaultsSuiteName,
        userDefaults: userDefaults
    )
}

private let fourMessageTranscript = """
{"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-1","cwd":"/Users/malo/Code/demo-project","message":{"role":"user","content":"First question."}}
{"type":"assistant","uuid":"assistant-1","timestamp":"2026-04-17T17:00:01Z","sessionId":"session-1","message":{"role":"assistant","content":[{"type":"text","text":"Reply one."}]}}
{"type":"user","uuid":"user-2","timestamp":"2026-04-17T17:00:02Z","sessionId":"session-1","message":{"role":"user","content":"Second question."}}
{"type":"assistant","uuid":"assistant-2","timestamp":"2026-04-17T17:00:03Z","sessionId":"session-1","message":{"role":"assistant","content":[{"type":"text","text":"Reply two."}]}}
"""

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

        // Wait for the async refreshTranscript kicked off by selectedSessionID.didSet.
        try await waitUntil { model.transcriptState.messages(for: firstSession.id).count == 2 }

        let selectedSessionID = try #require(model.selectedSessionID)
        let originalMessages = model.transcriptState.messages(for: selectedSessionID)

        try fileManager.removeItem(at: transcriptURL)
        watcher.emitChange()

        // Wait for the file-read error to propagate into .failed state.
        try await waitUntil {
            model.transcriptState.errorMessage(for: selectedSessionID) != nil
        }

        #expect(model.transcriptState.messages(for: selectedSessionID) == originalMessages)
        #expect(model.transcriptState.errorMessage(for: selectedSessionID)?.contains("Unable to load transcript") == true)
        #expect(model.errorMessage == nil)
    }

    // MARK: - playMessagesFromHere

    @Test
    @MainActor
    func playMessagesFromHereStartingAtAssistantPlaysAllSubsequentAssistants() async throws {
        let fixture = try makeTestAppModel(transcripts: ["session-1.jsonl": fourMessageTranscript])
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let firstAssistant = try #require(messages.first(where: { $0.id == "assistant-1" }))

        fixture.model.playMessagesFromHere(firstAssistant)

        // Both assistant messages should be driven: first via playNow (started),
        // second via enqueue (started once first finishes). The fake driver
        // doesn't auto-finish, so only the first reaches the driver.
        #expect(fixture.avDriver.startedRequests.map(\.messageID) == ["assistant-1"])
        // But SpeechController's currentMessageID should be the first; after
        // we emit didFinish, the second should start.
        #expect(fixture.model.speechController.currentMessageID == "assistant-1")

        fixture.avDriver.emit(.didFinish(fixture.avDriver.startedRequests[0].playbackID))

        #expect(fixture.avDriver.startedRequests.map(\.messageID) == ["assistant-1", "assistant-2"])
    }

    @Test
    @MainActor
    func playMessagesFromHereStartingAtUserSkipsToNextAssistant() async throws {
        let fixture = try makeTestAppModel(transcripts: ["session-1.jsonl": fourMessageTranscript])
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let secondUser = try #require(messages.first(where: { $0.id == "user-2" }))

        fixture.model.playMessagesFromHere(secondUser)

        // user-2 should be skipped; assistant-2 is the first speakable
        // message at-or-after the anchor.
        #expect(fixture.avDriver.startedRequests.map(\.messageID) == ["assistant-2"])
    }

    @Test
    @MainActor
    func playMessagesFromHereWithNoSubsequentAssistantsIsNoOp() async throws {
        let fixture = try makeTestAppModel(transcripts: ["session-1.jsonl": fourMessageTranscript])
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let lastAssistant = try #require(messages.first(where: { $0.id == "assistant-2" }))

        fixture.model.playMessagesFromHere(lastAssistant)

        // Last assistant plays; nothing queued after.
        #expect(fixture.avDriver.startedRequests.map(\.messageID) == ["assistant-2"])

        fixture.avDriver.emit(.didFinish(fixture.avDriver.startedRequests[0].playbackID))
        // Still only one started — queue drained.
        #expect(fixture.avDriver.startedRequests.count == 1)
    }

    // MARK: - Backend switch voice preference preservation (regression lock)

    @Test
    @MainActor
    func switchingBackendDoesNotClobberPreferredVoiceIdentifier() async throws {
        let fixture = try makeTestAppModel()
        defer { fixture.cleanup() }

        fixture.model.preferredVoiceIdentifier = "av.voice"
        fixture.model.preferredElevenLabsVoiceID = "11l.voice"

        fixture.model.preferredSpeechBackend = .systemVoice
        #expect(fixture.model.preferredVoiceIdentifier == "av.voice")
        #expect(fixture.model.preferredElevenLabsVoiceID == "11l.voice")

        fixture.model.preferredSpeechBackend = .elevenLabs
        #expect(fixture.model.preferredVoiceIdentifier == "av.voice")
        #expect(fixture.model.preferredElevenLabsVoiceID == "11l.voice")

        fixture.model.preferredSpeechBackend = .avSpeech
        #expect(fixture.model.preferredVoiceIdentifier == "av.voice")
    }

    // MARK: - currentVoiceIdentifier backend routing

    @Test
    @MainActor
    func currentVoiceIdentifierRoutesThroughActiveBackendDriver() async throws {
        let fixture = try makeTestAppModel()
        defer { fixture.cleanup() }

        fixture.model.preferredVoiceIdentifier = "av.voice"
        fixture.model.preferredElevenLabsVoiceID = "explicit.eleven"

        fixture.model.preferredSpeechBackend = .avSpeech
        #expect(fixture.model.currentVoiceIdentifier == "av.voice")

        fixture.model.preferredSpeechBackend = .systemVoice
        #expect(fixture.model.currentVoiceIdentifier == nil)

        fixture.model.preferredSpeechBackend = .elevenLabs
        // ElevenLabs driver has no voices in tests; resolveVoiceIdentifier
        // falls back to availableVoices.first which is nil, meaning
        // currentVoiceIdentifier returns nil when voices haven't loaded.
        // That's the contract: a first-time user without voices loaded
        // gets nil (which would throw noVoiceSelected at the driver).
        #expect(fixture.model.currentVoiceIdentifier == nil)
    }

    // MARK: - Fixtures

    private var initialTranscript: String {
        """
        {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-1","cwd":"/Users/malo/Code/demo-project","message":{"role":"user","content":"Please review this branch."}}
        {"type":"assistant","uuid":"assistant-1","timestamp":"2026-04-17T17:00:01Z","sessionId":"session-1","message":{"role":"assistant","content":[{"type":"text","text":"Happy to."}]}}
        """
    }
}
