import MomoKit
import SwiftUI

/// A group of Momo's built-in tools that the user can turn off, or have Momo always ask
/// before using, in Settings → Abilities. Tools from MCP servers are grouped by server
/// instead, with the switches in their ``MCPServerConfiguration``.
enum ToolGroup: String, CaseIterable, Identifiable {
    case tasks
    case calendar
    case files
    case communication
    case music
    case system
    case web
    case screen
    case power
    case meetings
    case routines
    /// Tools other tools rely on, such as the current time. Always available and not shown.
    case essentials

    var id: String { rawValue }

    /// The groups shown in Settings, in order.
    static var visible: [ToolGroup] { allCases.filter { $0 != .essentials } }

    /// Which group each built-in tool belongs to. Every tool Momo offers must be listed; a
    /// test checks it.
    static let toolNames: [String: ToolGroup] = [
        "add_task": .tasks, "list_tasks": .tasks, "complete_task": .tasks,
        "update_task": .tasks, "delete_task": .tasks, "add_note": .tasks,
        "search_notes": .tasks, "append_to_note": .tasks, "delete_note": .tasks,
        "log_habit": .tasks, "list_habits": .tasks, "remember": .tasks,
        "list_memories": .tasks, "forget": .tasks, "start_focus": .tasks,
        "calendar_events": .calendar, "add_calendar_event": .calendar,
        "list_reminders": .calendar, "add_reminder": .calendar, "complete_reminder": .calendar,
        "find_files": .files, "read_file": .files, "list_folder": .files,
        "reveal_in_finder": .files, "move_to_trash": .files,
        "search_contacts": .communication, "compose_email": .communication,
        "send_message": .communication,
        "control_music": .music,
        "open_app": .system, "open_url": .system, "list_shortcuts": .system,
        "run_shortcut": .system, "system_volume": .system, "set_dark_mode": .system,
        "sleep_display": .system, "lock_screen": .system, "quit_app": .system,
        "system_status": .system,
        "web_search": .web, "read_web_page": .web, "get_weather": .web,
        "read_screen": .screen, "get_context": .screen, "get_clipboard": .screen,
        "run_applescript": .power, "run_shell_command": .power,
        "start_meeting_notes": .meetings, "stop_meeting_notes": .meetings,
        "list_meetings": .meetings, "get_meeting": .meetings,
        "meeting_action_items_to_tasks": .meetings,
        "add_routine": .routines, "list_routines": .routines, "update_routine": .routines,
        "delete_routine": .routines,
        "current_time": .essentials,
    ]

    static func group(for toolName: String) -> ToolGroup? {
        toolNames[toolName]
    }

    var title: String {
        switch self {
        case .tasks: L("Tasks, notes & memory")
        case .calendar: L("Calendar & reminders")
        case .files: L("Files")
        case .communication: L("Mail, Messages & contacts")
        case .music: L("Music")
        case .system: L("System controls")
        case .web: L("Web")
        case .screen: L("Screen & context")
        case .power: L("Power tools (AppleScript & shell)")
        case .meetings: L("Meetings")
        case .routines: L("Routines")
        case .essentials: L("Essentials")
        }
    }

    /// What the group lets Momo do, in one line.
    var summary: String {
        switch self {
        case .tasks: L("Add and complete tasks, keep notes and habits, remember things for you.")
        case .calendar: L("Read your calendar, add events, and use the Reminders app.")
        case .files: L("Find, read and show files, and move them to the Trash when you agree.")
        case .communication:
            L("Look up contacts, draft emails and send messages you confirm.")
        case .music: L("Play, pause and skip in Music or Spotify, and say what's playing.")
        case .system:
            L("Open apps and links, run Shortcuts, change volume or dark mode, lock the screen.")
        case .web: L("Search the web, read web pages and check the weather.")
        case .screen: L("See what you're working on: the front app, selected text, your screen.")
        case .power: L("Run AppleScript and shell commands. Momo always asks first.")
        case .meetings: L("Start and stop meeting notes, and read past meetings.")
        case .routines: L("Set up, change and remove routines when you ask.")
        case .essentials: L("Tools other tools rely on, such as the current time.")
        }
    }

