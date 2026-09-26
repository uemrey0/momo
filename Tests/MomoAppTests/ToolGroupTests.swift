import Foundation
import MomoKit
import Testing

@testable import MomoApp

@MainActor
@Suite("Tool groups")
struct ToolGroupTests {
    /// Every built-in tool, assembled the way the app offers them.
    static func builtInTools() -> [any MomoTool] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-app-tests-\(UUID().uuidString)")
        let store = MomoStore(fileURL: folder.appendingPathComponent("data.json"))
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "momo-app-tests-\(UUID().uuidString)") ?? .standard)
        let assistant = AssistantController(store: store, settings: settings)
        let calendar = CalendarService()
        let character = CharacterController()
        let meetings = MeetingController(
            store: store, settings: settings, calendar: calendar, assistant: assistant,
            character: character)
        let web = WebTools.all(
            searcher: WebSearcher(braveKey: nil),
            labels: WebTools.Labels(search: "Searching", read: "Reading"))
        return StoreTools.all(store: store) + web + assistant.imageTools()
            + SystemTools.all(calendar: calendar, focus: FocusController(character: character))
            + MacTools.all() + MeetingTools.all(controller: meetings)
    }

    @Test("every built-in tool has a group")
    func everyToolHasAGroup() {
        let names = Self.builtInTools().map(\.definition.name)
        let missing = names.filter { ToolGroup.group(for: $0) == nil }
        #expect(missing.isEmpty, "Add these tools to ToolGroup.toolNames: \(missing)")
    }

    @Test("the table only names tools that exist")
    func noStaleNames() {
        let names = Set(Self.builtInTools().map(\.definition.name))
        let stale = ToolGroup.toolNames.keys.filter { !names.contains($0) }
        #expect(stale.isEmpty, "Remove these names from ToolGroup.toolNames: \(stale)")
    }

    @Test("power tools always ask, so their switch can stay fixed")
    func powerToolsAsk() {
        let power = Self.builtInTools().filter {
            ToolGroup.group(for: $0.definition.name) == .power
        }
        #expect(!power.isEmpty)
        let asking = power.filter { $0.definition.requiresConfirmation }
        #expect(asking.count == power.count)
    }

    @Test("defaults keep every tool as it is")
    func defaultsChangeNothing() {
        let tools = Self.builtInTools()
        let applied = AbilitySettings().apply(to: tools)
        #expect(applied.map(\.definition) == tools.map(\.definition))
    }

    @Test("turned-off groups are left out and essentials stay")
    func disabledGroups() {
        var abilities = AbilitySettings()
        for group in ToolGroup.allCases { abilities.setEnabled(group, false) }
        let names = abilities.apply(to: Self.builtInTools()).map(\.definition.name)
        #expect(names == ["current_time"])
    }

    @Test("always-ask groups need approval, others don't change")
    func alwaysAsk() {
        var abilities = AbilitySettings()
        abilities.setAlwaysAsks(.music, true)
        let applied = abilities.apply(to: Self.builtInTools())
        let music = applied.first { $0.definition.name == "control_music" }
        let tasks = applied.first { $0.definition.name == "add_task" }
        #expect(music?.definition.requiresConfirmation == true)
        #expect(tasks?.definition.requiresConfirmation == false)
    }

    @Test("tools without a group, like MCP servers' tools, pass unchanged")
    func ungroupedTools() {
        let remote = ClosureTool(ToolDefinition(name: "github__search", description: "Search")) {
            _ in ""
        }
        var abilities = AbilitySettings()
        for group in ToolGroup.allCases {
            abilities.setEnabled(group, false)
            abilities.setAlwaysAsks(group, true)
        }
        let applied = abilities.apply(to: [remote])
        #expect(applied.map(\.definition) == [remote.definition])
    }

    @Test("ability settings decode tolerantly")
    func tolerantDecoding() throws {
        let broken = Data(#"{"abilities": "nonsense", "personality": "calm"}"#.utf8)
        let preferences = try JSONDecoder().decode(Preferences.self, from: broken)
        #expect(preferences.abilities == AbilitySettings())
        #expect(preferences.personality == .calm)

        let partial = Data(#"{"abilities": {"disabledGroups": ["web", "gone"]}}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: partial)
        #expect(!decoded.abilities.isEnabled(.web))
        #expect(decoded.abilities.isEnabled(.music))
        #expect(decoded.abilities.alwaysAskGroups.isEmpty)
    }
}
