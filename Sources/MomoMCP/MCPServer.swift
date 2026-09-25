import Foundation
import MomoKit

/// A Model Context Protocol server that offers a toolbox to other agents (Claude Desktop,
/// Claude Code, Codex, ...). Speaks JSON-RPC 2.0; see ``MCPStdioServer`` for the transport.
public struct MCPServer: Sendable {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public var name: String
    public var version: String
    public var instructions: String
    private let toolbox: Toolbox
    /// Whether tools that need confirmation are offered. The calling agent is then
    /// responsible for asking the user.
    private let allowsConfirmationTools: Bool

    public init(
        toolbox: Toolbox, name: String = "momo", version: String = "0.1.0",
        instructions: String = "", allowsConfirmationTools: Bool = false
    ) {
        self.toolbox = toolbox
        self.name = name
        self.version = version
        self.instructions = instructions
        self.allowsConfirmationTools = allowsConfirmationTools
    }

    private var offeredTools: [ToolDefinition] {
        toolbox.definitions.filter { allowsConfirmationTools || !$0.requiresConfirmation }
    }

    /// Handles one JSON-RPC message. Returns the response, or `nil` for notifications.
    public func handle(_ message: JSONValue) async -> JSONValue? {
        let id = message["id"]
        guard let method = message["method"]?.stringValue else {
            return id.map { Self.error(id: $0, code: -32600, message: "Invalid request") }
        }
        guard let id else {
            // Notifications (such as notifications/initialized) need no answer.
            return nil
        }
        let params = message["params"] ?? .object([:])
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version =
                Self.supportedProtocolVersions.contains(requested)
                ? requested : Self.supportedProtocolVersions[0]
            var result: [String: JSONValue] = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "version": .string(self.version)],
            ]
            if !instructions.isEmpty { result["instructions"] = .string(instructions) }
            return Self.result(id: id, .object(result))
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            let tools: [JSONValue] = offeredTools.map { tool in
                [
                    "name": .string(tool.name), "description": .string(tool.description),
                    "inputSchema": tool.parameters,
                ]
            }
            return Self.result(id: id, ["tools": .array(tools)])
        case "tools/call":
            guard let toolName = params["name"]?.stringValue,
                offeredTools.contains(where: { $0.name == toolName })
            else {
                return Self.error(id: id, code: -32602, message: "Unknown tool")
            }
            let arguments = params["arguments"] ?? .object([:])
            let result = await toolbox.execute(
                ToolCall(id: ShortID.make(), name: toolName, arguments: arguments.jsonString),
                confirm: { _ in allowsConfirmationTools })
            return Self.result(
                id: id,
                [
                    "content": [["type": "text", "text": .string(result.output)]],
                    "isError": .bool(result.isError),
                ])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        [
            "jsonrpc": "2.0", "id": id,
            "error": ["code": .number(Double(code)), "message": .string(message)],
        ]
    }
}

/// Serves an ``MCPServer`` over standard input and output, one JSON message per line.
public enum MCPStdioServer {
    public static func run(_ server: MCPServer) async {
        let output = FileHandle.standardOutput
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let response: JSONValue?
                if let message = try? JSONValue.parse(line) {
                    response = await server.handle(message)
                } else {
                    response = MCPServer.error(id: .null, code: -32700, message: "Parse error")
                }
                if let response {
                    output.write(Data((response.jsonString + "\n").utf8))
                }
            }
        } catch {
            FileHandle.standardError.write(Data("momo-mcp: \(error)\n".utf8))
        }
    }
}