    var systemImage: String {
        switch self {
        case .tasks: "checklist"
        case .calendar: "calendar"
        case .files: "folder.fill"
        case .communication: "envelope.fill"
        case .music: "music.note"
        case .system: "switch.2"
        case .web: "globe"
        case .screen: "macwindow"
        case .power: "terminal.fill"
        case .meetings: "person.2.wave.2.fill"
        case .routines: "clock.arrow.circlepath"
        case .essentials: "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .tasks: Color(red: 0.2, green: 0.74, blue: 0.62)
        case .calendar: Color(red: 1.0, green: 0.45, blue: 0.3)
        case .files: Color(red: 0.25, green: 0.55, blue: 0.98)
        case .communication: Color(red: 0.3, green: 0.6, blue: 0.95)
        case .music: Color(red: 0.98, green: 0.36, blue: 0.47)
        case .system: .gray
        case .web: Color(red: 0.36, green: 0.7, blue: 0.95)
        case .screen: Color(red: 0.55, green: 0.42, blue: 0.98)
        case .power: Color(red: 0.3, green: 0.3, blue: 0.35)
        case .meetings: Color(red: 0.95, green: 0.55, blue: 0.2)
        case .routines: Color(red: 0.36, green: 0.7, blue: 0.95)
        case .essentials: .gray
        }
    }

    /// The macOS permissions the group's tools need, each for some of them.
    var permissions: [MacPermission] {
        switch self {
        case .calendar: [.calendars, .reminders]
        case .communication:
            [.contacts, .automation("com.apple.mail"), .automation("com.apple.MobileSMS")]
        case .music: [.automation("com.apple.Music"), .automation("com.spotify.client")]
        case .system: [.automation("com.apple.systemevents"), .location]
        case .screen: [.screenRecording, .accessibility]
        case .power: [.automation(nil)]
        case .meetings: [.microphone, .speechRecognition, .screenRecording]
        case .tasks, .files, .web, .routines, .essentials: []
        }
    }

    /// Every tool of the group asks before running, so "always ask" changes nothing.
    var alwaysAsks: Bool { self == .power }

    /// Whether the user can turn the group off.
    var canBeTurnedOff: Bool { self != .essentials }
}

/// Which tool groups the user turned off or wants Momo to ask about first. Stored by group
/// id, so a group that no longer exists is ignored.
struct AbilitySettings: Codable, Equatable {
    var disabledGroups: Set<String> = []
    var alwaysAskGroups: Set<String> = []

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disabledGroups =
            (try? container.decodeIfPresent(Set<String>.self, forKey: .disabledGroups)) ?? []
        alwaysAskGroups =
            (try? container.decodeIfPresent(Set<String>.self, forKey: .alwaysAskGroups)) ?? []
    }

    func isEnabled(_ group: ToolGroup) -> Bool {
        !group.canBeTurnedOff || !disabledGroups.contains(group.id)
    }

    func alwaysAsks(_ group: ToolGroup) -> Bool {
        group.alwaysAsks || alwaysAskGroups.contains(group.id)
    }

    mutating func setEnabled(_ group: ToolGroup, _ enabled: Bool) {
        if enabled { disabledGroups.remove(group.id) } else { disabledGroups.insert(group.id) }
    }

    mutating func setAlwaysAsks(_ group: ToolGroup, _ asks: Bool) {
        if asks { alwaysAskGroups.insert(group.id) } else { alwaysAskGroups.remove(group.id) }
    }

    /// The tools Momo may offer: those of turned-off groups are left out, and those of
    /// "always ask" groups need approval for every call. Tools without a group, like MCP
    /// servers' tools, pass unchanged.
    func apply(to tools: [any MomoTool]) -> [any MomoTool] {
        tools.compactMap { tool in
            let definition = tool.definition
            guard let group = ToolGroup.group(for: definition.name) else { return tool }
            guard isEnabled(group) else { return nil }
            guard alwaysAsks(group), !definition.requiresConfirmation else { return tool }
            return ConfirmingTool(
                tool, label: definition.activityLabel ?? ToolActivity.label(for: definition.name))
        }
    }
}
