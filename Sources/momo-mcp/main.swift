import Foundation
import MomoKit
import MomoMCP

// momo-mcp: offers Momo's tasks, notes, habits and memories to other agents over MCP.
//
//   momo-mcp                       tools that never need confirmation
//   momo-mcp --allow-destructive   also deleting tasks and notes; the agent must ask first
//   momo-mcp --data <path>         use another data file (for testing)

let arguments = CommandLine.arguments
if arguments.contains("--help") || arguments.contains("-h") {
    print(
        """
        momo-mcp: Momo's MCP server (stdio).

        Options:
          --allow-destructive  Also offer tools that delete data.
          --data <path>        Use a different data file.
        """)
    exit(0)
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
