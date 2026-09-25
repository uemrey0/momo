import Foundation
import MomoKit
import Testing

@testable import MomoBrain

private let echoTool = ToolDefinition(
    name: "add_task", description: "Add a task",
    parameters: JSONSchema.object(["title": JSONSchema.string("Title")], required: ["title"]))

private func collect(
    _ stream: AsyncThrowingStream<ChatEvent, any Error>
) async throws
    -> [ChatEvent]
{
    var events: [ChatEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private func text(of events: [ChatEvent]) -> String {
    events.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
}

@Suite("Server-sent events")
struct ServerSentEventTests {
    @Test("pairs event names with their data")
    func pairsNames() {
        var parser = ServerSentEventParser()
        #expect(parser.consume("event: message_start") == nil)
        #expect(parser.consume("data: {}") == .init(name: "message_start", data: "{}"))
        #expect(parser.consume(": keep-alive") == nil)
        #expect(parser.consume("data: [DONE]") == .init(name: nil, data: "[DONE]"))
    }
}

@Suite("OpenAI-compatible provider")
struct OpenAICompatibleProviderTests {
    @Test("streams text, runs a tool call split across chunks, then continues")
    func toolLoop() async throws {
        let first = sse([
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"add_task","arguments":"{\"ti"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"tle\":\"Milk\"}"}}]}}]}"#,
            "[DONE]",
        ])
        let second = sse([
            #"{"choices":[{"delta":{"content":"Added "}}]}"#,
            #"{"choices":[{"delta":{"content":"milk."}}]}"#, "[DONE]",
        ])
        let (session, host) = MockURLProtocol.session(responses: [
            .init(body: first), .init(body: second),
        ])
        let provider = OpenAICompatibleProvider(
            info: ProviderInfo(id: "test", name: "Test", kind: .apiKey),
            baseURL: URL(string: "https://\(host)/v1")!, model: "m", apiKey: "k", session: session)

        let received = LockedBox<[ToolCall]>([])
        let events = try await collect(
            provider.respond(
                to: ChatRequest(
                    systemPrompt: "Be nice", turns: [.init(role: .user, text: "Add milk")],
                    tools: [echoTool])
            ) { call in
                received.append(call)
                return ToolResult(callID: call.id, name: call.name, output: "ok")
            })

        #expect(text(of: events) == "Added milk.")
        #expect(received.value.first?.arguments == #"{"title":"Milk"}"#)
        let bodies = MockURLProtocol.requestBodies(host: host)
        #expect(bodies.count == 2)
        #expect(bodies[1].contains(#""role":"tool""#))
        #expect(bodies[1].contains(#""tool_call_id":"call_1""#))
    }

    @Test("explains authentication failures")
    func authFailure() async {
        let (session, host) = MockURLProtocol.session(responses: [
            .init(status: 401, body: #"{"error":{"message":"Invalid key"}}"#)
        ])
        let provider = OpenAICompatibleProvider(
            info: ProviderInfo(id: "test", name: "Test", kind: .apiKey),
            baseURL: URL(string: "https://\(host)/v1")!, model: "m", apiKey: "k", session: session)
        await #expect(throws: ProviderError.self) {
            _ = try await collect(
                provider.respond(
                    to: ChatRequest(systemPrompt: "", turns: [.init(role: .user, text: "hi")])
                ) { call in
                    ToolResult(callID: call.id, name: call.name, output: "")
                })
        }
    }
}

