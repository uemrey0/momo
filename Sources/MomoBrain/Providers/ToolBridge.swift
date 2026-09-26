import Foundation
import MomoKit
import MomoMCP

/// Offers a request's tools to a CLI brain (Codex, Gemini CLI) for the duration of one
/// answer.
///
/// The app serves the tools over MCP on a private Unix socket; the CLI starts
/// `momo-mcp --bridge <socket>`, which relays its stdio to that socket. Every call runs
/// through the provider's ``ToolRunner``, so confirmation prompts, personal data masking and
/// the character's reactions apply exactly as they do for every other brain.
struct ToolBridge: Sendable {
    /// The MCP server name the CLIs see.
    static let serverName = "momo"

    /// The `momo-mcp` executable the CLI launches.
    let relayPath: String
    private let server: MCPSocketServer

    /// The socket the app serves the tools on.
    var socketPath: String { server.socketPath }

    /// Arguments for `momo-mcp` that relay to this bridge.
    var relayArguments: [String] { ["--bridge", socketPath] }

    /// Starts serving `request.tools`. Returns `nil` when there is nothing to serve, no relay
    /// executable, or the socket cannot be created; the brain then answers without Momo's
    /// tools.
    ///
    /// - Parameter report: Receives `toolStarted` and `toolFinished` for every call, so the
    ///   UI shows the activity no matter how the CLI reports it.
    static func start(
        tools: [ToolDefinition], relayPath: String?, runTool: @escaping ToolRunner,
        report: @escaping @Sendable (ChatEvent) -> Void,
        parentDirectory: String? = nil
    ) -> ToolBridge? {
        guard !tools.isEmpty, let relayPath else { return nil }
        let server = MCPServer(
            tools: tools, name: serverName,
            instructions: """
                Momo's tools run inside the Momo app on the user's Mac: tasks, notes, \
                memories, calendar, apps and more. Momo asks the user before anything \
                irreversible, so call them directly when the user asks for something.
                """,
            execute: { call in
                report(.toolStarted(call))
                let result = await runTool(call)
                report(.toolFinished(result))
                return result
            })
        guard let socket = try? MCPSocketServer(server: server, parentDirectory: parentDirectory)
        else { return nil }
        return ToolBridge(relayPath: relayPath, server: socket)
    }

    /// Stops serving and removes the socket.
    func stop() {
        server.stop()
    }

    /// How the CLI starts the relay to this bridge.
    var launch: MCPLaunch { MCPLaunch(command: relayPath, arguments: relayArguments) }
}

/// How a CLI starts an MCP server over stdio.
struct MCPLaunch: Sendable, Equatable {
    var command: String
    var arguments: [String]
}
