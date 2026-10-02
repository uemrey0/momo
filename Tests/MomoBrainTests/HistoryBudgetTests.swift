import Foundation
import MomoKit
import Testing

@testable import MomoBrain

private let pixel = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

private func screenshot(_ name: String) -> ChatAttachment {
    ChatAttachment(name: name, content: .image(data: pixel, mimeType: "image/png"))
}

/// Three screenshots, each followed by a reply, then a fourth one with the new message.
private let screenshotChat: [ChatTurn] = [
    .init(role: .user, text: "First?", attachments: [screenshot("one.png")]),
    .init(role: .assistant, text: "A chart."),
    .init(role: .user, text: "Second?", attachments: [screenshot("two.png")]),
    .init(role: .assistant, text: "A map."),
    .init(role: .user, text: "And this?", attachments: [screenshot("three.png")]),
]

/// Sends `turns` and returns the JSON body of the request.
private func sentBody(
    _ provider: some ChatProvider, host: String, turns: [ChatTurn]
) async throws -> JSONValue {
    for try await _ in provider.respond(
        to: ChatRequest(systemPrompt: "s", turns: turns),
        runTool: { ToolResult(callID: $0.id, name: $0.name, output: "") })
    {}
    let body = try #require(MockURLProtocol.requestBodies(host: host).first)
    return try JSONValue.parse(body)
}

