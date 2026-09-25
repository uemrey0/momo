import AppKit
import Foundation
import MomoKit

/// Tools that act on the Mac itself: calendar, apps, links, Shortcuts, clipboard and focus.
enum SystemTools {
    @MainActor
    static func all(calendar: CalendarService, focus: FocusController) -> [any MomoTool] {
        [
            calendarEvents(calendar), addCalendarEvent(calendar), openApp(), openURL(),
            listShortcuts(), runShortcut(), readClipboard(), startFocus(focus),
        ]
    }

    // MARK: - Calendar

    static func calendarEvents(_ calendar: CalendarService) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "calendar_events",
                description:
                    "List the user's calendar events, starting today. Use it to plan the day or answer questions about their schedule.",
                parameters: JSONSchema.object([
                    "days": JSONSchema.integer("How many days to include, from 1 (today) to 14"),
                    "start": JSONSchema.string("Optional first day, ISO 8601; defaults to today"),
                ]))
        ) { arguments in
            guard calendar.isAuthorized else {
                return "Calendar access is off. The user can allow it in Momo Settings → General."
            }
            let days = min(14, max(1, arguments["days"]?.intValue ?? 1))
            let base =
                arguments["start"]?.stringValue.flatMap { FlexibleDate.parse($0) } ?? Date()
            let start = Calendar.current.startOfDay(for: base)
            let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
            let events = calendar.events(from: start, to: end)
            guard !events.isEmpty else { return "No events." }
            return events.prefix(60).map(CalendarService.describe).joined(separator: "\n")
        }
    }

    static func addCalendarEvent(_ calendar: CalendarService) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "add_calendar_event",
                description: "Add an event to the user's default calendar.",
                parameters: JSONSchema.object(
                    [
                        "title": JSONSchema.string("Event title"),
                        "start": JSONSchema.string("Start, ISO 8601 local time"),
                        "end": JSONSchema.string(
                            "End, ISO 8601 local time; defaults to one hour later"),
                        "notes": JSONSchema.string("Optional notes"),
                    ], required: ["title", "start"]),
                requiresConfirmation: true),
            summary: { arguments in
                let title = arguments["title"]?.stringValue ?? ""
                let start = arguments["start"]?.stringValue ?? ""
                return String(format: L("Add “%@” to your calendar at %@"), title, start)
            }
        ) { arguments in
            guard calendar.isAuthorized else {
                return "Calendar access is off. The user can allow it in Momo Settings → General."
            }
            guard let title = arguments["title"]?.stringValue,
                let start = arguments["start"]?.stringValue.flatMap({ FlexibleDate.parse($0) })
            else {
                throw ToolError("A title and a start time are required.")
            }
            let end =
                arguments["end"]?.stringValue.flatMap { FlexibleDate.parse($0) }
                ?? start.addingTimeInterval(3600)
            let event = try calendar.addEvent(
                title: title, start: start, end: end, notes: arguments["notes"]?.stringValue)
            return "Added \(CalendarService.describe(event))"
        }
    }

    // MARK: - Apps and links

    static func openApp() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "open_app",
                description:
                    "Open an app on the Mac by name, for example Safari, Notes or Spotify.",
                parameters: JSONSchema.object(
                    ["name": JSONSchema.string("The app's name")], required: ["name"]))
        ) { arguments in
            guard let name = arguments["name"]?.stringValue, let url = findApp(named: name) else {
                throw ToolError("I couldn't find an app with that name.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return "Opened \(url.deletingPathExtension().lastPathComponent)."
        }
    }

    static func findApp(named name: String) -> URL? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let folders = [
            "/Applications", "/System/Applications", "/System/Applications/Utilities",
            "/Applications/Utilities", NSHomeDirectory() + "/Applications",
        ]
        var fuzzy: URL?
        for folder in folders {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
                continue
            }
            for item in items where item.hasSuffix(".app") {
                let appName = String(item.dropLast(4)).lowercased()
                let url = URL(fileURLWithPath: folder).appendingPathComponent(item)
                if appName == wanted { return url }
                if fuzzy == nil, appName.contains(wanted) { fuzzy = url }
            }
        }
        return fuzzy
    }

    static func openURL() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "open_url",
                description: "Open a web page or a mailto: link in the user's default app.",
                parameters: JSONSchema.object(
                    ["url": JSONSchema.string("An https, http or mailto URL")], required: ["url"]))
        ) { arguments in
            guard let text = arguments["url"]?.stringValue, let url = URL(string: text),
                let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme)
            else {
                throw ToolError("Only web and mailto links can be opened.")
            }
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return "Opened \(text)."
        }
    }

    // MARK: - Shortcuts

    static func listShortcuts() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "list_shortcuts",
                description: "List the user's Shortcuts, to find one to run.")
        ) { _ in
            let output = try await shortcuts(["list"])
            return output.isEmpty ? "The user has no shortcuts." : output
        }
    }

    static func runShortcut() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "run_shortcut",
                description: "Run one of the user's Shortcuts by its exact name.",
                parameters: JSONSchema.object(
                    ["name": JSONSchema.string("The shortcut's name")], required: ["name"]),
                requiresConfirmation: true),
            summary: {
                String(format: L("Run the shortcut “%@”"), $0["name"]?.stringValue ?? "")
            }
        ) { arguments in
            guard let name = arguments["name"]?.stringValue else {
                throw ToolError("A shortcut name is required.")
            }
            let output = try await shortcuts(["run", name])
            return output.isEmpty ? "Ran \(name)." : "Ran \(name). Output:\n\(output.prefix(2000))"
        }
    }

    private static func shortcuts(_ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw ToolError(text.isEmpty ? "The shortcut failed." : text)
            }
            return text
        }.value
    }

    // MARK: - Clipboard and focus

    static func readClipboard() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "get_clipboard",
                description:
                    "Read the text the user copied, when they refer to “this” or “what I copied”.",
                requiresConfirmation: true),
            summary: { _ in L("Read the text on your clipboard") }
        ) { _ in
            let text = await MainActor.run { NSPasteboard.general.string(forType: .string) }
            guard let text, !text.isEmpty else { return "The clipboard has no text." }
            return String(text.prefix(20_000))
        }
    }

    @MainActor
    static func startFocus(_ focus: FocusController) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "start_focus",
                description:
                    "Start a focus session (for example a 25-minute Pomodoro). Momo stays quiet and cheers when it ends.",
                parameters: JSONSchema.object([
                    "minutes": JSONSchema.integer("Length in minutes, default 25"),
                    "task": JSONSchema.string("What the user is focusing on"),
                ]))
        ) { [weak focus] arguments in
            let minutes = arguments["minutes"]?.intValue ?? 25
            let task = arguments["task"]?.stringValue
            await MainActor.run { focus?.start(minutes: minutes, task: task) }
            return "Focus session started for \(minutes) minutes."
        }
    }
}
