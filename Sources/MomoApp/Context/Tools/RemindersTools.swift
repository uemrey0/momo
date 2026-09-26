import EventKit
import Foundation
import MomoKit

/// A reminder from Apple Reminders, copied out of EventKit so it can cross threads.
struct ReminderItem: Sendable {
    var id: String
    var title: String
    var list: String
    var due: Date?
    var isCompleted: Bool
    var notes: String?

    /// Describes the reminder for a model, e.g. "Buy milk (Groceries), due 2026-09-27T09:00 [id: …]".
    var summary: String {
        var text = isCompleted ? "✓ \(title)" : title
        text += " (\(list))"
        if let due { text += ", due \(FlexibleDate.format(due))" }
        if let notes, !notes.isEmpty { text += " — \(notes.prefix(120))" }
        return text + " [id: \(id)]"
    }
}

/// Reads and changes Apple Reminders through EventKit. Access is requested the first time a
/// reminders tool runs.
final class RemindersService: @unchecked Sendable {
    private let store = EKEventStore()

    /// Makes sure Momo has full access to reminders, asking the first time.
    func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = (try? await store.requestFullAccessToReminders()) ?? false
            if granted { return }
        default:
            break
        }
        throw PermissionRequired(.reminders, "Momo can't use Reminders: access is off.")
    }

    /// The names of the user's reminder lists.
    func listNames() -> [String] {
        store.calendars(for: .reminder).map(\.title)
    }

    /// Reminders in the list named `listName` (or all lists), incomplete ones unless
    /// `includeCompleted` is set.
    func reminders(listName: String?, includeCompleted: Bool) async throws -> [ReminderItem] {
        var calendars: [EKCalendar]?
        if let listName {
            calendars = [try calendar(named: listName)]
        }
        let predicate =
            includeCompleted
            ? store.predicateForReminders(in: calendars)
            : store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).map(Self.item)
                continuation.resume(returning: items)
            }
        }
    }

    /// Adds a reminder and returns it.
    func add(title: String, listName: String?, due: Date?, notes: String?) throws -> ReminderItem {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        if let listName {
            reminder.calendar = try calendar(named: listName)
        } else if let calendar = store.defaultCalendarForNewReminders() {
            reminder.calendar = calendar
        } else {
            throw ToolError("There is no reminder list to add to.")
        }
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return Self.item(reminder)
    }

    /// Marks the reminder with this identifier as completed.
    func complete(id: String) throws -> ReminderItem {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ToolError("No reminder has that id. List the reminders again.")
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        return Self.item(reminder)
    }

    private func calendar(named name: String) throws -> EKCalendar {
        let calendars = store.calendars(for: .reminder)
        if let match = calendars.first(where: {
            $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }) {
            return match
        }
        let names = calendars.map(\.title).joined(separator: ", ")
        throw ToolError("There's no reminder list called “\(name)”. Lists: \(names)")
    }

    private static func item(_ reminder: EKReminder) -> ReminderItem {
        ReminderItem(
            id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
            list: reminder.calendar?.title ?? "",
            due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
            isCompleted: reminder.isCompleted, notes: reminder.notes)
    }
}

/// Tools for Apple Reminders. Momo's own tasks stay the default; these are for when the user
/// talks about the Reminders app or its lists.
enum RemindersTools {
    static func all(_ service: RemindersService) -> [any MomoTool] {
        [listReminders(service), addReminder(service), completeReminder(service)]
    }

    static func listReminders(_ service: RemindersService) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "list_reminders",
                description:
                    "List reminders from the Apple Reminders app, with their lists. Use it only when the user mentions Reminders or one of its lists; Momo's own tasks use list_tasks.",
                parameters: JSONSchema.object([
                    "list": JSONSchema.string("Only this list; omit for all lists"),
                    "include_completed": JSONSchema.boolean(
                        "Include completed reminders, default false"),
                ]),
                activityLabel: L("Checking your reminders"))
        ) { arguments in
            try await service.ensureAccess()
            let items = try await service.reminders(
                listName: arguments["list"]?.stringValue,
                includeCompleted: arguments["include_completed"]?.boolValue == true)
            var lines = ["Lists: \(service.listNames().joined(separator: ", "))"]
            if items.isEmpty {
                lines.append("No reminders.")
            } else {
                let sorted = items.sorted {
                    ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title)
                }
                lines += sorted.prefix(100).map(\.summary)
            }
            return lines.joined(separator: "\n")
        }
    }

    static func addReminder(_ service: RemindersService) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "add_reminder",
                description:
                    "Add a reminder to the Apple Reminders app, which syncs to the user's iPhone. Use it when the user asks for Reminders specifically; otherwise prefer add_task.",
                parameters: JSONSchema.object(
                    [
                        "title": JSONSchema.string("What to be reminded of"),
                        "list": JSONSchema.string("List name; defaults to the default list"),
                        "due": JSONSchema.string("Optional due time, ISO 8601 local time"),
                        "notes": JSONSchema.string("Optional notes"),
                    ], required: ["title"]),
                activityLabel: L("Adding a reminder"))
        ) { arguments in
            guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
                throw ToolError("A title is required.")
            }
            try await service.ensureAccess()
            let due = arguments["due"]?.stringValue.flatMap { FlexibleDate.parse($0) }
            let item = try service.add(
                title: title, listName: arguments["list"]?.stringValue, due: due,
                notes: arguments["notes"]?.stringValue)
            return "Added to Reminders: \(item.summary)"
        }
    }

    static func completeReminder(_ service: RemindersService) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "complete_reminder",
                description:
                    "Mark an Apple Reminders reminder as done, by its id from list_reminders or by its title.",
                parameters: JSONSchema.object([
                    "id": JSONSchema.string("The reminder's id from list_reminders"),
                    "title": JSONSchema.string("The reminder's title, if the id is unknown"),
                ]),
                activityLabel: L("Completing a reminder"))
        ) { arguments in
            try await service.ensureAccess()
            if let id = arguments["id"]?.stringValue, !id.isEmpty {
                return "Completed: \(try service.complete(id: id).summary)"
            }
            guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
                throw ToolError("Give the reminder's id or title.")
            }
            let open = try await service.reminders(listName: nil, includeCompleted: false)
            let exact = open.filter {
                $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
            }
            let matches =
                exact.isEmpty
                ? open.filter {
                    $0.title.range(of: title, options: [.caseInsensitive, .diacriticInsensitive])
                        != nil
                } : exact
            guard let first = matches.first else {
                throw ToolError("No open reminder matches “\(title)”.")
            }
            guard matches.count == 1 else {
                let options = matches.prefix(10).map(\.summary).joined(separator: "\n")
                throw ToolError(
                    "Several reminders match. Ask which one, then pass its id:\n\(options)")
            }
            return "Completed: \(try service.complete(id: first.id).summary)"
        }
    }
}