@Suite("Anthropic provider")
struct AnthropicProviderTests {
    @Test("replays thinking and tool use blocks, then streams the answer")
    func toolLoop() async throws {
        let names = [
            "message_start", "content_block_start", "content_block_delta", "content_block_delta",
            "content_block_stop", "content_block_start", "content_block_delta",
            "content_block_delta", "content_block_stop", "message_delta", "message_stop",
        ]
        let first = sse(
            [
                #"{"type":"message_start","message":{"id":"msg_1"}}"#,
                #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}"#,
                #"{"type":"content_block_stop","index":0}"#,
                #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"add_task","input":{}}}"#,
                #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"title\":"}}"#,
                #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"Milk\"}"}}"#,
                #"{"type":"content_block_stop","index":1}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
                #"{"type":"message_stop"}"#,
            ], named: names)
        let second = sse(
            [
                #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Done!"}}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
                #"{"type":"message_stop"}"#,
            ],
            named: ["content_block_start", "content_block_delta", "message_delta", "message_stop"])
        let (session, host) = MockURLProtocol.session(responses: [
            .init(body: first), .init(body: second),
        ])
        let provider = AnthropicProvider(
            apiKey: "k", model: "claude-opus-5", session: session,
            endpoint: URL(string: "https://\(host)/v1/messages")!)

        let events = try await collect(
            provider.respond(
                to: ChatRequest(
                    systemPrompt: "sys", turns: [.init(role: .user, text: "Add milk")],
                    tools: [echoTool])
            ) { call in
                ToolResult(callID: call.id, name: call.name, output: "added \(call.arguments)")
            })

        #expect(text(of: events) == "Done!")
        #expect(
            events.contains(
                .toolStarted(
                    ToolCall(id: "toolu_1", name: "add_task", arguments: #"{"title":"Milk"}"#))))
        let bodies = MockURLProtocol.requestBodies(host: host)
        #expect(bodies.count == 2)
        let replay = try JSONValue.parse(bodies[1])
        let assistant = replay["messages"]?.arrayValue?[1]["content"]?.arrayValue
        #expect(assistant?[0]["signature"]?.stringValue == "sig123")
        #expect(assistant?[1]["input"]?["title"]?.stringValue == "Milk")
        let result = replay["messages"]?.arrayValue?[2]["content"]?.arrayValue?.first
        #expect(result?["type"]?.stringValue == "tool_result")
        #expect(result?["tool_use_id"]?.stringValue == "toolu_1")
        #expect(replay["fallbacks"]?.stringValue == "default")
        #expect(replay["tools"]?.arrayValue?.first?["eager_input_streaming"] == .bool(true))
    }

    @Test("reports refusals instead of failing silently")
    func refusal() async throws {
        let body = sse(
            [
                #"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#,
                #"{"type":"message_stop"}"#,
            ], named: ["message_delta", "message_stop"])
        let (session, host) = MockURLProtocol.session(responses: [.init(body: body)])
        let provider = AnthropicProvider(
            apiKey: "k", session: session, endpoint: URL(string: "https://\(host)/v1/messages")!)
        let events = try await collect(
            provider.respond(
                to: ChatRequest(systemPrompt: "", turns: [.init(role: .user, text: "x")])
            ) {
                ToolResult(callID: $0.id, name: $0.name, output: "")
            })
        #expect(text(of: events).contains("declined"))
    }

    @Test("merges turns so roles alternate")
    func alternatingTurns() {
        let turns = ChatTurn.alternating([
            .init(role: .assistant, text: "Hi!"), .init(role: .user, text: "a"),
            .init(role: .user, text: "b"), .init(role: .assistant, text: "c"),
        ])
        #expect(turns == [.init(role: .user, text: "a\n\nb"), .init(role: .assistant, text: "c")])
    }
}

@Suite("CLI bridges")
struct CLIBridgeTests {
    @Test("reads Codex JSON events")
    func codexEvents() throws {
        var parser = CodexEventParser()
        #expect(try parser.consume(#"{"type":"thread.started","thread_id":"t"}"#).isEmpty)
        let tool = try parser.consume(
            #"{"type":"item.started","item":{"id":"i1","type":"mcp_tool_call","tool":"add_task","arguments":{"title":"x"}}}"#
        )
        #expect(tool.count == 1)
        let message = try parser.consume(
            #"{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"Hello"}}"#)
        #expect(message == [.text("Hello")])
        #expect(throws: ProviderError.self) {
            try parser.consume(#"{"type":"turn.failed","error":{"message":"Usage limit reached"}}"#)
        }
        #expect(parser.lastError == "Usage limit reached")
    }

    @Test("passes the Momo MCP server to Codex safely quoted")
    func codexArguments() {
        let provider = CodexProvider(
            model: "gpt-5.6", mcpServerPath: "/Applications/Momo.app/Contents/MacOS/momo-mcp",
            workingDirectory: URL(fileURLWithPath: "/tmp"))
        let arguments = provider.arguments()
        #expect(arguments.contains("read-only"))
        #expect(
            arguments.contains(
                #"mcp_servers.momo.command="/Applications/Momo.app/Contents/MacOS/momo-mcp""#))
        #expect(arguments.last == "-")
    }

    @Test("reads Gemini CLI JSON output after log lines")
    func geminiOutput() throws {
        #expect(
            try GeminiCLIProvider.parse(
                "Loaded cached credentials.\n{\"response\":\"Hi\",\"stats\":{}}") == "Hi")
        #expect(throws: ProviderError.self) {
            try GeminiCLIProvider.parse(#"{"error":{"message":"quota"}}"#)
        }
    }
}

@Suite("Prompts and settings")
struct PromptAndSettingsTests {
    @Test("flattens recent history within a budget")
    func flattens() {
        let turns: [ChatTurn] = [
            .init(role: .user, text: String(repeating: "old ", count: 500)),
            .init(role: .assistant, text: "Sure"), .init(role: .user, text: "New question"),
        ]
        let prompt = PromptFlattener.prompt(for: turns, budget: 200)
        #expect(prompt.contains("Momo: Sure"))
        #expect(!prompt.contains("old old"))
        #expect(prompt.hasSuffix("New question"))
        #expect(PromptFlattener.prompt(for: [.init(role: .user, text: "Hi")], budget: 10) == "Hi")
    }

    @Test("includes memories and the current time in the system prompt")
    func systemPrompt() {
        let prompt = SystemPrompt.make(
            memories: [Memory(text: "The user's name is Emre")], languageName: "Turkish",
            now: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        #expect(prompt.contains("The user's name is Emre"))
        #expect(prompt.contains("1970-01-01T00:00"))
        #expect(prompt.contains("Turkish"))
    }

    @Test("decodes old settings and adds new brains")
    func lenientSettings() throws {
        let settings = try JSONDecoder().decode(
            BrainSettings.self, from: Data(#"{"order":["codex"],"localOnly":true}"#.utf8))
        #expect(settings.localOnly)
        #expect(settings.order.first == "codex")
        #expect(settings.order.count == BrainCatalog.allIDs.count)
        #expect(settings.masksPersonalData)
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func append<Element>(_ element: Element) where Value == [Element] {
        lock.lock()
        stored.append(element)
        lock.unlock()
    }
}
