import Foundation
import MomoKit

/// A model the user can pick, described in words they understand.
public struct ModelChoice: Identifiable, Sendable, Equatable {
    /// The value saved in settings. Empty means "let the provider decide".
    public var id: String
    /// A readable name, such as "Claude Sonnet 4.5".
    public var name: String
    /// A short description, when the provider offers one.
    public var detail: String?
    /// Whether this is the provider's own recommendation.
    public var isRecommended: Bool

    public init(id: String, name: String, detail: String? = nil, isRecommended: Bool = false) {
        self.id = id
        self.name = name
        self.detail = detail
        self.isRecommended = isRecommended
    }
}

/// Finds the models each provider offers, so people pick from a list instead of typing names.
public enum ModelCatalog {
    /// Lists the models for `providerID`. `key` is needed for API key providers.
    public static func choices(
        for providerID: String, key: String? = nil, session: URLSession = .shared
    ) async throws -> [ModelChoice] {
        switch providerID {
        case "codex":
            return try await codexChoices()
        case "gemini-cli":
            return geminiCLIChoices
        case "anthropic":
            return try parseAnthropic(
                try await get(
                    "https://api.anthropic.com/v1/models?limit=100",
                    headers: ["x-api-key": key ?? "", "anthropic-version": "2023-06-01"],
                    session: session))
        case "openai":
            return try parseOpenAI(
                try await get(
                    "https://api.openai.com/v1/models",
                    headers: ["Authorization": "Bearer \(key ?? "")"], session: session))
        case "gemini-api":
            return try parseGemini(
                try await get(
                    "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200",
                    headers: ["x-goog-api-key": key ?? ""], session: session))
        case "openrouter":
            return try parseOpenRouter(
                try await get("https://openrouter.ai/api/v1/models", headers: [:], session: session)
            )
        default:
            return []
        }
    }

    /// The Gemini CLI's own aliases, which always point to Google's latest models.
    public static let geminiCLIChoices = [
        ModelChoice(
            id: "", name: "Auto", detail: "Picks Pro or Flash for each request.",
            isRecommended: true),
        ModelChoice(id: "pro", name: "Pro", detail: "Google's most capable model."),
        ModelChoice(id: "flash", name: "Flash", detail: "Fast and capable."),
        ModelChoice(id: "flash-lite", name: "Flash-Lite", detail: "The fastest and lightest."),
    ]

    private static func get(
        _ address: String, headers: [String: String], session: URLSession
    ) async throws -> JSONValue {
        guard let url = URL(string: address) else { throw ProviderError("Invalid address.") }
        return try await HTTP.getJSON(session: session, url: url, headers: headers, timeout: 15)
    }

    // MARK: - Parsing

    static func parseAnthropic(_ json: JSONValue) throws -> [ModelChoice] {
        let models = json["data"]?.arrayValue ?? []
        return models.enumerated().compactMap { index, model in
            guard let id = model["id"]?.stringValue else { return nil }
            // The API lists the newest models first.
            return ModelChoice(
                id: id, name: model["display_name"]?.stringValue ?? id, isRecommended: index == 0)
        }
    }

    /// OpenAI lists every model, including audio, image and embedding ones; keep the chat
    /// models, newest first.
    static func parseOpenAI(_ json: JSONValue) throws -> [ModelChoice] {
        let excluded = [
            "audio", "realtime", "tts", "transcribe", "image", "embedding", "search", "instruct",
            "moderation", "dall-e", "whisper", "davinci", "babbage", "codex", "computer-use",
        ]
        let models = (json["data"]?.arrayValue ?? []).compactMap {
            model -> (id: String, created: Double)? in
            guard let id = model["id"]?.stringValue else { return nil }
            let isChat =
                id.hasPrefix("gpt-")
                || (id.hasPrefix("o") && id.dropFirst().first?.isNumber == true)
            guard isChat, !excluded.contains(where: id.contains) else { return nil }
            return (id, model["created"]?.doubleValue ?? 0)
        }
        return models.sorted { $0.created > $1.created }.enumerated().map { index, model in
            ModelChoice(id: model.id, name: model.id, isRecommended: index == 0)
        }
    }

