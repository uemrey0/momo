import Foundation
import MomoKit

/// Uses the user's ChatGPT plan through Codex: the official Codex CLI or the copy that comes
/// with the ChatGPT app. Codex handles sign-in; Momo never sees the credentials.
///
/// Runs `codex exec --json` in a read-only sandbox. When the Momo MCP server is available,
/// Codex can use Momo's tasks, notes and memory tools through it.
public struct CodexProvider: ChatProvider {
    public let info = ProviderInfo(id: "codex", name: "ChatGPT (Codex)", kind: .subscription)
    public let model: String?
    /// Path to the `momo-mcp` executable, offered to Codex as an MCP server.
    public let mcpServerPath: String?
    private let workingDirectory: URL

    public init(model: String? = nil, mcpServerPath: String? = nil, workingDirectory: URL) {
        self.model = model?.isEmpty == true ? nil : model
        self.mcpServerPath = mcpServerPath
        self.workingDirectory = workingDirectory
    }

    public static var isSignedIn: Bool {
        let home =
            ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        return FileManager.default.fileExists(
            atPath: (home as NSString).appendingPathComponent("auth.json"))
    }

    public func availability() async -> ProviderAvailability {
        guard CodexSetup.locate() != nil else {
            return .unavailable("Install the ChatGPT app for Mac, then connect it in Settings.")
        }
        guard await CodexSetup.isSignedIn() else {
            return .unavailable("Sign in with ChatGPT in Settings → AI.")
        }
        return .ready
    }

    func arguments() -> [String] {
        var arguments = [
            "exec", "--json", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
        ]
        if let model { arguments += ["-m", model] }
        if let mcpServerPath {
            arguments += ["-c", "mcp_servers.momo.command=\(Self.tomlString(mcpServerPath))"]
        }
        arguments.append("-")
        return arguments
    }

