import Foundation
import MomoKit

/// Talks to any server that implements the OpenAI Chat Completions API with streaming and
/// function calling: Ollama, LM Studio, OpenAI, Google Gemini's compatibility endpoint and
/// OpenRouter.
public struct OpenAICompatibleProvider: ChatProvider {
    public let info: ProviderInfo
    public let baseURL: URL
    public let model: String
    private let apiKey: String?
    private let extraHeaders: [String: String]
    private let session: URLSession
    /// Local servers are probed for reachability; hosted ones only need a key.
    private let isLocalServer: Bool

    public init(
        info: ProviderInfo, baseURL: URL, model: String, apiKey: String? = nil,
        extraHeaders: [String: String] = [:], session: URLSession = .shared
    ) {
        var info = info
        info.supportsImages =
            info.supportsImages || Self.modelSupportsImages(model, providerID: info.id)
        self.info = info
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.session = session
        self.isLocalServer = info.kind == .local
    }

    // MARK: - Presets

    public static func ollama(
        model: String, baseURL: URL? = nil, session: URLSession = .shared
    )
        -> OpenAICompatibleProvider
    {
        OpenAICompatibleProvider(
            info: ProviderInfo(
                id: "ollama", name: "Ollama · \(model)", kind: .local, comfortableLength: 24_000),
            baseURL: baseURL ?? URL(literal: "http://localhost:11434/v1"), model: model,
            session: session)
    }

    public static func lmStudio(
        model: String, baseURL: URL? = nil, session: URLSession = .shared
    )
        -> OpenAICompatibleProvider
    {
        OpenAICompatibleProvider(
            info: ProviderInfo(
                id: "lmstudio", name: "LM Studio · \(model)", kind: .local,
                comfortableLength: 24_000),
            baseURL: baseURL ?? URL(literal: "http://localhost:1234/v1"), model: model,
            session: session)
    }

    public static func openAI(
        apiKey: String, model: String, session: URLSession = .shared
    )
        -> OpenAICompatibleProvider
    {
        OpenAICompatibleProvider(
            info: ProviderInfo(id: "openai", name: "OpenAI · \(model)", kind: .apiKey),
            baseURL: URL(literal: "https://api.openai.com/v1"), model: model, apiKey: apiKey,
            session: session)
    }

    public static func gemini(
        apiKey: String, model: String, session: URLSession = .shared
    )
        -> OpenAICompatibleProvider
    {
        OpenAICompatibleProvider(
            info: ProviderInfo(id: "gemini-api", name: "Gemini · \(model)", kind: .apiKey),
            baseURL: URL(literal: "https://generativelanguage.googleapis.com/v1beta/openai"),
            model: model, apiKey: apiKey, session: session)
    }

    public static func openRouter(
        apiKey: String, model: String, session: URLSession = .shared
    )
        -> OpenAICompatibleProvider
    {
        OpenAICompatibleProvider(
            info: ProviderInfo(id: "openrouter", name: "OpenRouter · \(model)", kind: .apiKey),
            baseURL: URL(literal: "https://openrouter.ai/api/v1"), model: model, apiKey: apiKey,
            extraHeaders: ["X-Title": "Momo", "HTTP-Referer": "https://github.com/uemrey0/momo"],
            session: session)
    }

    // MARK: - ChatProvider

    public func availability() async -> ProviderAvailability {
        if !isLocalServer {
            guard let apiKey, !apiKey.isEmpty else { return .unavailable("Add an API key.") }
            return .ready
        }
        do {
            let models = try await Self.listModels(baseURL: baseURL, session: session)
            if models.isEmpty { return .unavailable("The server is running but has no models.") }
            if !models.contains(model) {
                return .unavailable("The model “\(model)” is not installed on the server.")
            }
            return .ready
        } catch {
            return .unavailable("The server at \(baseURL.host() ?? "localhost") is not running.")
        }
    }

