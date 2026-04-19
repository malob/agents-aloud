import Foundation
import Testing
@testable import ClaudeCodeVoice

// @unchecked Sendable: mutable fields are only touched from the
// @MainActor-isolated test bodies in this file.
private final class FakeElevenLabsClient: ElevenLabsClientType, @unchecked Sendable {
    var voicesToReturn: [ElevenLabsVoice] = []
    var listVoicesError: Error?

    private(set) var synthesizeCalls: [(voiceID: String, text: String, speed: Double, modelID: String)] = []
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    func streamSynthesize(
        voiceID: String,
        text: String,
        speed: Double,
        modelID: String
    ) -> AsyncThrowingStream<Data, Error> {
        synthesizeCalls.append((voiceID, text, speed, modelID))
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func listVoices() async throws -> [ElevenLabsVoice] {
        if let listVoicesError {
            throw listVoicesError
        }
        return voicesToReturn
    }

    // Test helpers — drive the synthetic stream from the test body.
    func yield(_ data: Data) {
        continuation?.yield(data)
    }

    func finishStream() {
        continuation?.finish()
    }

    func failStream(_ error: Error) {
        continuation?.finish(throwing: error)
    }
}

@MainActor
private final class EventRecorder {
    private(set) var events: [SpeechDriverEvent] = []

    var handler: @MainActor @Sendable (SpeechDriverEvent) -> Void {
        { [weak self] event in
            self?.events.append(event)
        }
    }
}

struct ElevenLabsBackendDriverTests {
    private func silencePCM(milliseconds: Int) -> Data {
        let sampleCount = (44_100 * milliseconds) / 1000
        let zeros = [Int16](repeating: 0, count: sampleCount)
        return zeros.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    @Test
    @MainActor
    func refreshVoicesPopulatesAvailableVoices() async throws {
        let client = FakeElevenLabsClient()
        client.voicesToReturn = [
            ElevenLabsVoice(voiceID: "v1", name: "Rachel"),
            ElevenLabsVoice(voiceID: "v2", name: "Adam"),
        ]
        let driver = ElevenLabsBackendDriver(client: client)

        await driver.refreshVoices()

        #expect(driver.availableVoices.map(\.id) == ["v1", "v2"])
        #expect(driver.availableVoices.map(\.name) == ["Rachel", "Adam"])
    }

    @Test
    @MainActor
    func refreshVoicesReturnsEmptyListOnError() async throws {
        let client = FakeElevenLabsClient()
        client.listVoicesError = NSError(domain: "test", code: 401)
        let driver = ElevenLabsBackendDriver(client: client)

        await driver.refreshVoices()
        #expect(driver.availableVoices.isEmpty)
    }

    @Test
    @MainActor
    func startWithoutVoiceIdentifierThrows() {
        let client = FakeElevenLabsClient()
        let driver = ElevenLabsBackendDriver(client: client)
        let recorder = EventRecorder()
        let request = SpeechRequest(
            playbackID: UUID(),
            messageID: "m",
            text: "hello",
            voiceIdentifier: nil,
            rate: 0.4
        )

        #expect(throws: ElevenLabsBackendDriver.DriverError.self) {
            try driver.start(request: request, eventHandler: recorder.handler)
        }
        #expect(recorder.events.isEmpty)
    }

    @Test
    @MainActor
    func startEmitsDidStartAndCallsClientWithMappedSpeed() throws {
        let client = FakeElevenLabsClient()
        let driver = ElevenLabsBackendDriver(client: client)
        let recorder = EventRecorder()
        let playbackID = UUID()
        let request = SpeechRequest(
            playbackID: playbackID,
            messageID: "m",
            text: "hello",
            voiceIdentifier: "v1",
            rate: 0.4  // middle of AVSpeech range -> ~1.25x ElevenLabs speed
        )

        try driver.start(request: request, eventHandler: recorder.handler)

        #expect(recorder.events == [.didStart(playbackID)])
        #expect(client.synthesizeCalls.count == 1)
        #expect(client.synthesizeCalls[0].voiceID == "v1")
        #expect(client.synthesizeCalls[0].text == "hello")
        #expect(client.synthesizeCalls[0].modelID == ElevenLabsBackendDriver.defaultModelID)
        // 0.4 maps to 1.25 per the documented linear mapping
        #expect(abs(client.synthesizeCalls[0].speed - 1.25) < 0.001)

        driver.stop()
    }