    public func respond(
        to request: ChatRequest, runTool: @escaping ToolRunner
    )
        -> AsyncThrowingStream<ChatEvent, any Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let executable = CodexSetup.locate() else {
                    continuation.finish(throwing: ProviderError("Codex was not found."))
                    return
                }
                let prompt = CLIPrompt.make(request)
                var parser = CodexEventParser()
                do {
                    for try await line in CommandRunner.lines(
                        executable: executable, arguments: arguments(), input: prompt,
                        workingDirectory: workingDirectory)
                    {
                        for event in try parser.consume(line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch let failure as CommandRunner.Failure {
                    continuation.finish(
                        throwing: ProviderError(
                            parser.lastError ?? CLIPrompt.describe(failure, tool: "Codex")))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func tomlString(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Reads the JSON Lines events of `codex exec --json`.
struct CodexEventParser {
    private(set) var lastError: String?
    private var messageCount = 0

    mutating func consume(_ line: String) throws -> [ChatEvent] {
        guard let event = try? JSONValue.parse(line), let type = event["type"]?.stringValue else {
            return []
        }
        let item = event["item"]
        switch (type, item?["type"]?.stringValue) {
        case ("item.completed", "agent_message"):
            guard let text = item?["text"]?.stringValue, !text.isEmpty else { return [] }
            defer { messageCount += 1 }
            return [.text(messageCount == 0 ? text : "\n\n" + text)]
        case ("item.started", "mcp_tool_call"):
            return [.toolStarted(Self.toolCall(item))]
        case ("item.completed", "mcp_tool_call"):
            let call = Self.toolCall(item)
            let failed = item?["status"]?.stringValue == "failed"
            return [
                .toolFinished(
                    ToolResult(
                        callID: call.id, name: call.name,
                        output: item?["result"]?.jsonString ?? "", isError: failed))
            ]
        case ("turn.failed", _):
            lastError = event["error"]?["message"]?.stringValue ?? "Codex could not finish."
            throw ProviderError(lastError ?? "")
        case ("error", _):
            lastError = event["message"]?.stringValue ?? event["error"]?["message"]?.stringValue
            return []
        default:
            return []
        }
    }

    private static func toolCall(_ item: JSONValue?) -> ToolCall {
        ToolCall(
            id: item?["id"]?.stringValue ?? ShortID.make(),
            name: item?["tool"]?.stringValue ?? "tool",
            arguments: item?["arguments"]?.jsonString ?? "{}")
    }
}

/// Uses the user's Google account (and their Google AI plan, if they have one) through the
/// official Gemini CLI, signed in with Google. It never uses a Gemini API key, which would be
/// billed separately.
public struct GeminiCLIProvider: ChatProvider {
    public let info = ProviderInfo(id: "gemini-cli", name: "Gemini (CLI)", kind: .subscription)
    public let model: String?
    private let workingDirectory: URL

    public init(model: String? = nil, workingDirectory: URL) {
        self.model = model?.isEmpty == true ? nil : model
        self.workingDirectory = workingDirectory
    }

    public static var isSignedIn: Bool {
        let folder = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini")
        return FileManager.default.fileExists(
            atPath: (folder as NSString).appendingPathComponent("oauth_creds.json"))
    }

    public func availability() async -> ProviderAvailability {
        guard GeminiCLISetup.isInstalled else {
            return .unavailable("Connect Google Gemini in Settings → AI.")
        }
        guard Self.isSignedIn else {
            return .unavailable("Sign in with Google in Settings → AI.")
        }
        return .ready
    }

    public func respond(
        to request: ChatRequest, runTool: @escaping ToolRunner
    )
        -> AsyncThrowingStream<ChatEvent, any Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let executable = GeminiCLISetup.locate() else {
                    continuation.finish(throwing: ProviderError("The Gemini CLI is not installed."))
                    return
                }
                var arguments = ["--output-format", "json"]
                if let model { arguments += ["-m", model] }
                var output = ""
                do {
                    // Always use the Google sign-in, never an API key from the environment.
                    for try await line in CommandRunner.lines(
                        executable: executable, arguments: arguments,
                        input: CLIPrompt.make(request), workingDirectory: workingDirectory,
                        environment: ["GOOGLE_GENAI_USE_GCA": "true", "GEMINI_API_KEY": ""])
                    {
                        output += line + "\n"
                    }
                    continuation.yield(.text(try Self.parse(output)))
                    continuation.finish()
                } catch let failure as CommandRunner.Failure {
                    let message = Self.errorMessage(in: output)
                    continuation.finish(
                        throwing: ProviderError(
                            message ?? CLIPrompt.describe(failure, tool: "Gemini CLI")))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The error message in a JSON answer, if there is one.
    static func errorMessage(in output: String) -> String? {
        guard let start = output.firstIndex(of: "{"),
            let json = try? JSONValue.parse(String(output[start...])),
            let message = json["error"]?["message"]?.stringValue
        else { return nil }
        return "Gemini CLI: \(message)"
    }

    /// Extracts the reply from `--output-format json`, which may follow log lines.
    static func parse(_ output: String) throws -> String {
        guard let start = output.firstIndex(of: "{"),
            let json = try? JSONValue.parse(String(output[start...]))
        else {
            throw ProviderError("The Gemini CLI returned an unexpected answer.")
        }
        if let message = json["error"]?["message"]?.stringValue {
            throw ProviderError("Gemini CLI: \(message)")
        }
        guard let response = json["response"]?.stringValue else {
            throw ProviderError("The Gemini CLI returned no answer.")
        }
        return response
    }
}

/// Builds single-shot prompts for CLI agents and explains their failures.
enum CLIPrompt {
    static func make(_ request: ChatRequest) -> String {
        """
        \(request.systemPrompt)

        You are answering through a command line bridge. Do not modify files or run shell \
        commands; just answer.

        \(PromptFlattener.prompt(for: request.turns, budget: 60_000))
        """
    }

    static func describe(_ failure: CommandRunner.Failure, tool: String) -> String {
        let detail = failure.standardError
            .split(separator: "\n").suffix(3).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if detail.localizedCaseInsensitiveContains("login")
            || detail.localizedCaseInsensitiveContains("auth")
        {
            return "\(tool) needs you to sign in again in Settings → AI."
        }
        return detail.isEmpty
            ? "\(tool) stopped unexpectedly (exit code \(failure.status))."
            : "\(tool): \(detail)"
    }
}
