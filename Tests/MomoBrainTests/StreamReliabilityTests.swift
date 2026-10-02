import Foundation
import MomoKit
import Testing

@testable import MomoBrain

/// The reply text that arrived, and the error the stream ended with, if any.
private func reply(
    from stream: AsyncThrowingStream<ChatEvent, any Error>
) async -> (text: String, error: (any Error)?) {
    var text = ""
    do {
        for try await event in stream {
            if case .text(let chunk) = event { text += chunk }
        }
    } catch {
        return (text, error)
    }
    return (text, nil)
}

private let question = ChatRequest(systemPrompt: "", turns: [.init(role: .user, text: "hi")])

private func noTool(_ call: ToolCall) async -> ToolResult {
    ToolResult(callID: call.id, name: call.name, output: "")
}

private func openAI(host: String, session: URLSession) throws -> OpenAICompatibleProvider {
    OpenAICompatibleProvider(
        info: ProviderInfo(id: "test", name: "Test", kind: .apiKey),
        baseURL: try #require(URL(string: "https://\(host)/v1")), model: "m", apiKey: "k",
        session: session)
}

@Suite("Streams that end early")
struct StreamEndTests {
    @Test("a Claude stream without message_stop is an error, not a finished answer")
    func truncatedAnthropicStream() async throws {
        let body = sse(
            [
                #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Half an"}}"#,
            ], named: ["content_block_start", "content_block_delta"])
        let (session, host) = MockURLProtocol.session(responses: [.init(body: body)])
        let provider = AnthropicProvider(
            apiKey: "k", session: session,
            endpoint: try #require(URL(string: "https://\(host)/v1/messages")))
        let result = await reply(from: provider.respond(to: question, runTool: noTool))
        #expect(result.text == "Half an")
        #expect(result.error as? ProviderError == ProviderError(streamEndedEarlyMessage))
    }

    @Test("an OpenAI-compatible stream without [DONE] or a finish reason is an error")
    func truncatedOpenAIStream() async throws {
        let body = sse([#"{"choices":[{"delta":{"content":"Half an"}}]}"#])
        let (session, host) = MockURLProtocol.session(responses: [.init(body: body)])
        let provider = try openAI(host: host, session: session)
        let result = await reply(from: provider.respond(to: question, runTool: noTool))
        #expect(result.text == "Half an")
        #expect(result.error as? ProviderError == ProviderError(streamEndedEarlyMessage))
    }

    @Test("a finish reason without [DONE] ends the answer, as some local servers do")
    func finishReasonWithoutDone() async throws {
        let body = sse([
            #"{"choices":[{"delta":{"content":"All done."},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
        ])
        let (session, host) = MockURLProtocol.session(responses: [.init(body: body)])
        let provider = try openAI(host: host, session: session)
        let result = await reply(from: provider.respond(to: question, runTool: noTool))
        #expect(result.error == nil)
        #expect(result.text == "All done.")
    }

    @Test("says so when the answer hit the length limit or a content filter")
    func finishReasonNotes() async throws {
        for (reason, note) in [
            ("length", answerTooLongNotice), ("content_filter", "content filter"),
        ] {
            let body = sse([
                #"{"choices":[{"delta":{"content":"Partial"},"finish_reason":"\#(reason)"}]}"#,
                "[DONE]",
            ])
            let (session, host) = MockURLProtocol.session(responses: [.init(body: body)])
            let provider = try openAI(host: host, session: session)
            let result = await reply(from: provider.respond(to: question, runTool: noTool))
            #expect(result.error == nil)
            #expect(result.text.hasPrefix("Partial\n\n("))
            #expect(result.text.contains(note))
        }
    }
}

@Suite("Retrying temporary HTTP errors")
struct RetryTests {
    private let waits = LockedBox<[Duration]>([])

    private var policy: HTTP.RetryPolicy {
        let waits = waits
        return HTTP.RetryPolicy(sleep: { waits.append($0) })
    }

    private func lines(
        _ responses: [MockURLProtocol.Response]
    ) async throws -> (lines: [String], requests: Int) {
        let (session, host) = MockURLProtocol.session(responses: responses)
        let url = try #require(URL(string: "https://\(host)/v1/messages"))
        var lines: [String] = []
        for try await line in try await HTTP.streamLines(
            session: session, url: url, headers: [:], body: [:], retry: policy)
        {
            lines.append(line)
        }
        return (lines, MockURLProtocol.requestBodies(host: host).count)
    }

    @Test("retries an overloaded provider once, then streams the answer")
    func overloadedThenOK() async throws {
        let result = try await lines([
            .init(status: 529, body: #"{"error":{"message":"Overloaded"}}"#),
            .init(body: "data: ok\n"),
        ])
        #expect(result.lines == ["data: ok"])
        #expect(result.requests == 2)
        let wait = try #require(waits.value.first)
        #expect(waits.value.count == 1)
        #expect(wait >= .milliseconds(500) && wait <= .seconds(1))
    }

    @Test("waits as long as Retry-After or retry-after-ms asks")
    func honoursRetryAfter() async throws {
        let result = try await lines([
            .init(status: 429, body: "slow down", headers: ["Retry-After": "7"]),
            .init(status: 503, body: "busy", headers: ["retry-after-ms": "1500"]),
            .init(body: "data: ok\n"),
        ])
        #expect(result.lines == ["data: ok"])
        #expect(waits.value == [.seconds(7), .milliseconds(1500)])
    }

    @Test("reads Retry-After as an HTTP date")
    func retryAfterDate() throws {
        let url = try #require(URL(string: "https://example.test"))
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "Wed, 21 Oct 2015 07:28:10 GMT"]))
        let now = Date(timeIntervalSince1970: 1_445_412_480)  // 07:28:00 GMT
        #expect(HTTP.retryAfter(in: response, now: now) == .seconds(10))
    }

    @Test("gives up when the provider asks to wait too long, and says how long")
    func retryAfterTooLong() async throws {
        do {
            _ = try await lines([
                .init(status: 429, body: "quota", headers: ["Retry-After": "120"]),
                .init(body: "data: ok\n"),
            ])
            Issue.record("expected an error")
        } catch let error as ProviderError {
            #expect(error.message.contains("(429)"))
            #expect(error.message.contains("wait 120 seconds"))
        }
        #expect(waits.value.isEmpty)
    }

    @Test("stops after three attempts")
    func givesUp() async throws {
        await #expect(throws: ProviderError.self) {
            _ = try await lines(Array(repeating: .init(status: 503, body: "busy"), count: 4))
        }
        #expect(waits.value.count == 2)
    }