    @Test
    @MainActor
    func pauseAndResumeEmitMatchingEvents() throws {
        let client = FakeElevenLabsClient()
        let driver = ElevenLabsBackendDriver(client: client)
        let recorder = EventRecorder()
        let playbackID = UUID()
        let request = SpeechRequest(
            playbackID: playbackID,
            messageID: "m",
            text: "hello",
            voiceIdentifier: "v1",
            rate: 0.4
        )

        try driver.start(request: request, eventHandler: recorder.handler)
        client.yield(silencePCM(milliseconds: 500))

        driver.pause()
        driver.resume()

        #expect(recorder.events.contains(.didPause(playbackID)))
        #expect(recorder.events.contains(.didResume(playbackID)))

        driver.stop()
    }

    @Test
    @MainActor
    func streamFinishEmitsDidFinish() async throws {
        let client = FakeElevenLabsClient()
        let driver = ElevenLabsBackendDriver(client: client)
        let recorder = EventRecorder()
        let playbackID = UUID()
        let request = SpeechRequest(
            playbackID: playbackID,
            messageID: "m",
            text: "hi",
            voiceIdentifier: "v1",
            rate: 0.4
        )

        try driver.start(request: request, eventHandler: recorder.handler)
        client.yield(silencePCM(milliseconds: 50))
        client.finishStream()

        // Wait for audio-thread callback to complete draining + finish event to fire
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            if recorder.events.contains(where: { if case .didFinish = $0 { return true } else { return false } }) {
                break
            }
        }

        #expect(recorder.events.contains(.didFinish(playbackID)))
    }

    @Test
    @MainActor
    func streamErrorEmitsDidFail() async throws {
        struct SyntheticError: LocalizedError, Equatable {
            var errorDescription: String? { "synthetic failure" }
        }

        let client = FakeElevenLabsClient()
        let driver = ElevenLabsBackendDriver(client: client)
        let recorder = EventRecorder()
        let playbackID = UUID()
        let request = SpeechRequest(
            playbackID: playbackID,
            messageID: "m",
            text: "hi",
            voiceIdentifier: "v1",
            rate: 0.4
        )

        try driver.start(request: request, eventHandler: recorder.handler)
        client.yield(silencePCM(milliseconds: 20))
        client.failStream(SyntheticError())

        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            if recorder.events.contains(where: { if case .didFail = $0 { return true } else { return false } }) {
                break
            }
        }

        let failEvent = recorder.events.first { if case .didFail = $0 { return true } else { return false } }
        if case let .didFail(id, description) = failEvent {
            #expect(id == playbackID)
            #expect(description.contains("synthetic"))
        } else {
            Issue.record("expected .didFail event, got \(recorder.events)")
        }
    }

    @Test
    func rateMappingIsLinearOverSliderRange() {
        // At 0.2 (slider min) -> speed 0.5
        #expect(abs(ElevenLabsBackendDriver.mapRateToSpeed(0.2) - 0.5) < 0.001)
        // At 0.4 (middle) -> speed 1.25
        #expect(abs(ElevenLabsBackendDriver.mapRateToSpeed(0.4) - 1.25) < 0.001)
        // At 0.6 (slider max) -> speed 2.0
        #expect(abs(ElevenLabsBackendDriver.mapRateToSpeed(0.6) - 2.0) < 0.001)
        // Out-of-range clamps
        #expect(ElevenLabsBackendDriver.mapRateToSpeed(0.0) == 0.5)
        #expect(ElevenLabsBackendDriver.mapRateToSpeed(1.0) == 2.0)
    }
}
