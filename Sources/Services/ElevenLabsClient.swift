import Foundation
import OSLog

// Testable surface the driver depends on. Let the real client hit the
// network; let tests inject a fake that emits scripted stream chunks
// and voice lists.
//
// Sendable is required because `listVoices()` is async and may hop
// executors; the compiler needs to know the client reference is safe
// to cross the isolation boundary. Fakes with mutable test-scripting
// state can opt into `@unchecked Sendable` with the understanding that
// they're accessed from a single actor context within a test.
protocol ElevenLabsClientType: Sendable {
    func streamSynthesize(
        voiceID: String,
        text: String,
        speed: Double,
        modelID: String
    ) -> AsyncThrowingStream<Data, Error>

    func listVoices() async throws -> [ElevenLabsVoice]
}

// HTTP client for ElevenLabs TTS. PCM-only output because that's what
// StreamingAudioPlayer consumes directly.
//
// We use `pcm_48000` (48kHz, 16-bit mono) — full-band audio, Nyquist
// comfortably past anything a voice produces. Surprising tier quirk,
// verified empirically against the live API (2026-06, pay-as-you-go
// account): `pcm_44100` is rejected with "Pro tier and above" while
// `pcm_48000` succeeds. Don't "fix" this to 44.1kHz for roundness —
// it's the one that's gated. The app shipped on `pcm_24000` (the
// safe-everywhere format) before this was discovered; if a 403
// `output_format_not_allowed` ever shows up for a lower-tier user,
// fall back to pcm_24000.
// See: https://help.elevenlabs.io/hc/en-us/articles/15754340124305
struct ElevenLabsClient: ElevenLabsClientType {
    static let defaultBaseURL = URL(string: "https://api.elevenlabs.io")!
    static let pcmOutputFormat = "pcm_48000"
    static let pcmSampleRate: Double = 48_000
    static let defaultChunkSize = 4096
    static let requestTimeout: TimeInterval = 30

    let apiKey: String
    let baseURL: URL
    let urlSession: URLSession

    init(
        apiKey: String,
        baseURL: URL = ElevenLabsClient.defaultBaseURL,
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    enum ClientError: LocalizedError, Equatable {
        case invalidResponse
        case http(status: Int, message: String)
        case nonAudioResponse(contentType: String, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "ElevenLabs returned an invalid response."
            case let .http(status, message):
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = trimmed.isEmpty ? "" : " \(trimmed)"
                switch status {
                case 401:
                    return "ElevenLabs rejected the API key (\(status)).\(suffix)"
                case 403:
                    return "ElevenLabs API key missing required permission (\(status)).\(suffix)"
                case 404:
                    return "ElevenLabs voice or model not found (\(status)).\(suffix)"
                case 429:
                    return "ElevenLabs rate limit hit.\(suffix)"
                default:
                    return "ElevenLabs request failed (\(status)).\(suffix)"
                }
            case let .nonAudioResponse(contentType, body):
                return "ElevenLabs returned non-audio content (\(contentType)). \(body)"
            }
        }
    }

    func streamSynthesize(
        voiceID: String,
        text: String,
        speed: Double,
        modelID: String
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let request = try makeSynthesizeRequest(
                        voiceID: voiceID,
                        text: text,
                        speed: speed,
                        modelID: modelID
                    )
                    let (bytes, response) = try await urlSession.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw ClientError.invalidResponse
                    }

                    let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

                    if http.statusCode >= 400 {
                        let body = try await readErrorBody(bytes: bytes)
                        throw ClientError.http(status: http.statusCode, message: body)
                    }

                    // PCM responses come back as application/octet-stream or
                    // audio/* depending on server mood. Anything obviously
                    // text is a malformed response we should surface.
                    if contentType.contains("application/json") || contentType.contains("text/") {
                        let body = try await readErrorBody(bytes: bytes)
                        throw ClientError.nonAudioResponse(contentType: contentType, body: body)
                    }

                    var buffer = Data()
                    buffer.reserveCapacity(Self.defaultChunkSize)
                    for try await byte in bytes {
                        if Task.isCancelled {
                            // Emit a cancellation error rather than a clean
                            // finish — downstream consumers (StreamingAudioPlayer)
                            // would otherwise fire `onFinish` on a truncated
                            // stream, playing partial audio as if complete.
                            throw CancellationError()
                        }
                        buffer.append(byte)
                        if buffer.count >= Self.defaultChunkSize {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func listVoices() async throws -> [ElevenLabsVoice] {
        var url = baseURL
        url.appendPathComponent("v1")
        url.appendPathComponent("voices")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        if http.statusCode >= 400 {
            let body = truncated(String(data: data, encoding: .utf8) ?? "")
            throw ClientError.http(status: http.statusCode, message: body)
        }

        struct VoicesResponse: Decodable { let voices: [ElevenLabsVoice] }
        let decoded = try JSONDecoder().decode(VoicesResponse.self, from: data)
        return decoded.voices
    }

    // MARK: -

    private func makeSynthesizeRequest(
        voiceID: String,
        text: String,
        speed: Double,
        modelID: String
    ) throws -> URLRequest {
        var url = baseURL
        url.appendPathComponent("v1")
        url.appendPathComponent("text-to-speech")
        url.appendPathComponent(voiceID)
        url.appendPathComponent("stream")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "output_format", value: Self.pcmOutputFormat)]
        guard let finalURL = components?.url else {
            throw ClientError.invalidResponse
        }

        let body: [String: Any] = [
            "text": text,
            "model_id": modelID,
            "voice_settings": [
                "speed": speed,
            ],
        ]

        var request = URLRequest(url: finalURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private func readErrorBody(bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        data.reserveCapacity(4096)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 4096 { break }
        }
        return truncated(String(data: data, encoding: .utf8) ?? "")
    }

    private func truncated(_ string: String) -> String {
        let collapsed = string
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(collapsed.prefix(500))
    }
}
