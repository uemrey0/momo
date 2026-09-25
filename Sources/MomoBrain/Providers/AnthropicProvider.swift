import Foundation
import MomoKit

/// Talks to the Claude Messages API with an Anthropic API key.
///
/// Streams text, runs client tools in a loop, and replays every content block of the
/// assistant's turn (including thinking blocks and their signatures) unchanged when sending
/// tool results back.
public struct AnthropicProvider: ChatProvider {
    public static let defaultModel = "claude-opus-5"
    public static let defaultEndpoint = URL(literal: "https://api.anthropic.com/v1/messages")
    /// Models offered in Settings, most capable first.
    public static let suggestedModels = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]

    public let info: ProviderInfo
    public let model: String
    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL

    public init(
        apiKey: String, model: String = Self.defaultModel, session: URLSession = .shared,
        endpoint: URL = AnthropicProvider.defaultEndpoint
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.endpoint = endpoint
        self.info = ProviderInfo(id: "anthropic", name: "Claude · \(model)", kind: .apiKey)
    }

    public func availability() async -> ProviderAvailability {
        apiKey.isEmpty ? .unavailable("Add an Anthropic API key.") : .ready
    }

    public func respond(
        to request: ChatRequest, runTool: @escaping ToolRunner
    )
        -> AsyncThrowingStream<ChatEvent, any Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, runTool: runTool, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Conversation loop

    private func run(
        _ request: ChatRequest, runTool: ToolRunner,
        continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation
    ) async throws {
        var messages: [JSONValue] = ChatTurn.alternating(request.turns).map {
            ["role": .string($0.role.rawValue), "content": .string($0.text)]
        }
        for _ in 0..<maximumToolRounds {
            let turn = try await stream(
                system: request.systemPrompt, messages: messages, tools: request.tools,
                continuation: continuation)

            switch turn.stopReason {
            case "refusal":
                continuation.yield(.text("\n\n(Claude declined to answer this request.)"))
                return
            case "max_tokens":
                continuation.yield(.text("\n\n(The answer was cut off because it got too long.)"))
                return
            case "tool_use":
                break
            default:
                return
            }
            let calls = turn.toolUses
            guard !calls.isEmpty else { return }

            messages.append(["role": "assistant", "content": .array(turn.blocks)])
            var results: [JSONValue] = []
            for use in calls {
                let call = ToolCall(id: use.id, name: use.name, arguments: use.arguments)
                continuation.yield(.toolStarted(call))
                let result: ToolResult
                if use.isValidJSON {
                    result = await runTool(call)
                } else {
                    result = ToolResult(
                        callID: use.id, name: use.name,
                        output: "INVALID_JSON: the tool input could not be parsed. Try again.",
                        isError: true)
                }
                continuation.yield(.toolFinished(result))
                results.append([
                    "type": "tool_result", "tool_use_id": .string(use.id),
                    "content": .string(result.output), "is_error": .bool(result.isError),
                ])
            }
            // All results go back in one user message so parallel tool use keeps working.
            messages.append(["role": "user", "content": .array(results)])
        }
        continuation.yield(.text("\n\n(I stopped after too many tool steps.)"))
    }

    // MARK: - Streaming

    struct ToolUse {
        var id: String
        var name: String
        var arguments: String
        var isValidJSON: Bool
    }

    struct Turn {
        var blocks: [JSONValue] = []
        var stopReason: String?
        var toolUses: [ToolUse] = []
    }

    private func stream(
        system: String, messages: [JSONValue], tools: [ToolDefinition],
        continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation
    ) async throws -> Turn {
        var body: [String: JSONValue] = [
            "model": .string(model), "max_tokens": 64_000, "stream": true,
            "system": .string(system), "messages": .array(messages),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(
                tools.map { tool in
                    [
                        "name": .string(tool.name), "description": .string(tool.description),
                        "input_schema": tool.parameters, "eager_input_streaming": true,
                    ]
                })
        }
        var headers = ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        if Self.supportsServerSideFallback(model) {
            // If the model declines, the API retries on a suitable fallback model.
            body["fallbacks"] = "default"
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        }

        let lines = try await HTTP.streamLines(
            session: session, url: endpoint, headers: headers, body: .object(body))
        var accumulator = TurnAccumulator()
        var parser = ServerSentEventParser()
        for try await line in lines {
            guard let event = parser.consume(line),
                let payload = try? JSONValue.parse(event.data)
            else { continue }
            if let text = try accumulator.apply(payload) {
                continuation.yield(.text(text))
            }
            if accumulator.isFinished { break }
        }
        if !accumulator.isFinished { accumulator.finish() }
        return accumulator.turn
    }

    static func supportsServerSideFallback(_ model: String) -> Bool {
        model == "claude-opus-5" || model == "claude-fable-5-1"
    }
}

