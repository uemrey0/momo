import Foundation
import MomoKit
import MomoMCP
import Testing

@testable import MomoBrain

@Suite("Tool bridge")
struct ToolBridgeTests {
    private static let toolbox = Toolbox([
        ClosureTool(ToolDefinition(name: "lookup", description: "Finds a contact.")) { arguments in
            "Found \(arguments["name"]?.stringValue ?? "")"
        },
        ClosureTool(
            ToolDefinition(
                name: "delete_everything", description: "Deletes it all.",
                requiresConfirmation: true)
        ) { _ in "Deleted" },
    ])

    @Test("runs calls through the tool runner, with confirmation and masking")
    func roundTrip() async throws {
        let toolbox = Self.toolbox
        let events = LockedBox<[ChatEvent]>([])
        let confirmations = LockedBox<[String]>([])
        // Like Assistant's runner: unmask arguments, confirm, mask the output.
        let runTool: ToolRunner = { call in
            var call = call
            call.arguments = call.arguments.replacingOccurrences(of: "[NAME_1]", with: "Emre")
            var result = await toolbox.execute(call) { request in
                confirmations.append(request.toolName)
                return false
            }
            result.output = result.output.replacingOccurrences(of: "Emre", with: "[NAME_1]")
            return result
        }
        let report: @Sendable (ChatEvent) -> Void = { events.append($0) }
        let started = ToolBridge.start(
            tools: toolbox.definitions, relayPath: "/usr/local/bin/momo-mcp",
            runTool: runTool, report: report)
        let bridge = try #require(started)
        #expect(bridge.relayArguments == ["--bridge", bridge.socketPath])

        let client = MCPClient(transport: try UnixSocketTransport(path: bridge.socketPath))
        try await client.connect()
        // Tools that need confirmation are offered: Momo asks the user itself.
        #expect(try await client.listTools().map(\.name) == ["lookup", "delete_everything"])
        #expect(
            try await client.callTool("lookup", arguments: ["name": "[NAME_1]"]) == "Found [NAME_1]"
        )

        do {
            _ = try await client.callTool("delete_everything", arguments: [:])
            Issue.record("A declined call should fail")
        } catch MCPClient.ClientError.server(let message) {
            #expect(message.contains("declined"))
        }
        #expect(confirmations.value == ["delete_everything"])

        let reported = events.value.map { event -> String in
            switch event {
            case .toolStarted(let call): "started \(call.name)"
            case .toolFinished(let result): "finished \(result.name) \(result.isError)"
            case .text: "text"
            }
        }
        #expect(
            reported == [
                "started lookup", "finished lookup false", "started delete_everything",
                "finished delete_everything true",
            ])

        await client.close()
        bridge.stop()
        #expect(!FileManager.default.fileExists(atPath: bridge.socketPath))
    }

    @Test("does not start without tools or a relay")
    func noBridge() {
        let runTool: ToolRunner = { ToolResult(callID: $0.id, name: $0.name, output: "") }
        #expect(
            ToolBridge.start(
                tools: [], relayPath: "/bin/momo-mcp", runTool: runTool, report: { _ in })
                == nil)
        #expect(
            ToolBridge.start(
                tools: Self.toolbox.definitions, relayPath: nil, runTool: runTool,
                report: { _ in }) == nil)
    }
}

@Suite("CLI bridge configuration")
struct CLIBridgeConfigurationTests {
    private let launch = MCPLaunch(
        command: "/Applications/Momo.app/Contents/MacOS/momo-mcp",
        arguments: ["--bridge", "/tmp/momo-a\"b/mcp.sock"])

