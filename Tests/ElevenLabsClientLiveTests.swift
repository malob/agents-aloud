import Foundation
import Testing
@testable import ClaudeCodeVoice

// Live integration tests that hit the real ElevenLabs API. Skipped unless
// ELEVENLABS_API_KEY is set in the environment — so `swift test` in
// CI / clean checkouts doesn't fail or leak spend.
//
// Run with:
//   ELEVENLABS_API_KEY=sk-... swift test --filter ElevenLabsClientLiveTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] != nil))
struct ElevenLabsClientLiveTests {
    private var client: ElevenLabsClient {
        let apiKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? ""
        return ElevenLabsClient(apiKey: apiKey)
    }

    @Test
    func listsAtLeastOneVoice() async throws {
        let voices = try await client.listVoices()
        #expect(!voices.isEmpty)
        #expect(voices.allSatisfy { !$0.voiceID.isEmpty && !$0.name.isEmpty })
    }

    @Test
    func streamSynthesizeProducesPCMBytes() async throws {
        let voices = try await client.listVoices()
        let voice = try #require(voices.first)

        let stream = client.streamSynthesize(
            voiceID: voice.voiceID,
            text: "Hello from the integration test.",
            speed: 1.0,
            modelID: "eleven_turbo_v2_5"
        )

        var totalBytes = 0
        for try await chunk in stream {
            totalBytes += chunk.count
        }

        // PCM 44.1kHz 16-bit ≈ 88KB/sec. A short phrase should produce
        // at least 20KB of audio — anything less suggests a malformed
        // or empty response.
        #expect(totalBytes > 20_000)
    }
}