    @Test("doesn't retry errors that won't go away")
    func badRequestNotRetried() async throws {
        let (session, host) = MockURLProtocol.session(responses: [
            .init(status: 400, body: #"{"error":{"message":"Bad"}}"#), .init(body: "data: ok\n"),
        ])
        let url = try #require(URL(string: "https://\(host)/v1/messages"))
        await #expect(throws: ProviderError.self) {
            _ = try await HTTP.streamLines(
                session: session, url: url, headers: [:], body: [:], retry: policy)
        }
        #expect(MockURLProtocol.requestBodies(host: host).count == 1)
        #expect(waits.value.isEmpty)
    }

    @Test("doesn't retry once the answer has started arriving")
    func noRetryAfterBytes() async throws {
        let (session, host) = MockURLProtocol.session(responses: [
            .init(body: "data: first\n", failsAfterBody: true), .init(body: "data: again\n"),
        ])
        let url = try #require(URL(string: "https://\(host)/v1/messages"))
        let stream = try await HTTP.streamLines(
            session: session, url: url, headers: [:], body: [:], retry: policy)
        var received: [String] = []
        await #expect(throws: (any Error).self) {
            for try await line in stream { received.append(line) }
        }
        #expect(!received.contains("data: again"))
        #expect(MockURLProtocol.requestBodies(host: host).count == 1)
        #expect(waits.value.isEmpty)
    }
}
