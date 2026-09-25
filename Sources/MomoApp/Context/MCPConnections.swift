import Foundation
import MomoBrain
import MomoKit
import MomoMCP
import Observation

/// An MCP server the user connected, whose tools Momo can use.
struct MCPServerConfiguration: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var command: String
    var arguments: [String] = []
    var isEnabled = true
    /// Ask before each tool call; on by default because other servers' tools may change things.
    var asksBeforeUse = true
}

/// Connects to the user's MCP servers and offers their tools to the assistant.
@MainActor
@Observable
final class MCPConnections {
    enum Status: Equatable {
        case connecting
        case connected(toolCount: Int)
        case failed(String)
    }

    private(set) var statuses: [UUID: Status] = [:]
    @ObservationIgnored private var clients:
        [UUID: (MCPServerConfiguration, MCPClient, [MCPClient.RemoteTool])] = [:]
    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Tools from every connected, enabled server.
    var tools: [any MomoTool] {
        settings.preferences.mcpServers.filter(\.isEnabled).flatMap {
            configuration -> [any MomoTool] in
            guard let (connected, client, tools) = clients[configuration.id],
                connected == configuration
            else { return [] }
            let prefix = configuration.name.isEmpty ? "mcp" : configuration.name
            return tools.map {
                MCPRemoteTool(
                    tool: $0, client: client, prefix: prefix,
                    requiresConfirmation: configuration.asksBeforeUse)
            }
        }
    }

    /// Connects new or changed servers and disconnects removed ones.
    func refresh() async {
        let configurations = settings.preferences.mcpServers
        for (id, entry) in clients
        where !configurations.contains(where: { $0.id == id && $0 == entry.0 && $0.isEnabled }) {
            await entry.1.close()
            clients[id] = nil
            statuses[id] = nil
        }
        for configuration in configurations
        where configuration.isEnabled && clients[configuration.id] == nil {
            statuses[configuration.id] = .connecting
            do {
                let command = Self.resolve(configuration.command)
                let transport = try ProcessTransport(
                    command: command, arguments: configuration.arguments,
                    environment: ["PATH": CommandLocator.searchPath])
                let client = MCPClient(transport: transport)
                try await client.connect()
                let tools = try await client.listTools()
                clients[configuration.id] = (configuration, client, tools)
                statuses[configuration.id] = .connected(toolCount: tools.count)
            } catch {
                statuses[configuration.id] = .failed(error.localizedDescription)
            }
        }
    }

    /// Finds bare command names (like `npx`) on the user's PATH.
    private static func resolve(_ command: String) -> String {
        if command.contains("/") { return (command as NSString).expandingTildeInPath }
        return CommandLocator.locate(command)?.path ?? command
    }
}
