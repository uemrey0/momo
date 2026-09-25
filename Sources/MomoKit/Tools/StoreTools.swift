import Foundation

/// The tools that read and change Momo's own data: tasks, notes, habits and memories.
///
/// These are shared by the in-app assistant and the MCP server.
public enum StoreTools {
    public static func all(store: MomoStore) -> [any MomoTool] {
        [
            addTask(store), listTasks(store), completeTask(store), updateTask(store),
            deleteTask(store), addNote(store), searchNotes(store), appendToNote(store),
            deleteNote(store), logHabit(store), listHabits(store), remember(store),
            listMemories(store), forget(store), currentTime(),
        ]
    }

    // MARK: - Tasks

    static func addTask(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "add_task",
                description:
                    "Add a task to the user's to-do list. Set remind_at to get a reminder notification.",
                parameters: JSONSchema.object(
                    [
                        "title": JSONSchema.string("Short task title"),
                        "notes": JSONSchema.string("Optional details"),
                        "due": JSONSchema.string(
                            "Optional deadline, ISO 8601 local time, e.g. 2026-09-27T15:00"),
                        "remind_at": JSONSchema.string(
                            "Optional reminder time, ISO 8601 local time"),
                    ], required: ["title"]))
        ) { arguments in
            guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
                throw ToolError("A title is required.")
            }
            let task = try await store.addTask(
                title: title, notes: arguments["notes"]?.stringValue,
                dueDate: try date(arguments, "due"), remindAt: try date(arguments, "remind_at"))
            return "Added task \(describe(task))"
        }
    }

    static func listTasks(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "list_tasks",
                description: "List the user's open tasks, optionally including completed ones.",
                parameters: JSONSchema.object([
                    "include_done": JSONSchema.boolean("Also list completed tasks")
                ]))
        ) { arguments in
            let tasks = await store.tasks(
                includeDone: arguments["include_done"]?.boolValue ?? false)
            guard !tasks.isEmpty else { return "The to-do list is empty." }
            return tasks.map(describe).joined(separator: "\n")
        }
    }

    static func completeTask(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "complete_task",
                description: "Mark a task as done.",
                parameters: JSONSchema.object(
                    ["task": JSONSchema.string("Task ID or title")], required: ["task"]))
        ) { arguments in
            let task = try await store.completeTask(try required(arguments, "task"))
            return "Completed \(describe(task))"
        }
    }

    static func updateTask(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "update_task",
                description: "Change a task's title, notes, deadline or reminder.",
                parameters: JSONSchema.object(
                    [
                        "task": JSONSchema.string("Task ID or title"),
                        "title": JSONSchema.string("New title"),
                        "notes": JSONSchema.string("New notes"),
                        "due": JSONSchema.string("New deadline, ISO 8601, or 'none' to clear"),
                        "remind_at": JSONSchema.string(
                            "New reminder time, ISO 8601, or 'none' to clear"),
                    ], required: ["task"]))
        ) { arguments in
            let task = try await store.updateTask(
                try required(arguments, "task"), title: arguments["title"]?.stringValue,
                notes: arguments["notes"]?.stringValue, dueDate: try optionalDate(arguments, "due"),
                remindAt: try optionalDate(arguments, "remind_at"))
            return "Updated \(describe(task))"
        }
    }

    static func deleteTask(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "delete_task",
                description: "Permanently delete a task. Prefer complete_task for finished work.",
                parameters: JSONSchema.object(
                    ["task": JSONSchema.string("Task ID or title")], required: ["task"]),
                requiresConfirmation: true),
            summary: { "Delete the task “\($0["task"]?.stringValue ?? "")”" }
        ) { arguments in
            let task = try await store.deleteTask(try required(arguments, "task"))
            return "Deleted task \(task.title)"
        }
    }

    // MARK: - Notes

    static func addNote(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "add_note",
                description: "Save a note for the user.",
                parameters: JSONSchema.object(
                    [
                        "title": JSONSchema.string("Short title"),
                        "body": JSONSchema.string("The note's content"),
                    ], required: ["title", "body"]))
        ) { arguments in
            let note = try await store.addNote(
                title: try required(arguments, "title"),
                body: arguments["body"]?.stringValue ?? "")
            return "Saved note \(note.id): \(note.title)"
        }
    }

    static func searchNotes(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "search_notes",
                description:
                    "Find the user's notes. Leave the query empty to list the most recent notes.",
                parameters: JSONSchema.object([
                    "query": JSONSchema.string("Words to look for")
                ]))
        ) { arguments in
            let query = arguments["query"]?.stringValue ?? ""
            let notes =
                query.isEmpty ? await store.notes() : await store.searchNotes(query)
            guard !notes.isEmpty else { return "No notes found." }
            return notes.prefix(10).map { note in
                let body =
                    note.body.count > 600 ? note.body.prefix(600) + "…" : Substring(note.body)
                return "[\(note.id)] \(note.title)\n\(body)"
            }.joined(separator: "\n\n")
        }
    }

    static func appendToNote(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "append_to_note",
                description: "Add text to the end of an existing note.",
                parameters: JSONSchema.object(
                    [
                        "note": JSONSchema.string("Note ID or title"),
                        "text": JSONSchema.string("Text to add"),
                    ], required: ["note", "text"]))
        ) { arguments in
            let note = try await store.appendToNote(
                try required(arguments, "note"), text: try required(arguments, "text"))
            return "Updated note \(note.id): \(note.title)"
        }
    }

    static func deleteNote(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "delete_note",
                description: "Permanently delete a note.",
                parameters: JSONSchema.object(
                    ["note": JSONSchema.string("Note ID or title")], required: ["note"]),
                requiresConfirmation: true),
            summary: { "Delete the note “\($0["note"]?.stringValue ?? "")”" }
        ) { arguments in
            let note = try await store.deleteNote(try required(arguments, "note"))
            return "Deleted note \(note.title)"
        }
    }

    // MARK: - Habits

    static func logHabit(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "log_habit",
                description:
                    "Record that the user did a habit today (creates the habit if it is new).",
                parameters: JSONSchema.object(
                    [
                        "habit": JSONSchema.string("Habit name or ID, e.g. 'Drink water'"),
                        "done": JSONSchema.boolean("false to undo today's check-in"),
                    ], required: ["habit"]))
        ) { arguments in
            let habit = try await store.logHabit(
                try required(arguments, "habit"), done: arguments["done"]?.boolValue ?? true)
            return "\(habit.name): streak \(habit.streak()) day(s)"
        }
    }

    static func listHabits(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "list_habits",
                description: "List habits with today's status and current streaks.")
        ) { _ in
            let habits = await store.habits()
            guard !habits.isEmpty else { return "No habits yet." }
            return habits.map {
                "[\($0.id)] \($0.name): \($0.isDone() ? "done today" : "not yet today"), streak \($0.streak())"
            }.joined(separator: "\n")
        }
    }

    // MARK: - Memory

    static func remember(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "remember",
                description:
                    "Remember a lasting fact or preference about the user, e.g. their name or that they prefer short answers.",
                parameters: JSONSchema.object(
                    ["fact": JSONSchema.string("One fact, written in the third person")],
                    required: ["fact"]))
        ) { arguments in
            let memory = try await store.remember(try required(arguments, "fact"))
            return "Remembered [\(memory.id)] \(memory.text)"
        }
    }

    static func listMemories(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "list_memories",
                description: "List everything Momo remembers about the user.")
        ) { _ in
            let memories = await store.memories()
            guard !memories.isEmpty else { return "Nothing remembered yet." }
            return memories.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n")
        }
    }

    static func forget(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "forget",
                description: "Forget a remembered fact when the user asks.",
                parameters: JSONSchema.object(
                    ["memory": JSONSchema.string("Memory ID or text")], required: ["memory"]))
        ) { arguments in
            let memory = try await store.forget(try required(arguments, "memory"))
            return "Forgot: \(memory.text)"
        }
    }

    // MARK: - Time

    static func currentTime() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "current_time",
                description: "Get the current local date, time, weekday and time zone.")
        ) { _ in
            let now = Date()
            let weekday = DateFormatter()
            weekday.locale = Locale(identifier: "en_US_POSIX")
            weekday.dateFormat = "EEEE"
            return
                "\(FlexibleDate.format(now)) (\(weekday.string(from: now)), \(TimeZone.current.identifier))"
        }
    }

    // MARK: - Helpers

    static func describe(_ task: TaskItem) -> String {
        var parts = ["[\(task.id)] \(task.title)"]
        if task.isDone { parts.append("(done)") }
        if let due = task.dueDate { parts.append("due \(FlexibleDate.format(due))") }
        if let remind = task.remindAt { parts.append("reminder \(FlexibleDate.format(remind))") }
        if let notes = task.notes, !notes.isEmpty { parts.append("— \(notes)") }
        return parts.joined(separator: " ")
    }

    static func required(_ arguments: JSONValue, _ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespaces),
            !value.isEmpty
        else {
            throw ToolError("The '\(key)' argument is required.")
        }
        return value
    }

    static func date(_ arguments: JSONValue, _ key: String) throws -> Date? {
        guard let text = arguments[key]?.stringValue, !text.isEmpty else { return nil }
        guard let date = FlexibleDate.parse(text) else {
            throw ToolError("'\(text)' is not a date. Use ISO 8601 such as 2026-09-27T15:00.")
        }
        return date
    }

    /// `nil` leaves the value unchanged, `.some(nil)` clears it.
    static func optionalDate(_ arguments: JSONValue, _ key: String) throws -> Date?? {
        guard let text = arguments[key]?.stringValue, !text.isEmpty else { return nil }
        if ["none", "null", "clear"].contains(text.lowercased()) { return .some(nil) }
        return .some(try date(arguments, key))
    }
}