/// Rebuilds the assistant's content blocks from stream events.
struct TurnAccumulator {
    private(set) var turn = AnthropicProvider.Turn()
    private(set) var isFinished = false
    private var blocks: [Int: [String: JSONValue]] = [:]
    private var partialInputs: [Int: String] = [:]

    /// Applies one event and returns any new reply text.
    mutating func apply(_ event: JSONValue) throws -> String? {
        switch event["type"]?.stringValue {
        case "content_block_start":
            guard let index = event["index"]?.intValue,
                let block = event["content_block"]?.objectValue
            else { return nil }
            blocks[index] = block
            if block["type"]?.stringValue == "tool_use" { partialInputs[index] = "" }
        case "content_block_delta":
            guard let index = event["index"]?.intValue, let delta = event["delta"],
                var block = blocks[index]
            else { return nil }
            defer { blocks[index] = block }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let text = delta["text"]?.stringValue ?? ""
                block["text"] = .string((block["text"]?.stringValue ?? "") + text)
                return text
            case "thinking_delta":
                let thinking = delta["thinking"]?.stringValue ?? ""
                block["thinking"] = .string((block["thinking"]?.stringValue ?? "") + thinking)
            case "signature_delta":
                block["signature"] = delta["signature"] ?? .string("")
            case "input_json_delta":
                partialInputs[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
            default:
                break
            }
        case "content_block_stop":
            guard let index = event["index"]?.intValue else { return nil }
            finishToolUse(at: index)
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.stringValue {
                turn.stopReason = reason
            }
        case "message_stop":
            finish()
        case "error":
            let message = event["error"]?["message"]?.stringValue ?? "Unknown error"
            throw ProviderError("Claude reported an error: \(message)")
        default:
            break
        }
        return nil
    }

    private mutating func finishToolUse(at index: Int) {
        guard var block = blocks[index], block["type"]?.stringValue == "tool_use" else { return }
        let raw = partialInputs[index] ?? ""
        let parsed = try? JSONValue.parse(raw)
        block["input"] = parsed ?? .object([:])
        blocks[index] = block
        turn.toolUses.append(
            AnthropicProvider.ToolUse(
                id: block["id"]?.stringValue ?? "toolu_\(index)",
                name: block["name"]?.stringValue ?? "", arguments: raw.isEmpty ? "{}" : raw,
                isValidJSON: parsed != nil))
    }

    mutating func finish() {
        isFinished = true
        turn.blocks = blocks.keys.sorted().compactMap { blocks[$0].map(JSONValue.object) }
    }
}

extension ChatTurn {
    /// Merges consecutive turns from the same speaker and drops leading assistant turns, as
    /// strictly alternating APIs require.
    public static func alternating(_ turns: [ChatTurn]) -> [ChatTurn] {
        var result: [ChatTurn] = []
        for turn in turns where !turn.text.isEmpty {
            if result.isEmpty && turn.role == .assistant { continue }
            if let last = result.last, last.role == turn.role {
                result[result.count - 1].text += "\n\n" + turn.text
            } else {
                result.append(turn)
            }
        }
        return result
    }
}
