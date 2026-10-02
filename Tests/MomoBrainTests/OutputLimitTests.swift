import Foundation
import MomoKit
import Testing

@testable import MomoBrain

private let question = ChatRequest(systemPrompt: "", turns: [.init(role: .user, text: "hi")])

private let answer = sse(
    [
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        #"{"type":"message_stop"}"#,
    ], named: ["content_block_start", "content_block_delta", "message_delta", "message_stop"])

private let tooLarge = #"""
    {"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: 64000 > 32000, which is the maximum allowed number of output tokens for claude-opus-4-1-20250805"}}
    """#

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

private func noTool(_ call: ToolCall) async -> ToolResult {
    ToolResult(callID: call.id, name: call.name, output: "")
}

private func sentMaxTokens(host: String) throws -> [Int] {
    try MockURLProtocol.requestBodies(host: host).map {
        try #require(JSONValue.parse($0)["max_tokens"]?.intValue)
    }
}

@Suite("Claude output limit")
struct OutputLimitTests {
    @Test(
        "known models get their output limit, up to Momo's ceiling",
        arguments: [
            ("claude-opus-5", 64_000), ("claude-sonnet-4-5-20250929", 64_000),
            ("claude-opus-4-1-20250805", 32_000), ("claude-opus-4-20250514", 32_000),
            ("claude-opus-4-6", 64_000), ("claude-haiku-4-5", 64_000),
            ("claude-3-5-haiku-20241022", 8_192), ("claude-3-haiku-20240307", 4_096),
        ])
    func knownModels(model: String, expected: Int) {
        #expect(AnthropicProvider.maxTokens(for: model) == expected)
    }

    @Test("unknown models get a conservative default")
    func unknownModel() {
        #expect(AnthropicProvider.maxTokens(for: "claude-next") == 16_384)
        #expect(AnthropicProvider.maxTokens(for: "") == 16_384)
    }

    @Test("reads the limit from the API's error message")
    func parsesLimit() {
        #expect(AnthropicProvider.outputLimit(in: "Request failed (400). " + tooLarge) == 32_000)
        #expect(AnthropicProvider.outputLimit(in: "Request failed (400). messages: empty") == nil)
    }

    @Test("sends the model's limit as max_tokens")
    func sendsLimit() async throws {
        let (session, host) = MockURLProtocol.session(responses: [.init(body: answer)])
        let provider = AnthropicProvider(
            apiKey: "k", model: "claude-opus-4-1-20250805", session: session,
            endpoint: try #require(URL(string: "https://\(host)/v1/messages")))
        let result = await reply(from: provider.respond(to: question, runTool: noTool))
        #expect(result.error == nil)
        #expect(try sentMaxTokens(host: host) == [32_000])
    }

    @Test("a 400 saying max_tokens is too large is retried once with the stated limit")
    func retriesWithStatedLimit() async throws {
        let (session, host) = MockURLProtocol.session(responses: [
            .init(status: 400, body: tooLarge), .init(body: answer),
        ])
        let provider = AnthropicProvider(
            apiKey: "k", model: "claude-opus-5", session: session,
            endpoint: try #require(URL(string: "https://\(host)/v1/messages")))
        let result = await reply(from: provider.respond(to: question, runTool: noTool))
        #expect(result.error == nil)
        #expect(result.text == "Hello")
        #expect(try sentMaxTokens(host: host) == [64_000, 32_000])
    }

    @Test("other 400s fail with the provider's message and are not retried")
    func otherBadRequest() async throws {
        let message =
            #"{"type":"error","error":{"message":"messages: at least one message is required"}}"#
        let (session, host) = MockURLProtocol.session(responses: [
            .init(status: 400, body: message), .init(body: answer),
        ])
        let provider = AnthropicProvider(
            apiKey: "k", model: "claude-opus-5", session: session,
            endpoint: try #require(URL(string: "https://\(host)/v1/messages")))
        let result = await reply(from: provider.respond(to: question, runTool: noTool))
        let error = try #require(result.error as? ProviderError)
        #expect(error.message.contains("at least one message is required"))
        #expect(MockURLProtocol.requestBodies(host: host).count == 1)
    }
}
