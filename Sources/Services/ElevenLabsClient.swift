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

// HTTP client for ElevenLabs TTS. PCM-only output (`pcm_44100`) because
// that's what StreamingAudioPlayer consumes directly. If we ever need
// MP3 output (non-streaming path, voice preview, etc.) we can add it
// as a parameter; deliberately not premature.
struct ElevenLabsClient: ElevenLabsClientType {
    static let defaultBaseURL = URL(string: "https://api.elevenlabs.io")!
    static let pcmOutputFormat = "pcm_44100"
    static let pcmSampleRate: Double = 44_100
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
                switch status {
                case 401, 403:
                    return "ElevenLabs rejected the API key (\(status))."
                case 404:
                    return "ElevenLabs voice or model not found (\(status))."
                case 429:
                    return "ElevenLabs rate limit hit. \(message)"
                default:
                    return "ElevenLabs request failed (\(status)). \(message)"
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
                        if Task.isCancelled { break }
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

        var body: [String: Any] = [
            "text": text,
            "model_id": modelID,
            "voice_settings": [
                "speed": speed,
            ],
        ]
        // Belt-and-suspenders — the Kit's observations indicated some
        // tenants prefer output_format in the body too.
        body["output_format"] = Self.pcmOutputFormat

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
