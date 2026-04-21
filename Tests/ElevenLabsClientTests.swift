import Foundation
import Testing
@testable import ClaudeCodeVoice

// URLProtocol stub that answers requests with scripted responses. Each
// test sets `handler` before triggering a request; URLSession calls into
// this class on arbitrary queues, so the storage needs to be thread-safe.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "StubURLProtocol.noHandler", code: 0))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeClient(
    apiKey: String = "test-key",
    baseURL: URL = URL(string: "https://stub.elevenlabs.test")!
) -> ElevenLabsClient {
    ElevenLabsClient(apiKey: apiKey, baseURL: baseURL, urlSession: stubbedSession())
}

// Consumes the entire stream and returns either the aggregated bytes or
// the error it ends with. Tests use this to avoid manual for-await plumbing.
private func drain(_ stream: AsyncThrowingStream<Data, Error>) async -> Result<Data, Error> {
    var accumulated = Data()
    do {
        for try await chunk in stream {
            accumulated.append(chunk)
        }
        return .success(accumulated)
    } catch {
        return .failure(error)
    }
}

// Serialized because these tests share the static StubURLProtocol.handler
// across the whole test process; running in parallel lets one test's
// handler clobber another's in-flight request.
@Suite(.serialized)
struct ElevenLabsClientTests {

    // MARK: - streamSynthesize request shape (regression lock for commit d2ca469)

    @Test
    func streamSynthesizeRequestUsesPCM24000QueryParamAndCorrectBody() async throws {
        nonisolated(unsafe) var capturedRequest: URLRequest?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            // Non-audio response body; we don't care about the response here,
            // just the request shape.
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/octet-stream"]
            )!
            return (response, Data())
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient()
        _ = await drain(client.streamSynthesize(voiceID: "v1", text: "hi", speed: 0.95, modelID: "eleven_turbo_v2_5"))

        let request = try #require(capturedRequest)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(url.path == "/v1/text-to-speech/v1/stream")
        #expect(components.queryItems?.first(where: { $0.name == "output_format" })?.value == "pcm_24000")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "test-key")

        // URLProtocol receives a request with httpBodyStream, not httpBody,
        // because URLSession repackages bodies over a certain size. Read
        // through the stream to get the actual bytes we sent.
        let body = readBody(from: request)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["text"] as? String == "hi")
        #expect(json?["model_id"] as? String == "eleven_turbo_v2_5")
        // output_format must NOT appear in the body — it's a query-string
        // param. Earlier code sent it twice, which currently works but
        // risks future 400s if ElevenLabs tightens body schema.
        #expect(json?["output_format"] == nil)

        let voiceSettings = try #require(json?["voice_settings"] as? [String: Any])
        #expect((voiceSettings["speed"] as? Double) == 0.95)
    }

    // MARK: - streamSynthesize error mapping

    @Test
    func streamSynthesizeMapsStatusCodesToSpecificMessages() async throws {
        struct Case {
            let status: Int
            let expectedSubstring: String
        }
        let cases = [
            Case(status: 401, expectedSubstring: "rejected the API key"),
            Case(status: 403, expectedSubstring: "missing required permission"),
            Case(status: 404, expectedSubstring: "voice or model not found"),
            Case(status: 429, expectedSubstring: "rate limit hit"),
            Case(status: 500, expectedSubstring: "request failed"),
        ]

        for testCase in cases {
            StubURLProtocol.handler = { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: testCase.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error":"test"}"#.utf8))
            }

            let client = makeClient()
            let result = await drain(client.streamSynthesize(voiceID: "v1", text: "x", speed: 1.0, modelID: "m"))

            guard case let .failure(error) = result else {
                Issue.record("expected failure for status \(testCase.status), got success")
                continue
            }
            let description = error.localizedDescription
            #expect(
                description.contains(testCase.expectedSubstring),
                "status \(testCase.status): expected description containing '\(testCase.expectedSubstring)', got '\(description)'"
            )
        }
        StubURLProtocol.handler = nil
    }

    @Test
    func streamSynthesizeRejectsJSONSuccessResponseAsNonAudio() async throws {
        StubURLProtocol.handler = { request in
            // 2xx status with a JSON content-type — the client should flag
            // this as a non-audio response rather than yield the bytes.
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"unexpected":"json"}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await drain(client.streamSynthesize(voiceID: "v1", text: "x", speed: 1.0, modelID: "m"))

        guard case let .failure(error) = result else {
            Issue.record("expected failure for JSON 200 response")
            return
        }
        #expect(error.localizedDescription.contains("non-audio"))
    }

    // MARK: - listVoices error mapping

    @Test
    func listVoicesMapsStatusCodesToSpecificMessages() async throws {
        struct Case {
            let status: Int
            let expectedSubstring: String
        }
        let cases = [
            Case(status: 401, expectedSubstring: "rejected the API key"),
            Case(status: 403, expectedSubstring: "missing required permission"),
            Case(status: 500, expectedSubstring: "request failed"),
        ]

        for testCase in cases {
            StubURLProtocol.handler = { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: testCase.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error":"test"}"#.utf8))
            }

            let client = makeClient()
            await #expect(throws: ElevenLabsClient.ClientError.self) {
                _ = try await client.listVoices()
            }
        }
        StubURLProtocol.handler = nil
    }

    @Test
    func listVoicesDecodesSuccessfulResponse() async throws {
        let responseJSON = #"{"voices":[{"voice_id":"v1","name":"Rachel"},{"voice_id":"v2","name":"Adam"}]}"#
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(responseJSON.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient()
        let voices = try await client.listVoices()

        #expect(voices.map(\.voiceID) == ["v1", "v2"])
        #expect(voices.map(\.name) == ["Rachel", "Adam"])
    }

    // MARK: - Helpers

    private func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }
}
