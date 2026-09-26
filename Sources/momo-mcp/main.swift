import Foundation
import MomoKit
import MomoMCP

// momo-mcp: offers Momo's tasks, notes, habits and memories to other agents over MCP.
//
//   momo-mcp                       tools that never need confirmation
//   momo-mcp --allow-destructive   also deleting tasks and notes; the agent must ask first
//   momo-mcp --data <path>         use another data file (for testing)
//   momo-mcp --bridge <socket>     relay to the tools the Momo app serves for one request

let arguments = CommandLine.arguments
if arguments.contains("--help") || arguments.contains("-h") {
    print(
        """
        momo-mcp: Momo's MCP server (stdio).

        Options:
          --allow-destructive  Also offer tools that delete data.
          --data <path>        Use a different data file.
          --bridge <socket>    Relay stdio to the tool bridge the Momo app serves on a
                               Unix socket while it answers with a CLI brain. The app
                               then runs every tool, with its confirmations and privacy.
        """)
    exit(0)
}

if let index = arguments.firstIndex(of: "--bridge") {
    guard index + 1 < arguments.count else {
        FileHandle.standardError.write(Data("momo-mcp: --bridge needs a socket path\n".utf8))
        exit(64)
    }
    // A closed pipe should end the relay, not kill it with a signal.
    signal(SIGPIPE, SIG_IGN)
    do {
        try MCPBridgeRelay.run(socketPath: arguments[index + 1])
        exit(0)
    } catch {
        FileHandle.standardError.write(
            Data("momo-mcp: cannot reach the Momo app: \(error.localizedDescription)\n".utf8))
        exit(69)
    }
}

let dataURL: URL
if let index = arguments.firstIndex(of: "--data"), index + 1 < arguments.count {
    dataURL = URL(fileURLWithPath: arguments[index + 1])
} else {
    dataURL = MomoStore.defaultFileURL
}

let store = MomoStore(fileURL: dataURL)
let server = MCPServer(
    toolbox: Toolbox(StoreTools.all(store: store)),
    instructions: """
        Momo is the user's personal assistant on their Mac. Use these tools to read and update \
        the user's tasks, reminders, notes, habits and the facts Momo remembers about them. \
        Changes show up in the Momo app right away.
        """,
    allowsConfirmationTools: arguments.contains("--allow-destructive"))

await MCPStdioServer.run(server)