    @Test("gives Codex the bridge, a long tool timeout and web search")
    func codexBridge() {
        let provider = CodexProvider(
            mcpServerPath: "/Applications/Momo.app/Contents/MacOS/momo-mcp",
            workingDirectory: URL(fileURLWithPath: "/tmp"))
        let arguments = provider.arguments(bridge: launch)
        #expect(arguments.starts(with: ["exec", "--json"]))
        #expect(arguments.contains("read-only"))
        #expect(arguments.contains(#"web_search="live""#))
        #expect(
            arguments.contains(
                #"mcp_servers.momo.command="/Applications/Momo.app/Contents/MacOS/momo-mcp""#))
        #expect(
            arguments.contains(#"mcp_servers.momo.args=["--bridge", "/tmp/momo-a\"b/mcp.sock"]"#))
        #expect(arguments.contains("mcp_servers.momo.tool_timeout_sec=600"))
        #expect(arguments.last == "-")
        // Every -c is followed by its value.
        for (index, argument) in arguments.enumerated() where argument == "-c" {
            #expect(arguments[index + 1].contains("="))
        }
    }

    @Test("escapes TOML strings")
    func toml() {
        #expect(CodexProvider.tomlString(#"a\b"c"#) == #""a\\b\"c""#)
        #expect(CodexProvider.tomlString("line\nnext\u{1}") == #""line\nnext\u0001""#)
        #expect(CodexProvider.tomlArray(["x", "y z"]) == #"["x", "y z"]"#)
    }

    @Test("skips Codex events for bridged calls and reports its web searches")
    func codexEvents() throws {
        var parser = CodexEventParser(bridgedServer: "momo")
        #expect(
            try parser.consume(
                #"{"type":"item.started","item":{"id":"i1","type":"mcp_tool_call","server":"momo","tool":"add_task","arguments":{}}}"#
            ).isEmpty)
        #expect(
            try parser.consume(
                #"{"type":"item.started","item":{"id":"i2","type":"mcp_tool_call","server":"github","tool":"issues","arguments":{}}}"#
            ).count == 1)
        let search = try parser.consume(
            #"{"type":"item.completed","item":{"id":"s1","type":"web_search","query":"weather"}}"#)
        guard case .toolStarted(let call) = search.first, case .toolFinished = search.last else {
            Issue.record("Expected a started and finished web search")
            return
        }
        #expect(call.name == "web_search")
        #expect(search.count == 2)
        _ = try parser.consume(
            #"{"type":"item.started","item":{"id":"s2","type":"web_search","query":"news"}}"#)
        #expect(
            try parser.consume(
                #"{"type":"item.completed","item":{"id":"s2","type":"web_search","query":"news"}}"#
            ).count == 1)
    }

    @Test("writes Gemini settings with the trusted bridge and without file or shell tools")
    func geminiSettings() throws {
        let settings = GeminiCLIProvider.settings(bridge: launch)
        let momo = try #require(settings["mcpServers"]?["momo"])
        #expect(momo["command"]?.stringValue == launch.command)
        #expect(momo["args"]?.arrayValue?.compactMap(\.stringValue) == launch.arguments)
        #expect(momo["trust"]?.boolValue == true)
        #expect(momo["timeout"]?.intValue == 600_000)
        #expect(settings["mcp"]?["allowed"]?.arrayValue?.compactMap(\.stringValue) == ["momo"])
        let excluded = settings["tools"]?["exclude"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(excluded.contains("run_shell_command"))
        #expect(excluded.contains("write_file"))
        #expect(!excluded.contains("google_web_search"))

        let plain = GeminiCLIProvider.settings(bridge: nil)
        #expect(plain["mcpServers"] == nil)
        #expect(plain["tools"]?["exclude"] != nil)

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-gemini-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = try GeminiCLIProvider.writeSettings(settings, in: workspace)
        #expect(file.path.hasSuffix(".gemini/settings.json"))
        #expect(try JSONValue.parse(String(contentsOf: file, encoding: .utf8)) == settings)

        let environment = GeminiCLIProvider.environment(settingsFile: file)
        #expect(environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] == file.path)
        #expect(environment["GEMINI_API_KEY"] == "")
        #expect(
            GeminiCLIProvider(workingDirectory: workspace).arguments(format: "stream-json")
                == ["--output-format", "stream-json"])
    }

    @Test("streams Gemini text and its own tools, skipping bridged calls")
    func geminiStream() throws {
        var parser = GeminiStreamParser(bridgedServer: "momo", bridgedTools: ["add_task"])
        var events: [ChatEvent] = []
        let lines = [
            "Loaded cached credentials.",
            #"{"type":"init","session_id":"s","model":"gemini-2.5-pro"}"#,
            #"{"type":"message","role":"user","content":"hi"}"#,
            #"{"type":"message","role":"assistant","content":"Let me ","delta":true}"#,
            #"{"type":"message","role":"assistant","content":"check.","delta":true}"#,
            #"{"type":"tool_use","tool_name":"mcp_momo_add_task","tool_id":"t1","parameters":{}}"#,
            #"{"type":"tool_result","tool_id":"t1","status":"success","output":"ok"}"#,
            #"{"type":"tool_use","tool_name":"add_task","tool_id":"t2","parameters":{}}"#,
            #"{"type":"tool_use","tool_name":"google_web_search","tool_id":"t3","parameters":{"query":"x"}}"#,
            #"{"type":"tool_result","tool_id":"t3","status":"success","output":"results"}"#,
            #"{"type":"message","role":"assistant","content":"Done.","delta":true}"#,
            #"{"type":"result","status":"success","stats":{}}"#,
        ]
        for line in lines { events += try parser.consume(line) }
        #expect(parser.sawEvents)
        #expect(events.count == 5)
        #expect(events.first == .text("Let me "))
        #expect(events.last == .text("\n\nDone."))
        guard case .toolStarted(let call) = events[2], case .toolFinished(let result) = events[3]
        else {
            Issue.record("Expected Google Search to be reported")
            return
        }
        #expect(call.name == "google_web_search")
        #expect(result.output == "results")

        var failing = GeminiStreamParser()
        _ = try failing.consume(#"{"type":"error","severity":"warning","message":"slow"}"#)
        #expect(failing.lastError == nil)
        #expect(throws: ProviderError.self) {
            try failing.consume(#"{"type":"result","status":"error","error":{"message":"quota"}}"#)
        }
        #expect(failing.lastError == "Gemini CLI: quota")
    }

    @Test("recognises a Gemini CLI too old for streaming output")
    func oldGemini() {
        #expect(
            GeminiCLIProvider.rejectsStreamJSON(
                #"Invalid values: Argument: output-format, Given: "stream-json", Choices: "text", "json""#
            ))
        #expect(!GeminiCLIProvider.rejectsStreamJSON("Quota exceeded"))
    }

    @Test("tells CLI brains to act through Momo's tools")
    func prompt() {
        let request = ChatRequest(
            systemPrompt: "You are Momo.", turns: [.init(role: .user, text: "Add milk")])
        let withTools = CLIPrompt.make(request, hasTools: true)
        #expect(withTools.contains(#""momo" MCP server"#))
        #expect(withTools.hasSuffix("Add milk"))
        #expect(CLIPrompt.make(request).contains("just answer"))
    }
}