    /// Lists the model IDs a server offers.
    public static func listModels(
        baseURL: URL, session: URLSession = .shared
    ) async throws
        -> [String]
    {
        let json = try await HTTP.getJSON(
            session: session, url: baseURL.appendingPathComponent("models"), timeout: 1.5)
        return json["data"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
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
        var messages: [JSONValue] = [["role": "system", "content": .string(request.systemPrompt)]]
        let turns = ChatTurn.recent(request.turns, budget: historyBudget)
        messages += turns.indices.map { index in
            let turn = turns[index]
            return [
                "role": .string(turn.role.rawValue),
                "content": content(of: turn, includingImages: index == turns.count - 1),
            ]
        }
        var tools = request.tools
        for _ in 0..<maximumToolRounds {
            try Task.checkCancellation()
            let round: Round
            do {
                round = try await stream(
                    messages: messages, tools: tools, continuation: continuation)
            } catch let error as ProviderError
                where !tools.isEmpty && error.message.localizedCaseInsensitiveContains("tool")
            {
                // Some local models cannot call tools; carry on without them.
                tools = []
                round = try await stream(messages: messages, tools: [], continuation: continuation)
            }
            guard !round.toolCalls.isEmpty else { return }

            messages.append([
                "role": "assistant",
                "content": round.text.isEmpty ? .null : .string(round.text),
                "tool_calls": .array(
                    round.toolCalls.map { call in
                        [
                            "id": .string(call.id), "type": "function",
                            "function": [
                                "name": .string(call.name), "arguments": .string(call.arguments),
                            ],
                        ]
                    }),
            ])
            for call in round.toolCalls {
                try Task.checkCancellation()
                continuation.yield(.toolStarted(call))
                let result = await runTool(call)
                continuation.yield(.toolFinished(result))
                messages.append([
                    "role": "tool", "tool_call_id": .string(call.id),
                    "content": .string(result.output),
                ])
            }
        }
        continuation.yield(.text(toolRoundLimitNotice))
    }

    /// How many characters of history to send. Local models get what they handle well, so
    /// the server doesn't silently cut off the system prompt and tools at the start of its
    /// context; hosted ones get the same budget as Claude.
    var historyBudget: Int { isLocalServer ? info.comfortableLength : remoteHistoryBudget }

    // MARK: - Images

    /// A turn's message content: plain text, or text and `image_url` parts with data URIs
    /// when the turn has images and the model can see them. Without `includingImages`,
    /// images are described in words instead, so earlier screenshots aren't uploaded again
    /// with every message.
    func content(of turn: ChatTurn, includingImages: Bool = true) -> JSONValue {
        let images = turn.images
        guard info.supportsImages, includingImages, !images.isEmpty else {
            return .string(turn.contextText)
        }
        var parts: [JSONValue] = []
        let text = turn.context(imagesVisible: true)
        if !text.isEmpty { parts.append(["type": "text", "text": .string(text)]) }
        for image in images {
            let url = "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
            parts.append(["type": "image_url", "image_url": ["url": .string(url)]])
        }
        return .array(parts)
    }

    /// Model name fragments of vision models served through OpenAI-compatible APIs.
    static let visionModelHints = [
        "vision", "-vl", "vl-", "llava", "moondream", "minicpm-v", "gemma3", "gemma-3",
        "qwen2.5vl", "qwen3-vl", "pixtral", "llama-4", "llama4", "mistral-small3",
        "mistral-small-3",
        "claude", "gemini", "gpt-4o", "gpt-4.1", "gpt-5", "grok-4", "o4-mini",
    ]

    /// Whether a model can plausibly look at images, judged from its name. Gemini models all
    /// can; OpenAI's current chat models can, except small reasoning models.
    public static func modelSupportsImages(_ model: String, providerID: String) -> Bool {
        let name = model.lowercased()
        if providerID == "gemini-api" { return true }
        if providerID == "openai",
            ["o1", "o3", "o4", "chatgpt"].contains(where: name.hasPrefix),
            !name.hasPrefix("o1-mini"), !name.hasPrefix("o3-mini")
        {
            return true
        }
        return visionModelHints.contains { name.contains($0) }
    }

    private struct Round {
        var text = ""
        var toolCalls: [ToolCall] = []
    }

    private func stream(
        messages: [JSONValue], tools: [ToolDefinition],
        continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation
    ) async throws -> Round {
        var body: [String: JSONValue] = [
            "model": .string(model), "stream": true, "messages": .array(messages),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(
                tools.map { tool in
                    [
                        "type": "function",
                        "function": [
                            "name": .string(tool.name), "description": .string(tool.description),
                            "parameters": tool.parameters,
                        ],
                    ]
                })
        }
        var headers = extraHeaders
        if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }

        let lines = try await HTTP.streamLines(
            session: session, url: baseURL.appendingPathComponent("chat/completions"),
            headers: headers, body: .object(body))

        var parser = ServerSentEventParser()
        var round = Round()
        var partialCalls: [Int: (id: String, name: String, arguments: String)] = [:]
        for try await line in lines {
            guard let event = parser.consume(line) else { continue }
            if event.data == "[DONE]" { break }
            guard let chunk = try? JSONValue.parse(event.data) else { continue }
            if let message = chunk["error"]?["message"]?.stringValue {
                throw ProviderError(message)
            }
            guard let delta = chunk["choices"]?.arrayValue?.first?["delta"] else { continue }
            if let text = delta["content"]?.stringValue, !text.isEmpty {
                round.text += text
                continuation.yield(.text(text))
            }
            for call in delta["tool_calls"]?.arrayValue ?? [] {
                let index = call["index"]?.intValue ?? partialCalls.count
                var partial = partialCalls[index] ?? ("", "", "")
                if let id = call["id"]?.stringValue, !id.isEmpty { partial.id = id }
                if let name = call["function"]?["name"]?.stringValue { partial.name += name }
                if let arguments = call["function"]?["arguments"]?.stringValue {
                    partial.arguments += arguments
                }
                partialCalls[index] = partial
            }
        }
        round.toolCalls = partialCalls.keys.sorted().compactMap { index in
            guard let call = partialCalls[index], !call.name.isEmpty else { return nil }
            return ToolCall(
                id: call.id.isEmpty ? "call_\(index)" : call.id, name: call.name,
                arguments: call.arguments)
        }
        return round
    }
}