private let anthropicReply = sse(
    [#"{"type":"message_stop"}"#], named: ["message_stop"])
private let openAIReply = sse([#"{"choices":[{"delta":{"content":"ok"}}]}"#, "[DONE]"])

@Suite("History budget")
struct HistoryBudgetTests {
    @Test("keeps the newest turns within the budget and starts with the user")
    func trims() {
        let turns: [ChatTurn] =
            (0..<10).flatMap { index in
                [
                    ChatTurn(
                        role: .user, text: "question \(index) " + String(repeating: "q", count: 90)),
                    ChatTurn(
                        role: .assistant,
                        text: "answer \(index) " + String(repeating: "a", count: 90)),
                ]
            } + [ChatTurn(role: .user, text: "latest")]

        let recent = ChatTurn.recent(turns, budget: 450)
        #expect(recent.last?.text == "latest")
        #expect(recent.first?.role == .user)
        #expect(recent.map(\.contextText.count).reduce(0, +) <= 450)
        #expect(recent.count == 5)
        #expect(recent.first?.text.hasPrefix("question 8") == true)
        #expect(zip(recent, recent.dropFirst()).allSatisfy { $0.role != $1.role })
        #expect(ChatTurn.recent(turns, budget: 1_000_000) == ChatTurn.alternating(turns))
    }

    @Test("always keeps the latest turn, even over budget")
    func keepsLatest() {
        let long = ChatTurn(role: .user, text: String(repeating: "x", count: 500))
        let turns = [ChatTurn(role: .user, text: "Hi"), .init(role: .assistant, text: "Hey"), long]
        #expect(ChatTurn.recent(turns, budget: 100) == [long])
        #expect(ChatTurn.recent([], budget: 100).isEmpty)
    }

    @Test("sends Claude only the last two user turns' images and notes older ones")
    func anthropicImages() async throws {
        let (session, host) = MockURLProtocol.session(responses: [.init(body: anthropicReply)])
        let provider = AnthropicProvider(
            apiKey: "k", session: session,
            endpoint: try #require(URL(string: "https://\(host)/v1/messages")))
        let body = try await sentBody(provider, host: host, turns: screenshotChat)
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(
            messages.map { $0["role"]?.stringValue } == [
                "user", "assistant", "user", "assistant", "user",
            ])

        #expect(body.jsonString.components(separatedBy: pixel.base64EncodedString()).count == 3)
        for index in [2, 4] {
            let blocks = try #require(messages[index]["content"]?.arrayValue)
            #expect(blocks.first?["type"]?.stringValue == "image")
        }
        let first = try #require(messages.first?["content"]?.stringValue)
        #expect(first.contains("[image shared earlier: one.png, no longer attached;"))
        #expect(!first.contains("not visible"))
        #expect(first.hasSuffix("First?"))
    }

    @Test("sends OpenAI-compatible models only the last two user turns' images")
    func openAIImages() async throws {
        let (session, host) = MockURLProtocol.session(responses: [.init(body: openAIReply)])
        let provider = OpenAICompatibleProvider(
            info: ProviderInfo(id: "test", name: "Test", kind: .apiKey, supportsImages: true),
            baseURL: try #require(URL(string: "https://\(host)/v1")), model: "m", apiKey: "k",
            session: session)
        let body = try await sentBody(provider, host: host, turns: screenshotChat)
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.count == 6)
        #expect(messages.first?["role"]?.stringValue == "system")

        #expect(body.jsonString.components(separatedBy: pixel.base64EncodedString()).count == 3)
        for index in [3, 5] {
            let parts = try #require(messages[index]["content"]?.arrayValue)
            #expect(parts.last?["image_url"] != nil)
        }
        let first = try #require(messages[1]["content"]?.stringValue)
        #expect(first.contains("[image shared earlier: one.png, no longer attached;"))
        #expect(!first.contains("not visible"))
    }

    @Test("still tells brains that can't see that images aren't visible")
    func blindHistory() {
        let provider = OpenAICompatibleProvider.ollama(model: "llama3.2")
        let old = provider.content(of: screenshotChat[0], includingImages: false)
        #expect(old.stringValue?.contains("[image attached: one.png, not visible") == true)
        #expect(screenshotChat[0].contextText.contains("not visible to this brain"))
    }

    @Test("fits a long chat into a local model's comfortable length")
    func localBudget() async throws {
        let (session, host) = MockURLProtocol.session(responses: [.init(body: openAIReply)])
        let provider = OpenAICompatibleProvider.ollama(
            model: "llama3.2", baseURL: try #require(URL(string: "http://\(host)/v1")),
            session: session)
        #expect(provider.historyBudget == provider.info.comfortableLength)
        let turns: [ChatTurn] =
            (0..<40).flatMap { index in
                [
                    ChatTurn(
                        role: .user, text: "Q\(index) " + String(repeating: "q", count: 1_000)),
                    ChatTurn(
                        role: .assistant, text: "A\(index) " + String(repeating: "a", count: 1_000)),
                ]
            } + [ChatTurn(role: .user, text: "What now?")]

        let body = try await sentBody(provider, host: host, turns: turns)
        let history = try #require(body["messages"]?.arrayValue).dropFirst()
        let texts = history.compactMap { $0["content"]?.stringValue }
        #expect(texts.map(\.count).reduce(0, +) <= provider.info.comfortableLength)
        #expect(history.first?["role"]?.stringValue == "user")
        #expect(texts.last == "What now?")
        #expect(texts.contains { $0.hasPrefix("A39 ") })
        #expect(!texts.contains { $0.hasPrefix("Q0 ") })
    }

    @Test("asks for a new conversation when the request is too large")
    func overflowErrors() {
        let tooLarge = HTTP.error(status: 413, body: Data("Payload Too Large".utf8))
        #expect(tooLarge.message.contains("Start a new conversation"))

        let anthropic = HTTP.error(
            status: 400,
            body: Data(
                #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 210000 tokens > 200000 maximum"}}"#
                    .utf8))
        #expect(anthropic.message.contains("Start a new conversation"))
        #expect(anthropic.message.contains("210000 tokens"))

        let openAI = HTTP.error(
            status: 400,
            body: Data(
                #"{"error":{"message":"This model's maximum context length is 128000 tokens.","code":"context_length_exceeded"}}"#
                    .utf8))
        #expect(openAI.message.contains("Start a new conversation"))

        let rateLimit = HTTP.error(
            status: 429,
            body: Data(#"{"error":{"message":"Request too large for tokens per min"}}"#.utf8))
        #expect(!rateLimit.message.contains("Start a new conversation"))
        #expect(
            !HTTP.error(status: 400, body: Data("bad".utf8)).message.contains("new conversation"))
    }
}
