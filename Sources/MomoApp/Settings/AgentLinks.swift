import Foundation
import MomoBrain

/// Adds Momo's MCP server to agents the user already has, so they can use Momo's tasks, notes
/// and memories. Each agent is set up the way it expects, without Terminal.
enum AgentLink: String, CaseIterable, Identifiable {
    case claudeDesktop, claudeCode, codex

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Whether the agent is installed on this Mac.
    var isInstalled: Bool {
        switch self {
        case .claudeDesktop:
            FileManager.default.fileExists(atPath: "/Applications/Claude.app")
                || FileManager.default.fileExists(
                    atPath: Self.claudeDesktopConfig.deletingLastPathComponent().path)
        case .claudeCode: CommandLocator.locate("claude") != nil
        case .codex: CodexSetup.locate() != nil
        }
    }

    /// Whether Momo is already connected to the agent.
    func isLinked() async -> Bool {
        switch self {
        case .claudeDesktop:
            return (Self.readClaudeDesktopConfig()["mcpServers"] as? [String: Any])?["momo"] != nil
        case .claudeCode:
            guard let claude = CommandLocator.locate("claude") else { return false }
            return await ToolCommand.succeeds(claude, ["mcp", "get", "momo"])
        case .codex:
            guard let codex = CodexSetup.locate() else { return false }
            return await ToolCommand.succeeds(codex, ["mcp", "get", "momo"])
        }
    }

    /// Connects Momo to the agent. Returns whether it worked.
    func link(serverPath: String) async -> Bool {
        switch self {
        case .claudeDesktop:
            return Self.addToClaudeDesktop(serverPath: serverPath)
        case .claudeCode:
            guard let claude = CommandLocator.locate("claude") else { return false }
            return await ToolCommand.succeeds(
                claude, ["mcp", "add", "--scope", "user", "momo", "--", serverPath])
        case .codex:
            guard let codex = CodexSetup.locate() else { return false }
            return await ToolCommand.succeeds(codex, ["mcp", "add", "momo", "--", serverPath])
        }
    }

    // MARK: - Claude Desktop

    static var claudeDesktopConfig: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static func readClaudeDesktopConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: claudeDesktopConfig),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    /// Adds Momo to `mcpServers` in Claude Desktop's config, keeping everything else and a
    /// backup of the previous file.
    static func addToClaudeDesktop(serverPath: String) -> Bool {
        let url = claudeDesktopConfig
        let fileManager = FileManager.default
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            // Never overwrite a config Momo can't read.
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            config = parsed
            try? fileManager.removeItem(at: url.appendingPathExtension("momo-backup"))
            try? fileManager.copyItem(at: url, to: url.appendingPathExtension("momo-backup"))
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["momo"] = ["command": serverPath]
        config["mcpServers"] = servers
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