    static func parseGemini(_ json: JSONValue) throws -> [ModelChoice] {
        let excluded = ["embedding", "image", "tts", "live", "audio", "aqa", "robotics"]
        return (json["models"]?.arrayValue ?? []).compactMap { model in
            guard let name = model["name"]?.stringValue, name.contains("gemini"),
                !excluded.contains(where: name.contains),
                model["supportedGenerationMethods"]?.arrayValue?.contains(
                    .string("generateContent"))
                    == true
            else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            return ModelChoice(
                id: id, name: model["displayName"]?.stringValue ?? id,
                detail: model["description"]?.stringValue.map { firstSentence(of: $0) },
                isRecommended: id == "gemini-flash-latest")
        }
    }

    static func parseOpenRouter(_ json: JSONValue) throws -> [ModelChoice] {
        let auto = ModelChoice(
            id: "openrouter/auto", name: "Auto",
            detail: "OpenRouter picks a model for each request.",
            isRecommended: true)
        let models = (json["data"]?.arrayValue ?? []).compactMap { model -> ModelChoice? in
            guard let id = model["id"]?.stringValue, id != auto.id else { return nil }
            return ModelChoice(id: id, name: model["name"]?.stringValue ?? id, detail: id)
        }
        return [auto] + models
    }

    static func parseCodex(_ result: JSONValue) -> [ModelChoice] {
        (result["data"]?.arrayValue ?? []).compactMap { model in
            guard let id = model["id"]?.stringValue ?? model["model"]?.stringValue,
                model["hidden"]?.boolValue != true
            else { return nil }
            return ModelChoice(
                id: id, name: model["displayName"]?.stringValue ?? id,
                detail: model["description"]?.stringValue,
                isRecommended: model["isDefault"]?.boolValue == true)
        }
    }

    private static func firstSentence(of text: String) -> String {
        guard let end = text.firstIndex(of: ".") else { return text }
        return String(text[...end])
    }

    // MARK: - Codex

    /// Asks Codex's app server which models the user's ChatGPT plan offers.
    static func codexChoices() async throws -> [ModelChoice] {
        guard let codex = CodexSetup.locate() else { throw ProviderError("Codex was not found.") }
        let result = try await JSONRPCProcess.request(
            executable: codex, arguments: ["app-server"],
            messages: [
                [
                    "jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": ["clientInfo": ["name": "momo", "version": "1"]],
                ],
                ["jsonrpc": "2.0", "method": "initialized"],
                ["jsonrpc": "2.0", "id": 2, "method": "model/list", "params": [:]],
            ],
            responseID: 2)
        return parseCodex(result)
    }
}

/// Starts a JSON-RPC server that talks over standard input and output, sends it some messages
/// and returns the result of one response.
enum JSONRPCProcess {
    static func request(
        executable: URL, arguments: [String], messages: [JSONValue], responseID: Int,
        timeout: Duration = .seconds(20)
    ) async throws -> JSONValue {
        let input = messages.map(\.jsonString).joined(separator: "\n") + "\n"
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                // Keep standard input open: servers stop when it closes.
                for try await line in CommandRunner.lines(
                    executable: executable, arguments: arguments, input: input,
                    closesInput: false)
                {
                    guard let message = try? JSONValue.parse(line),
                        message["id"]?.intValue == responseID
                    else { continue }
                    if let error = message["error"] {
                        throw ProviderError(error["message"]?.stringValue ?? "Request failed.")
                    }
                    return message["result"] ?? .null
                }
                throw ProviderError("No answer.")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProviderError("No answer in time.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ProviderError("No answer.") }
            return result
        }
    }
}
