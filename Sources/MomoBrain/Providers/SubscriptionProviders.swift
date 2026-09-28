import Foundation
import MomoKit

/// Uses the user's ChatGPT plan through Codex: the official Codex CLI or the copy that comes
/// with the ChatGPT app. Codex handles sign-in; Momo never sees the credentials.
///
/// Runs `codex exec --json` in a read-only sandbox, with Codex's own web search. While it
/// answers, the app serves the request's tools through a ``ToolBridge``, so Codex can use
/// every tool Momo has (store, system and the user's MCP servers) with Momo's confirmations
/// and masking. Without a bridge it falls back to the standalone Momo MCP server.
public struct CodexProvider: ChatProvider {
    public let info = ProviderInfo(
        id: "codex", name: "ChatGPT (Codex)", kind: .subscription, supportsImages: true)
    public let model: String?
    /// Path to the `momo-mcp` executable, which Codex launches to reach Momo's tools.
    public let mcpServerPath: String?
    private let workingDirectory: URL

    public init(model: String? = nil, mcpServerPath: String? = nil, workingDirectory: URL) {
        self.model = model?.isEmpty == true ? nil : model
        self.mcpServerPath = mcpServerPath
        self.workingDirectory = workingDirectory
    }

    /// Codex's home folder: `CODEX_HOME`, or `~/.codex`.
    static var home: URL {
        URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]
                ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex"),
            isDirectory: true)
    }

    public static var isSignedIn: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path)
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

    /// How long Codex waits for one Momo tool call: long enough for the user to answer a
    /// confirmation question.
    static let toolTimeoutSeconds = 600

    /// - Parameter fast: The answer is awaited in a voice conversation, so Codex thinks
    ///   briefly and the first words come sooner.
    func arguments(bridge: MCPLaunch? = nil, fast: Bool = false) -> [String] {
        var arguments = [
            "exec", "--json", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
            // Codex's own web search, for current information.
            "-c", #"web_search="live""#,
        ]
        if fast { arguments += ["-c", #"model_reasoning_effort="low""#] }
        if let model { arguments += ["-m", model] }
        let server = "mcp_servers.\(ToolBridge.serverName)"
        if let bridge {
            arguments += [
                "-c", "\(server).command=\(Self.tomlString(bridge.command))",
                "-c", "\(server).args=\(Self.tomlArray(bridge.arguments))",
                "-c", "\(server).tool_timeout_sec=\(Self.toolTimeoutSeconds)",
            ]
        } else if let mcpServerPath {
            arguments += ["-c", "\(server).command=\(Self.tomlString(mcpServerPath))"]
        }
        if bridge != nil || mcpServerPath != nil {
            // `codex exec` never asks for approval, so Codex refuses every MCP call that
            // needs one. Momo asks the user itself before anything irreversible, so its tools
            // are pre-approved for Codex.
            arguments += ["-c", #"\#(server).default_tools_approval_mode="approve""#]
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
                let bridge = ToolBridge.start(
                    tools: request.tools, relayPath: mcpServerPath, runTool: runTool,
                    report: { continuation.yield($0) })
                defer { bridge?.stop() }
                let images = Self.writeImages(of: request)
                defer { if let images { try? FileManager.default.removeItem(at: images.folder) } }
                let prompt = CLIPrompt.make(
                    request, hasTools: bridge != nil || mcpServerPath != nil,
                    imagesVisible: images != nil)
                var parser = CodexEventParser(
                    bridgedServer: bridge.map { _ in ToolBridge.serverName })
                // Codex saves the images it draws in its home folder without mentioning them in
                // its events, so each turn's folder is watched for new ones.
                var generated = CodexGeneratedImages(home: Self.home)
                func drawnImages(_ thread: String?) -> [ChatEvent] {
                    guard let thread else { return [] }
                    return generated.newImages(thread: thread).map {
                        .artifact(ChatArtifact(url: $0))
                    }
                }
                do {
                    for try await line in CommandRunner.lines(
                        executable: executable,
                        arguments: Self.adding(
                            images: images?.paths ?? [],
                            to: arguments(bridge: bridge?.launch, fast: request.prefersSpeed)),
                        input: prompt, workingDirectory: workingDirectory)
                    {
                        for event in try parser.consume(line) { continuation.yield(event) }
                        for image in drawnImages(parser.threadID) { continuation.yield(image) }
                    }
                    for image in drawnImages(parser.threadID) { continuation.yield(image) }
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

    /// A TOML basic string, with backslashes, quotes and control characters escaped.
    static func tomlString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\r": escaped += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                escaped += String(format: "\\u%04X", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "\""
    }

    /// A TOML array of strings.
    static func tomlArray(_ values: [String]) -> String {
        "[" + values.map(tomlString).joined(separator: ", ") + "]"
    }
}

// MARK: - Images

extension CodexProvider {
    /// Writes the latest turn's images to a private temporary folder for `codex exec -i`.
    /// `nil` when there are none or they could not be written.
    static func writeImages(of request: ChatRequest) -> (folder: URL, paths: [String])? {
        let images = request.turns.last?.images ?? []
        guard !images.isEmpty else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-images-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let paths = try images.enumerated().map { index, image in
                let suffix = image.mimeType == "image/png" ? "png" : "jpg"
                let url = folder.appendingPathComponent("image-\(index + 1).\(suffix)")
                try image.data.write(to: url, options: [.atomic])
                return url.path
            }
            return (folder, paths)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    /// Adds `-i` with the image paths right after `exec`, where a following option ends the
    /// list, so it can't swallow the prompt argument.
    static func adding(images paths: [String], to arguments: [String]) -> [String] {
        guard !paths.isEmpty, let exec = arguments.firstIndex(of: "exec") else { return arguments }
        var arguments = arguments
        arguments.insert(contentsOf: ["-i", paths.joined(separator: ",")], at: exec + 1)
        return arguments
    }
}

/// Finds the images Codex saves under `generated_images/<thread>` in its home folder.
struct CodexGeneratedImages {
    let home: URL
    private var seen: Set<String> = []

    init(home: URL) {
        self.home = home
    }

    /// Images in the thread's folder that were not reported yet, oldest first.
    mutating func newImages(thread: String) -> [URL] {
        let folder = home.appendingPathComponent("generated_images", isDirectory: true)
            .appendingPathComponent(thread, isDirectory: true)
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
        let images =
            files
            .filter { ChatArtifact(url: $0).kind == .image && !seen.contains($0.path) }
            .sorted { lhs, rhs in
                let date: (URL) -> Date = {
                    (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                }
                return date(lhs) < date(rhs)
            }
        seen.formUnion(images.map(\.path))
        return images
    }
}

/// Reads the JSON Lines events of `codex exec --json`.
struct CodexEventParser {
    /// The MCP server whose calls the ``ToolBridge`` already reports; their events are
    /// skipped so each call shows once.
    var bridgedServer: String?
    private(set) var lastError: String?
    /// The id of the Codex thread, which names the folder its generated images go to.
    private(set) var threadID: String?
    private var messageCount = 0
    private var startedSearches: Set<String> = []

    init(bridgedServer: String? = nil) {
        self.bridgedServer = bridgedServer
    }

    mutating func consume(_ line: String) throws -> [ChatEvent] {
        guard let event = try? JSONValue.parse(line), let type = event["type"]?.stringValue else {
            return []
        }
        let item = event["item"]
        switch (type, item?["type"]?.stringValue) {
        case ("thread.started", _):
            threadID = event["thread_id"]?.stringValue
            return []
        case ("item.started", "command_execution"):
            return [.toolStarted(Self.command(item))]
        case ("item.completed", "command_execution"):
            let call = Self.command(item)
            let failed = item?["status"]?.stringValue == "failed"
            return [
                .toolFinished(
                    ToolResult(callID: call.id, name: call.name, output: "", isError: failed))
            ]
        case ("item.completed", "agent_message"):
            guard let text = item?["text"]?.stringValue, !text.isEmpty else { return [] }
            defer { messageCount += 1 }
            return [.text(messageCount == 0 ? text : "\n\n" + text)]
        case ("item.started", "mcp_tool_call"):
            guard !isBridged(item) else { return [] }
            return [.toolStarted(Self.toolCall(item))]
        case ("item.completed", "mcp_tool_call"):
            guard !isBridged(item) else { return [] }
            let call = Self.toolCall(item)
            let failed = item?["status"]?.stringValue == "failed"
            return [
                .toolFinished(
                    ToolResult(
                        callID: call.id, name: call.name,
                        output: item?["result"]?.jsonString ?? "", isError: failed))
            ]
        case ("item.started", "web_search"):
            let id = item?["id"]?.stringValue ?? ""
            startedSearches.insert(id)
            return [.toolStarted(Self.webSearch(item))]
        case ("item.completed", "web_search"):
            let id = item?["id"]?.stringValue ?? ""
            let call = Self.webSearch(item)
            let finished = ChatEvent.toolFinished(
                ToolResult(callID: call.id, name: call.name, output: ""))
            // Some versions only report the finished search.
            return startedSearches.remove(id) == nil ? [.toolStarted(call), finished] : [finished]
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

    private func isBridged(_ item: JSONValue?) -> Bool {
        guard let bridgedServer else { return false }
        return item?["server"]?.stringValue == bridgedServer
    }

    private static func toolCall(_ item: JSONValue?) -> ToolCall {
        ToolCall(
            id: item?["id"]?.stringValue ?? ShortID.make(),
            name: item?["tool"]?.stringValue ?? "tool",
            arguments: item?["arguments"]?.jsonString ?? "{}")
    }

    /// A shell command Codex ran, shown as a step. Reading one of Codex's own skill files is
    /// shown as getting ready, with the skill's name, rather than as a raw command.
    static func command(_ item: JSONValue?) -> ToolCall {
        let id = item?["id"]?.stringValue ?? ShortID.make()
        var command = item?["command"]?.stringValue ?? ""
        // `/bin/zsh -lc '…'` wraps every command; show what runs inside.
        if let open = command.firstIndex(of: "'"), let close = command.lastIndex(of: "'"),
            open < close, command.hasPrefix("/bin/")
        {
            command = String(command[command.index(after: open)..<close])
        }
        let parts = command.split(separator: "/")
        if let skills = parts.firstIndex(of: "skills"), command.hasSuffix("SKILL.md"),
            parts.count > skills + 2
        {
            let skill = String(parts[parts.count - 2])
            return ToolCall(
                id: id, name: "codex_skill",
                arguments: (["name": .string(skill)] as JSONValue).jsonString)
        }
        return ToolCall(
            id: id, name: "run_command",
            arguments: (["command": .string(command)] as JSONValue).jsonString)
    }

    private static func webSearch(_ item: JSONValue?) -> ToolCall {
        let query = item?["query"]?.stringValue ?? ""
        return ToolCall(
            id: item?["id"]?.stringValue ?? ShortID.make(), name: "web_search",
            arguments: (["query": .string(query)] as JSONValue).jsonString)
    }
}

/// Uses the user's Google account (and their Google AI plan, if they have one) through the
/// official Gemini CLI, signed in with Google. It never uses a Gemini API key, which would be
/// billed separately.
///
/// Momo's tools reach the CLI through a ``ToolBridge`` described in a generated settings file
/// (see ``GeminiCLIProvider/settings(bridge:)``). The CLI's own file and shell tools are
/// excluded; its Google web search stays available.
public struct GeminiCLIProvider: ChatProvider {
    public let info = ProviderInfo(id: "gemini-cli", name: "Gemini (CLI)", kind: .subscription)
    public let model: String?
    /// Path to the `momo-mcp` executable, which the CLI launches to reach Momo's tools.
    public let mcpServerPath: String?
    private let workingDirectory: URL

    public init(model: String? = nil, mcpServerPath: String? = nil, workingDirectory: URL) {
        self.model = model?.isEmpty == true ? nil : model
        self.mcpServerPath = mcpServerPath
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

    /// Built-in Gemini CLI tools Momo never offers: they change files, run commands or write
    /// the CLI's own memory. Momo has its own tools for all of that, with confirmation.
    static let excludedTools = [
        "run_shell_command", "write_file", "replace", "edit", "save_memory", "write_todos",
    ]

    /// How long the CLI waits for one Momo tool call, in milliseconds: long enough for the
    /// user to answer a confirmation question.
    static let toolTimeoutMilliseconds = 600_000

    /// The settings file for one run, in the current (v2, nested) settings format.
    ///
    /// The Momo server is trusted because Momo asks for confirmation itself; in non-interactive
    /// runs the CLI would otherwise deny every call that needs approval. Only the Momo server
    /// is allowed, so tools that bypass Momo's confirmation never reach the model.
    static func settings(bridge: MCPLaunch?) -> JSONValue {
        var settings: [String: JSONValue] = [
            "tools": ["exclude": .array(excludedTools.map { .string($0) })]
        ]
        if let bridge {
            settings["mcpServers"] = [
                ToolBridge.serverName: [
                    "command": .string(bridge.command),
                    "args": .array(bridge.arguments.map { .string($0) }),
                    "trust": true,
                    "timeout": .number(Double(toolTimeoutMilliseconds)),
                ]
            ]
            settings["mcp"] = ["allowed": [.string(ToolBridge.serverName)]]
        }
        return .object(settings)
    }

    /// Writes `settings` to `<workspace>/.gemini/settings.json` and returns its location.
    static func writeSettings(_ settings: JSONValue, in workspace: URL) throws -> URL {
        let folder = workspace.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("settings.json")
        try Data(settings.jsonString.utf8).write(to: file, options: .atomic)
        return file
    }

    func arguments(format: String) -> [String] {
        var arguments = ["--output-format", format]
        if let model { arguments += ["-m", model] }
        return arguments
    }

    /// The environment for a run: always the Google sign-in, never an API key from the
    /// environment, and Momo's settings file.
    static func environment(settingsFile: URL?) -> [String: String] {
        var environment = ["GOOGLE_GENAI_USE_GCA": "true", "GEMINI_API_KEY": ""]
        // Workspace settings are ignored in folders the user has not trusted, so the file is
        // also passed as the system settings layer, which is always read and wins over the
        // user's own settings for the keys it sets.
        if let settingsFile { environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] = settingsFile.path }
        return environment
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
                let bridge = ToolBridge.start(
                    tools: request.tools, relayPath: mcpServerPath, runTool: runTool,
                    report: { continuation.yield($0) })
                defer { bridge?.stop() }
                let settingsFile = try? Self.writeSettings(
                    Self.settings(bridge: bridge?.launch), in: workingDirectory)
                let environment = Self.environment(settingsFile: settingsFile)
                let prompt = CLIPrompt.make(request, hasTools: bridge != nil)
                var parser = GeminiStreamParser(
                    bridgedServer: bridge.map { _ in ToolBridge.serverName },
                    bridgedTools: Set(bridge == nil ? [] : request.tools.map(\.name)))
                var output = ""
                do {
                    for try await line in CommandRunner.lines(
                        executable: executable, arguments: arguments(format: "stream-json"),
                        input: prompt, workingDirectory: workingDirectory,
                        environment: environment)
                    {
                        if output.count < 64_000 { output += line + "\n" }
                        for event in try parser.consume(line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch let failure as CommandRunner.Failure
                    where !parser.sawEvents && Self.rejectsStreamJSON(failure.standardError)
                {
                    // An older CLI without streaming output: ask for one JSON answer.
                    do {
                        let text = try await answer(
                            executable: executable, prompt: prompt, environment: environment)
                        continuation.yield(.text(text))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch let failure as CommandRunner.Failure {
                    let message = parser.lastError ?? Self.errorMessage(in: output)
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

    /// Runs the CLI with `--output-format json` and returns the reply.
    private func answer(
        executable: URL, prompt: String, environment: [String: String]
    ) async throws -> String {
        var output = ""
        do {
            for try await line in CommandRunner.lines(
                executable: executable, arguments: arguments(format: "json"), input: prompt,
                workingDirectory: workingDirectory, environment: environment)
            {
                output += line + "\n"
            }
            return try Self.parse(output)
        } catch let failure as CommandRunner.Failure {
            throw ProviderError(
                Self.errorMessage(in: output) ?? CLIPrompt.describe(failure, tool: "Gemini CLI"))
        }
    }

    /// Whether the CLI refused `--output-format stream-json` because it is too old.
    static func rejectsStreamJSON(_ standardError: String) -> Bool {
        standardError.contains("stream-json")
            && (standardError.localizedCaseInsensitiveContains("invalid")
                || standardError.localizedCaseInsensitiveContains("choices"))
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

/// Reads the JSON Lines events of `gemini --output-format stream-json`: streamed reply text
/// and the CLI's own tool calls (such as Google Search).
struct GeminiStreamParser {
    /// The MCP server whose calls the ``ToolBridge`` already reports.
    var bridgedServer: String?
    /// Tool names the bridge serves; older CLIs report MCP tools without a prefix.
    var bridgedTools: Set<String>
    private(set) var lastError: String?
    /// Whether any event was understood, which shows the CLI supports streaming output.
    private(set) var sawEvents = false
    /// Names of the running tool calls the parser reported, by tool call ID.
    private var runningTools: [String: String] = [:]
    private var hasText = false
    private var toolSinceText = false

    init(bridgedServer: String? = nil, bridgedTools: Set<String> = []) {
        self.bridgedServer = bridgedServer
        self.bridgedTools = bridgedTools
    }

    mutating func consume(_ line: String) throws -> [ChatEvent] {
        guard let event = try? JSONValue.parse(line), let type = event["type"]?.stringValue else {
            return []
        }
        sawEvents = true
        switch type {
        case "message":
            guard event["role"]?.stringValue == "assistant",
                let content = event["content"]?.stringValue, !content.isEmpty
            else { return [] }
            // Separate the text before and after tool calls.
            let text = hasText && toolSinceText ? "\n\n" + content : content
            hasText = true
            toolSinceText = false
            return [.text(text)]
        case "tool_use":
            toolSinceText = true
            let name = event["tool_name"]?.stringValue ?? "tool"
            guard !isBridged(name) else { return [] }
            let id = event["tool_id"]?.stringValue ?? ShortID.make()
            runningTools[id] = name
            return [
                .toolStarted(
                    ToolCall(
                        id: id, name: name, arguments: event["parameters"]?.jsonString ?? "{}"))
            ]
        case "tool_result":
            toolSinceText = true
            guard let id = event["tool_id"]?.stringValue,
                let name = runningTools.removeValue(forKey: id)
            else { return [] }
            let failed = event["status"]?.stringValue == "error"
            let output =
                event["output"]?.stringValue ?? event["error"]?["message"]?.stringValue ?? ""
            return [
                .toolFinished(ToolResult(callID: id, name: name, output: output, isError: failed))
            ]
        case "error":
            if event["severity"]?.stringValue != "warning",
                let message = event["message"]?.stringValue
            {
                lastError = "Gemini CLI: \(message)"
            }
            return []
        case "result":
            guard event["status"]?.stringValue == "error" else { return [] }
            let message =
                event["error"]?["message"]?.stringValue ?? lastError ?? "The Gemini CLI failed."
            lastError = message.hasPrefix("Gemini CLI") ? message : "Gemini CLI: \(message)"
            throw ProviderError(lastError ?? message)
        default:
            return []
        }
    }

    private func isBridged(_ name: String) -> Bool {
        guard let bridgedServer else { return false }
        return name.hasPrefix("mcp_\(bridgedServer)_") || name.hasPrefix("\(bridgedServer)__")
            || bridgedTools.contains(name)
    }
}

/// Builds single-shot prompts for CLI agents and explains their failures.
enum CLIPrompt {
    /// - Parameters:
    ///   - hasTools: Whether the CLI can reach Momo's tools through the `momo` MCP server.
    ///   - imagesVisible: Whether the CLI receives the attached images itself.
    static func make(
        _ request: ChatRequest, hasTools: Bool = false, imagesVisible: Bool = false
    ) -> String {
        let bridge =
            hasTools
            ? """
            You are answering through a command line bridge. To act for the user (tasks, \
            notes, memories, calendar, apps, their connected services and more), call the \
            tools of the "momo" MCP server: they run inside Momo on the user's Mac, and Momo \
            asks the user before anything irreversible, so use them directly instead of \
            describing what you would do or telling the user to do it. Use web search for \
            current information. Never modify files or run shell commands.
            """
            : """
            You are answering through a command line bridge. Do not modify files or run shell \
            commands; just answer.
            """
        return """
            \(request.systemPrompt)

            \(bridge)

            \(PromptFlattener.prompt(
                for: request.turns, budget: 60_000, imagesVisible: imagesVisible))
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
