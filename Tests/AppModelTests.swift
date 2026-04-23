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
    transcripts: [String: String] = [:],
    speechTextProcessor: any SpeechTextProcessor = PassthroughSpeechProcessor()
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
        keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"),
        speechTextProcessor: speechTextProcessor
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
        // Wait for the async processing + playNow to land.
        try await waitUntil { fixture.avDriver.startedRequests.map(\.messageID) == ["assistant-1"] }
        // And the next message must have been enqueued before we emit didFinish.
        try await waitUntil { fixture.model.speechController.currentMessageID == "assistant-1" }

        fixture.avDriver.emit(.didFinish(fixture.avDriver.startedRequests[0].playbackID))

        try await waitUntil {
            fixture.avDriver.startedRequests.map(\.messageID) == ["assistant-1", "assistant-2"]
        }
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
        try await waitUntil { fixture.avDriver.startedRequests.map(\.messageID) == ["assistant-2"] }
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
        try await waitUntil { fixture.avDriver.startedRequests.map(\.messageID) == ["assistant-2"] }

        fixture.avDriver.emit(.didFinish(fixture.avDriver.startedRequests[0].playbackID))
        // Still only one started — queue drained.
        #expect(fixture.avDriver.startedRequests.count == 1)
    }

    // MARK: - Live Speak on empty session

    @Test
    @MainActor
    func liveSpeakOnEmptySessionSpeaksFirstNewAssistantMessage() async throws {
        // Session starts with only a user prompt; the assistant hasn't
        // responded yet. User enables Live Speak, then a new assistant
        // message arrives. The old `!previousIDs.isEmpty` guard would
        // incorrectly skip this first message and mark it "known" forever.
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-1.jsonl", isDirectory: false)
        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

        // Start with a session that has only a user prompt, no assistant reply.
        let initialContent = """
        {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-1","cwd":"/Users/malo/Code/demo-project","message":{"role":"user","content":"Start question."}}
        """
        try initialContent.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let defaultsSuiteName = "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        let watcher = FakeTranscriptFileWatcher()
        let avDriver = FakeSpeechBackendDriver(
            availableVoices: [SpeechVoiceOption(id: "av.voice", name: "AV", language: "en-US", quality: .enhanced)]
        )
        let controller = SpeechController(
            avSpeechDriver: avDriver,
            systemVoiceDriver: FakeSpeechBackendDriver(wordsPerMinute: 400)
        )
        let model = AppModel(
            storageService: ClaudeStorageService(projectsRoot: projectsRoot),
            speechController: controller,
            userDefaults: userDefaults,
            selectedTranscriptWatcher: watcher,
            keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)")
        )
        defer {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
            try? fileManager.removeItem(at: temporaryRoot)
        }

        await model.start()
        let firstSession = try #require(model.sessions.first)
        model.selectedSessionID = firstSession.id
        try await waitUntil { model.transcriptState.messages(for: firstSession.id).count == 1 }

        // Enable Live Speak — seeds knownAssistantMessageIDsBySession
        // with the empty set (no assistant messages yet).
        model.setLiveReadEnabled(true)

        // Append the first assistant reply to the session.
        let assistantLine = "\n{\"type\":\"assistant\",\"uuid\":\"assistant-1\",\"timestamp\":\"2026-04-17T17:00:01Z\",\"sessionId\":\"session-1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"First reply.\"}]}}"
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(assistantLine.utf8))
        try handle.close()

        watcher.emitChange()

        try await waitUntil {
            avDriver.startedRequests.contains(where: { $0.messageID == "assistant-1" })
        }
    }

    // MARK: - isPreparingPlayback flag lifecycle

    @Test
    @MainActor
    func stopPlaybackClearsPreparingFlagImmediately() async throws {
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let first = try #require(messages.first(where: { $0.id == "assistant-1" }))

        fixture.model.playMessage(first)
        try await waitUntil { processor.pendingCount == 1 }
        #expect(fixture.model.isPreparingPlayback)

        fixture.model.stopPlayback()

        // Flag MUST clear synchronously — otherwise the Stop button
        // appears briefly still-enabled after user pressed it.
        #expect(!fixture.model.isPreparingPlayback)

        // Resume the suspended continuation so the prep Task can exit
        // cleanly (its guard `!Task.isCancelled` then bails). Otherwise
        // the Task lingers until process exit, holding references.
        processor.releaseAll()
    }

    @Test
    @MainActor
    func sessionSwitchClearsPreparingFlagImmediately() async throws {
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let first = try #require(messages.first(where: { $0.id == "assistant-1" }))

        fixture.model.playMessage(first)
        try await waitUntil { processor.pendingCount == 1 }
        #expect(fixture.model.isPreparingPlayback)

        fixture.model.selectedSessionID = nil
        #expect(!fixture.model.isPreparingPlayback)

        processor.releaseAll()
    }

    @Test
    @MainActor
    func disablingLiveSpeakClearsPreparingFlagImmediately() async throws {
        // Live Speak disable mid-preprocessing (an assistant message
        // arrived, was about to be enqueued, user turned Live Speak off
        // during the refine). Flag clears immediately so Stop in the
        // toolbar doesn't stick around enabled.
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let first = try #require(messages.first(where: { $0.id == "assistant-1" }))

        fixture.model.setLiveReadEnabled(true)
        fixture.model.playMessage(first)
        try await waitUntil { processor.pendingCount == 1 }
        #expect(fixture.model.isPreparingPlayback)

        fixture.model.setLiveReadEnabled(false)
        #expect(!fixture.model.isPreparingPlayback)

        processor.releaseAll()
    }

    // MARK: - Preprocessing cancellation

    @Test
    @MainActor
    func stopDuringPreprocessingCancelsPendingPlayback() async throws {
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let firstAssistant = try #require(messages.first(where: { $0.id == "assistant-1" }))

        fixture.model.playMessage(firstAssistant)

        // Wait for the processor to start processing the message.
        try await waitUntil { processor.invocationCount == 1 }
        #expect(processor.pendingCount == 1)

        // User presses Stop before processing completes.
        fixture.model.stopPlayback()

        // Release the processor. The pending task should have been
        // cancelled — playNow must NOT be called.
        processor.releaseAll()

        // Give any would-be stale Task time to land if the cancellation
        // didn't take.
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.avDriver.startedRequests.isEmpty)
    }

    @Test
    @MainActor
    func rapidSpeakReclickDoesNotClearPreparingFlagEarly() async throws {
        // When one prep Task completes, the shared isPreparingPlayback
        // flag must stay true as long as another prep Task is still in
        // flight. Under the current concurrent-rewrites model this is
        // natural: each Task removes only its own messageID from the
        // set, so B's membership keeps the set non-empty after A
        // resolves.
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let first = try #require(messages.first(where: { $0.id == "assistant-1" }))
        let second = try #require(messages.first(where: { $0.id == "assistant-2" }))

        fixture.model.playMessage(first)
        try await waitUntil { processor.pendingCount == 1 }
        #expect(fixture.model.isPreparingPlayback)

        // Second click while first is still preparing — both now in
        // flight concurrently.
        fixture.model.playMessage(second)
        try await waitUntil { processor.pendingCount == 2 }
        #expect(fixture.model.isPreparingPlayback)

        // Release the first pending process() call. First's ID leaves
        // the set; second's is still there → flag stays true.
        processor.releaseNext()
        try await waitUntil { fixture.model.preparingMessageIDs == ["assistant-2"] }

        #expect(fixture.model.isPreparingPlayback)
        #expect(processor.pendingCount == 1)

        // Release the second. Set empties, flag clears.
        processor.releaseNext()
        try await waitUntil { !fixture.model.isPreparingPlayback }
    }

    @Test
    @MainActor
    func clickingSpeakOnSecondMessageDoesNotCancelFirstsRewrite() async throws {
        // Regression guard: earlier implementation used a single
        // in-flight preparation Task that playMessage always cancelled
        // at entry — so clicking Speak on B while A was still rewriting
        // dropped A entirely, and only B ever played. Concurrent-rewrite
        // model: both A and B show "Rewriting…", both finish, both
        // play in rewrite-completion order.
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let assistantOne = try #require(messages.first(where: { $0.id == "assistant-1" }))
        let assistantTwo = try #require(messages.first(where: { $0.id == "assistant-2" }))

        fixture.model.playMessage(assistantOne)
        try await waitUntil { processor.pendingCount == 1 }

        #expect(fixture.model.preparingMessageIDs == ["assistant-1"])

        // Click on the second message while the first is still being
        // rewritten. The first must NOT be cancelled — both rows stay
        // marked as preparing.
        fixture.model.playMessage(assistantTwo)
        try await waitUntil { processor.pendingCount == 2 }

        #expect(fixture.model.preparingMessageIDs == ["assistant-1", "assistant-2"])
        #expect(fixture.model.isPreparingPlayback)

        // Release both; both should complete, both should land in the
        // driver queue. Release order == play-order if the controller
        // was idle when the first came out, else head-of-queue for the
        // second.
        processor.releaseAll()
        try await waitUntil { fixture.model.preparingMessageIDs.isEmpty }
    }

    @Test
    @MainActor
    func clickingSpeakOnSameMessageTwiceDoesNotDoubleRewrite() async throws {
        // Dedupe: a second click on a message that's already being
        // rewritten is a no-op. The user's click is interpreted as
        // "I want this spoken," which is already in motion.
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let assistantOne = try #require(
            fixture.model.transcriptState.messages(for: firstSession.id)
                .first(where: { $0.id == "assistant-1" })
        )

        fixture.model.playMessage(assistantOne)
        try await waitUntil { processor.pendingCount == 1 }

        fixture.model.playMessage(assistantOne)
        fixture.model.playMessage(assistantOne)
        // pendingCount MUST stay at 1 — second / third click were
        // deduped, not forwarded to the processor.
        try await Task.sleep(for: .milliseconds(30))
        #expect(processor.pendingCount == 1)

        processor.releaseAll()
        try await waitUntil { fixture.model.preparingMessageIDs.isEmpty }
    }

    @Test
    @MainActor
    func liveSpeakRewritingSurfacesAsPreparingMessageID() async throws {
        // Live Speak has its own rewrite loop inside refreshTranscript
        // (separate from playMessage's prep Task). Without explicit
        // preparingMessageID wiring there, arriving assistant messages
        // would flow straight from file-watcher event → silent rewrite
        // wait → enqueued audio, with zero UI feedback during the
        // 5–10s CLI wait. This test pins that the row gets marked
        // "preparing" for the duration of the rewrite.
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsRoot.appendingPathComponent("demo-project", isDirectory: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-1.jsonl", isDirectory: false)
        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

        let initialContent = """
        {"type":"user","uuid":"user-1","timestamp":"2026-04-17T17:00:00Z","sessionId":"session-1","cwd":"/Users/malo/Code/demo-project","message":{"role":"user","content":"Start question."}}
        """
        try initialContent.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let defaultsSuiteName = "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        let watcher = FakeTranscriptFileWatcher()
        let avDriver = FakeSpeechBackendDriver(
            availableVoices: [SpeechVoiceOption(id: "av.voice", name: "AV", language: "en-US", quality: .enhanced)]
        )
        let controller = SpeechController(
            avSpeechDriver: avDriver,
            systemVoiceDriver: FakeSpeechBackendDriver(wordsPerMinute: 400)
        )
        let processor = ControllableSpeechTextProcessor()
        let model = AppModel(
            storageService: ClaudeStorageService(projectsRoot: projectsRoot),
            speechController: controller,
            userDefaults: userDefaults,
            selectedTranscriptWatcher: watcher,
            keychain: KeychainStorage(service: "ClaudeCodeVoice-AppModelTests-\(UUID().uuidString)"),
            speechTextProcessor: processor
        )
        defer {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
            try? fileManager.removeItem(at: temporaryRoot)
        }

        await model.start()
        let firstSession = try #require(model.sessions.first)
        model.selectedSessionID = firstSession.id
        try await waitUntil { model.transcriptState.messages(for: firstSession.id).count == 1 }

        model.setLiveReadEnabled(true)

        // Append the first assistant reply — live-read should pick it up
        // and call the processor.
        let assistantLine = "\n{\"type\":\"assistant\",\"uuid\":\"assistant-1\",\"timestamp\":\"2026-04-17T17:00:01Z\",\"sessionId\":\"session-1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"First reply.\"}]}}"
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(assistantLine.utf8))
        try handle.close()
        watcher.emitChange()

        // Processor is suspended — we should see the row marked as
        // preparing for the duration of the rewrite.
        try await waitUntil { processor.pendingCount == 1 }
        #expect(model.preparingMessageIDs.contains("assistant-1"))
        #expect(model.isPreparingPlayback)

        // Resolve the rewrite; the label should clear and the message
        // should land in the speech queue.
        processor.releaseAll()
        try await waitUntil { model.preparingMessageIDs.isEmpty }
        try await waitUntil { avDriver.startedRequests.contains(where: { $0.messageID == "assistant-1" }) }
    }

    @Test
    @MainActor
    func preparingMessageIDAdvancesThroughSpeakFromHereQueue() async throws {
        // In playMessagesFromHere the rewrite walks the queue serially
        // while the first message plays. The UI needs to know which
        // row is currently being rewritten so the "Rewriting…" label
        // moves with the head of the queue.
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let assistantOne = try #require(messages.first(where: { $0.id == "assistant-1" }))

        fixture.model.playMessagesFromHere(assistantOne)
        try await waitUntil { processor.pendingCount == 1 }

        #expect(fixture.model.preparingMessageIDs == ["assistant-1"])

        // Release the first; the prep Task then asks the processor to
        // rewrite the second message. Only one of the sequence's
        // messages is marked preparing at a time (serial walk).
        processor.releaseNext()
        try await waitUntil {
            processor.pendingCount == 1 && fixture.model.preparingMessageIDs == ["assistant-2"]
        }

        processor.releaseAll()
        try await waitUntil { fixture.model.preparingMessageIDs.isEmpty }
    }

    @Test
    @MainActor
    func sessionSwitchDuringPreprocessingCancelsPendingPlayback() async throws {
        let processor = ControllableSpeechTextProcessor()
        let fixture = try makeTestAppModel(
            transcripts: ["session-1.jsonl": fourMessageTranscript],
            speechTextProcessor: processor
        )
        defer { fixture.cleanup() }

        await fixture.model.start()
        let firstSession = try #require(fixture.model.sessions.first)
        fixture.model.selectedSessionID = firstSession.id
        try await waitUntil { fixture.model.transcriptState.messages(for: firstSession.id).count == 4 }

        let messages = fixture.model.transcriptState.messages(for: firstSession.id)
        let firstAssistant = try #require(messages.first(where: { $0.id == "assistant-1" }))

        fixture.model.playMessage(firstAssistant)
        try await waitUntil { processor.invocationCount == 1 }

        // User switches away to no selection mid-process.
        fixture.model.selectedSessionID = nil

        processor.releaseAll()
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.avDriver.startedRequests.isEmpty)
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
