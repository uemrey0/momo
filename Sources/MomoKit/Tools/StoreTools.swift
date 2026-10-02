import Foundation

/// The tools that read and change Momo's own data: tasks, notes, habits, memories,
/// routines and meetings.
///
/// These are shared by the in-app assistant and the MCP server.
public enum StoreTools {
    public static func all(store: MomoStore) -> [any MomoTool] {
        [
            addTask(store), listTasks(store), completeTask(store), updateTask(store),
            deleteTask(store), addNote(store), searchNotes(store), appendToNote(store),
            deleteNote(store), logHabit(store), listHabits(store), remember(store),
            listMemories(store), forget(store), addRoutine(store), listRoutines(store),
            updateRoutine(store), deleteRoutine(store), listMeetings(store), getMeeting(store),
            meetingActionItemsToTasks(store), currentTime(),
        ]
    }

    // MARK: - Tasks

    /// Arguments shared by add_task and update_task for repeating, priority and tags.
    static func taskDetailProperties(clearable: Bool) -> [String: JSONValue] {
        let clear = clearable ? ", or 'none' to stop repeating" : ""
        return [
            "repeat": JSONSchema.string(
                "Optional: repeat the task daily, weekdays, weekly, monthly or yearly\(clear). "
                    + "Completing it then creates the next occurrence."),
            "repeat_interval": JSONSchema.integer(
                "Optional: repeat every N days, weeks, months or years (default 1)"),
            "priority": JSONSchema.oneOf(
                TaskPriority.allCases.map(\.rawValue), description: "Optional priority"),
            "tags": JSONSchema.string("Optional comma-separated tags, e.g. 'work, errands'"),
        ]
    }

    static func addTask(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "add_task",
                description:
                    "Add a task to the user's to-do list. Set remind_at to get a reminder notification. Set repeat for recurring tasks such as 'pay rent monthly'.",
                parameters: JSONSchema.object(
                    [
                        "title": JSONSchema.string("Short task title"),
                        "notes": JSONSchema.string("Optional details"),
                        "due": JSONSchema.string(
                            "Optional deadline, ISO 8601 local time, e.g. 2026-09-27T15:00"),
                        "remind_at": JSONSchema.string(
                            "Optional reminder time, ISO 8601 local time"),
                    ].merging(taskDetailProperties(clearable: false)) { first, _ in first },
                    required: ["title"]))
        ) { arguments in
            guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
                throw ToolError("A title is required.")
            }
            let task = try await store.addTask(
                title: title, notes: arguments["notes"]?.stringValue,
                dueDate: try date(arguments, "due"), remindAt: try date(arguments, "remind_at"),
                recurrence: try recurrence(arguments) ?? nil,
                priority: try priority(arguments) ?? .normal, tags: tags(arguments) ?? [])
            return "Added task \(describe(task))"
        }
    }

    static func listTasks(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "list_tasks",
                description:
                    "List the user's open tasks, optionally including completed ones or only those with a tag.",
                parameters: JSONSchema.object([
                    "include_done": JSONSchema.boolean("Also list completed tasks"),
                    "tag": JSONSchema.string("Only tasks with this tag"),
                    "priority": JSONSchema.oneOf(
                        TaskPriority.allCases.map(\.rawValue),
                        description: "Only tasks with this priority"),
                ]))
        ) { arguments in
            var tasks = await store.tasks(
                includeDone: arguments["include_done"]?.boolValue ?? false)
            if let tag = tags(arguments, key: "tag")?.first {
                tasks = tasks.filter { $0.tags.contains(tag) }
            }
            if let priority = try priority(arguments) {
                tasks = tasks.filter { $0.priority == priority }
            }
            guard !tasks.isEmpty else {
                return arguments["tag"] == nil && arguments["priority"] == nil
                    ? "The to-do list is empty." : "No tasks match."
            }
            return tasks.map(describe).joined(separator: "\n")
        }
    }

    static func completeTask(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "complete_task",
                description:
                    "Mark a task as done. For a repeating task this also creates the next occurrence.",
                parameters: JSONSchema.object(
                    ["task": JSONSchema.string("Task ID or title")], required: ["task"]))
        ) { arguments in
            let task = try await store.completeTask(try required(arguments, "task"))
            var output = "Completed \(describe(task))"
            if let id = task.nextOccurrenceID, let next = await store.task(id: id) {
                output += "\nNext occurrence: \(describe(next))"
            }
            return output
        }
    }

    static func updateTask(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "update_task",
                description:
                    "Change a task's title, notes, deadline, reminder, repetition, priority or tags.",
                parameters: JSONSchema.object(
                    [
                        "task": JSONSchema.string("Task ID or title"),
                        "title": JSONSchema.string("New title"),
                        "notes": JSONSchema.string("New notes"),
                        "due": JSONSchema.string("New deadline, ISO 8601, or 'none' to clear"),
                        "remind_at": JSONSchema.string(
                            "New reminder time, ISO 8601, or 'none' to clear"),
                    ].merging(taskDetailProperties(clearable: true)) { first, _ in first },
                    required: ["task"]))
        ) { arguments in
            let task = try await store.updateTask(
                try required(arguments, "task"), title: arguments["title"]?.stringValue,
                notes: arguments["notes"]?.stringValue, dueDate: try optionalDate(arguments, "due"),
                remindAt: try optionalDate(arguments, "remind_at"),
                recurrence: try recurrence(arguments), priority: try priority(arguments),
                tags: tags(arguments))
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
            var notes =
                query.isEmpty ? await store.notes() : await store.searchNotes(query)
            if notes.isEmpty, !query.isEmpty {
                // No note has every word: fall back to notes that share words or stems.
                notes = MemoryRanker(usesEmbeddings: false)
                    .rank(await store.notes(), by: { $0.title + " " + $0.body }, query: query)
                    .filter { $0.score > 0 }.map(\.item)
            }
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
                    [
                        "fact": JSONSchema.string("One fact, written in the third person"),
                        "category": JSONSchema.oneOf(
                            MemoryCategory.allCases.map(\.rawValue),
                            description:
                                "preference (how the user likes things), person (someone in their life), project (something they work on) or fact (anything else, the default)"
                        ),
                    ],
                    required: ["fact"]))
        ) { arguments in
            let memory = try await store.remember(
                try required(arguments, "fact"), category: try category(arguments))
            return "Remembered [\(memory.id)] (\(memory.category.rawValue)) \(memory.text)"
        }
    }

    static func listMemories(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "list_memories",
                description:
                    "List what Momo remembers about the user, optionally only one category.",
                parameters: JSONSchema.object([
                    "category": JSONSchema.oneOf(
                        MemoryCategory.allCases.map(\.rawValue),
                        description: "Only memories in this category")
                ]))
        ) { arguments in
            let category = try category(arguments)
            let memories = await store.memories(in: category)
            guard !memories.isEmpty else {
                return category == nil
                    ? "Nothing remembered yet." : "Nothing remembered in that category."
            }
            return memories.map { "[\($0.id)] (\($0.category.rawValue)) \($0.text)" }
                .joined(separator: "\n")
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

    // MARK: - Routines

    static let daysDescription =
        "'daily', 'weekdays', 'weekends' or days such as 'mon, wed, fri'"

    static func addRoutine(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "add_routine",
                description:
                    "Create a routine: a prompt Momo runs by itself on a schedule and delivers as a notification, e.g. every weekday at 09:00 'Summarise my day and the weather'.",
                parameters: JSONSchema.object(
                    [
                        "title": JSONSchema.string("Short name, e.g. 'Morning brief'"),
                        "prompt": JSONSchema.string(
                            "What Momo should do each time, written as the user's request"),
                        "time": JSONSchema.string("Local time of day, 24-hour HH:mm"),
                        "days": JSONSchema.string("Optional: \(daysDescription). Default daily"),
                    ], required: ["title", "prompt", "time"]),
                // A routine runs its prompt unattended, so the user approves every prompt.
                requiresConfirmation: true),
            summary: routineSummary
        ) { arguments in
            guard let time = try time(arguments) else {
                throw ToolError("The 'time' argument is required, e.g. 09:00.")
            }
            let routine = try await store.addRoutine(
                title: try required(arguments, "title"), prompt: try required(arguments, "prompt"),
                schedule: RoutineSchedule(
                    hour: time.hour, minute: time.minute, weekdays: try days(arguments) ?? []))
            return "Added routine \(describe(routine))"
        }
    }

    static func listRoutines(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "list_routines",
                description: "List the user's routines with their schedules.")
        ) { _ in
            let routines = await store.routines()
            guard !routines.isEmpty else { return "No routines yet." }
            return routines.map(describe).joined(separator: "\n")
        }
    }

    static func updateRoutine(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "update_routine",
                description:
                    "Change a routine's title, prompt or schedule, or pause and resume it.",
                parameters: JSONSchema.object(
                    [
                        "routine": JSONSchema.string("Routine ID or title"),
                        "title": JSONSchema.string("New title"),
                        "prompt": JSONSchema.string("New prompt"),
                        "time": JSONSchema.string("New local time of day, HH:mm"),
                        "days": JSONSchema.string("New days: \(daysDescription)"),
                        "enabled": JSONSchema.boolean("false to pause, true to resume"),
                    ], required: ["routine"])),
            summary: routineSummary,
            // Changing what a routine does needs approval; changing when it runs does not.
            confirmsWhen: { $0["prompt"]?.stringValue != nil }
        ) { arguments in
            let routine = try await store.updateRoutine(
                try required(arguments, "routine"), title: arguments["title"]?.stringValue,
                prompt: arguments["prompt"]?.stringValue, time: try time(arguments),
                weekdays: try days(arguments), isEnabled: arguments["enabled"]?.boolValue)
            return "Updated routine \(describe(routine))"
        }
    }

    static func deleteRoutine(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "delete_routine",
                description:
                    "Permanently delete a routine. Prefer update_routine with enabled false to pause it.",
                parameters: JSONSchema.object(
                    ["routine": JSONSchema.string("Routine ID or title")], required: ["routine"]),
                requiresConfirmation: true),
            summary: { "Delete the routine “\($0["routine"]?.stringValue ?? "")”" }
        ) { arguments in
            let routine = try await store.deleteRoutine(try required(arguments, "routine"))
            return "Deleted routine \(routine.title)"
        }
    }

    /// What a routine call will set up, with the full prompt, for the confirmation.
    @Sendable static func routineSummary(_ arguments: JSONValue) -> String {
        let name = arguments["title"]?.stringValue ?? arguments["routine"]?.stringValue ?? ""
        var lines = ["Routine “\(name)”"]
        if let time = arguments["time"]?.stringValue {
            lines.append("At \(time), \(arguments["days"]?.stringValue ?? "daily")")
        }
        if let prompt = arguments["prompt"]?.stringValue {
            lines.append("Runs by itself: “\(prompt)”")
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ routine: Routine) -> String {
        var parts = ["[\(routine.id)] \(routine.title): \(routine.schedule.summary)"]
        if !routine.isEnabled { parts.append("(paused)") }
        if let lastRun = routine.lastRun {
            parts.append("last ran \(FlexibleDate.format(lastRun))")
        }
        parts.append("— \(routine.prompt)")
        return parts.joined(separator: " ")
    }

    static func time(_ arguments: JSONValue) throws -> (hour: Int, minute: Int)? {
        guard let text = arguments["time"]?.stringValue, !text.isEmpty else { return nil }
        guard let time = RoutineSchedule.parseTime(text) else {
            throw ToolError("'\(text)' is not a time. Use 24-hour HH:mm such as 09:00.")
        }
        return time
    }

    static func days(_ arguments: JSONValue) throws -> Set<Int>? {
        guard let text = arguments["days"]?.stringValue, !text.isEmpty else { return nil }
        guard let days = RoutineSchedule.parseDays(text) else {
            throw ToolError("'\(text)' are not days. Use \(daysDescription).")
        }
        return days
    }

    // MARK: - Meetings

    static func listMeetings(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "list_meetings",
                description:
                    "List meetings Momo took notes of, newest first, with their date, participants and summary. Use it to find a meeting, e.g. yesterday's stand-up, then get_meeting for details.",
                parameters: JSONSchema.object([
                    "query": JSONSchema.string(
                        "Optional words to look for in titles, summaries and participants"),
                    "days": JSONSchema.integer("Optional: only meetings from the last N days"),
                ]))
        ) { arguments in
            var meetings = await store.meetings()
            if let days = arguments["days"]?.intValue, days > 0 {
                let start = Calendar.current.date(
                    byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: Date()))
                meetings = meetings.filter { $0.startedAt >= (start ?? .distantPast) }
            }
            let words = (arguments["query"]?.stringValue ?? "").lowercased()
                .split(whereSeparator: \.isWhitespace)
            if !words.isEmpty {
                meetings = meetings.filter { meeting in
                    let text =
                        ([meeting.title, meeting.summary] + meeting.participants.map(\.name))
                        .joined(separator: " ").lowercased()
                    return words.allSatisfy { text.contains($0) }
                }
            }
            guard !meetings.isEmpty else { return "No meetings found." }
            return meetings.prefix(20).map(describe).joined(separator: "\n")
        }
    }

    static func getMeeting(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "get_meeting",
                description:
                    "Get a meeting's notes: summary, decisions, action items, open questions and participants, optionally with an excerpt of the transcript.",
                parameters: JSONSchema.object(
                    [
                        "meeting": JSONSchema.string("Meeting ID, title, or 'latest'"),
                        "include_transcript": JSONSchema.boolean(
                            "Also return the transcript (shortened when long)"),
                    ], required: ["meeting"]))
        ) { arguments in
            let meeting = try await store.findMeeting(try required(arguments, "meeting"))
            return details(
                meeting, includeTranscript: arguments["include_transcript"]?.boolValue ?? false)
        }
    }

    static func meetingActionItemsToTasks(_ store: MomoStore) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "meeting_action_items_to_tasks",
                description:
                    "Add a meeting's action items to the user's tasks. Items that are already tasks are skipped.",
                parameters: JSONSchema.object(
                    [
                        "meeting": JSONSchema.string("Meeting ID, title, or 'latest'"),
                        "items": JSONSchema.string(
                            "Optional comma-separated action item IDs; all items when omitted"),
                    ], required: ["meeting"]))
        ) { arguments in
            let meeting = try await store.findMeeting(try required(arguments, "meeting"))
            guard !meeting.actionItems.isEmpty else {
                return "The meeting “\(meeting.title)” has no action items."
            }
            var ids: Set<String>?
            if let text = arguments["items"]?.stringValue, !text.isEmpty {
                ids = Set(
                    text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                        .map { $0.lowercased() })
            } else if let array = arguments["items"]?.arrayValue {
                ids = Set(array.compactMap(\.stringValue).map { $0.lowercased() })
            }
            let tasks = try await store.addActionItemsAsTasks(meetingID: meeting.id, itemIDs: ids)
            guard !tasks.isEmpty else { return "Those action items are already tasks." }
            return "Added tasks:\n" + tasks.map(describe).joined(separator: "\n")
        }
    }

    static func describe(_ meeting: Meeting) -> String {
        var parts = [
            "[\(meeting.id)] \(FlexibleDate.format(meeting.startedAt)) \(meeting.title)",
            "(\(Int(meeting.duration() / 60)) min, \(meeting.participantCount) participants)",
        ]
        switch meeting.status {
        case .recording: parts.append("(recording now)")
        case .summarizing: parts.append("(summary in progress)")
        case .failed: parts.append("(no summary)")
        case .done: break
        }
        if !meeting.summary.isEmpty {
            let summary = meeting.summary.replacingOccurrences(of: "\n", with: " ")
            parts.append("— " + (summary.count > 200 ? summary.prefix(200) + "…" : summary))
        }
        return parts.joined(separator: " ")
    }

    /// A meeting's notes for the model, with at most `transcriptLimit` characters of transcript.
    static func details(
        _ meeting: Meeting, includeTranscript: Bool, transcriptLimit: Int = 8_000
    ) -> String {
        var lines = [describe(meeting)]
        if !meeting.participants.isEmpty {
            lines.append(
                "Participants: "
                    + meeting.participants.map { participant in
                        participant.isUser
                            ? "the user"
                            : participant.name + (participant.spoke ? "" : " (invited)")
                    }.joined(separator: ", "))
        }
        if !meeting.summary.isEmpty { lines.append("Summary: \(meeting.summary)") }
        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append("\(title):\n" + items.map { "- \($0)" }.joined(separator: "\n"))
        }
        section("Decisions", meeting.decisions)
        section(
            "Action items",
            meeting.actionItems.map { item in
                var text = "[\(item.id)] \(item.text)"
                if let owner = item.owner { text += " — owner: \(owner)" }
                if let due = item.dueDate {
                    text += ", due \(FlexibleDate.format(due))"
                } else if let due = item.dueText {
                    text += ", due \(due)"
                }
                if item.taskID != nil { text += " (already a task)" }
                return text
            })
        section("Open questions", meeting.openQuestions)
        if let reason = meeting.failureReason { lines.append("No summary: \(reason)") }
        if includeTranscript {
            let transcript = MeetingTranscript.lines(meeting.segments).joined(separator: "\n")
            if transcript.isEmpty {
                lines.append("Transcript: (empty)")
            } else if transcript.count > transcriptLimit {
                lines.append(
                    "Transcript (first \(transcriptLimit) of \(transcript.count) characters):\n"
                        + transcript.prefix(transcriptLimit) + "…")
            } else {
                lines.append("Transcript:\n\(transcript)")
            }
        }
        return lines.joined(separator: "\n")
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
        if task.priority != .normal { parts.append("(\(task.priority.rawValue) priority)") }
        if let due = task.dueDate { parts.append("due \(FlexibleDate.format(due))") }
        if let remind = task.remindAt { parts.append("reminder \(FlexibleDate.format(remind))") }
        if let recurrence = task.recurrence { parts.append("repeats \(recurrence.summary)") }
        if !task.tags.isEmpty { parts.append(task.tags.map { "#\($0)" }.joined(separator: " ")) }
        if let notes = task.notes, !notes.isEmpty { parts.append("— \(notes)") }
        return parts.joined(separator: " ")
    }

    /// Reads `repeat` and `repeat_interval`. `nil` leaves the rule unchanged, `.some(nil)`
    /// stops repeating.
    static func recurrence(_ arguments: JSONValue) throws -> Recurrence?? {
        let interval = arguments["repeat_interval"]?.intValue ?? 1
        guard let text = arguments["repeat"]?.stringValue?.trimmingCharacters(in: .whitespaces),
            !text.isEmpty
        else { return nil }
        if ["none", "null", "never", "no", "false"].contains(text.lowercased()) {
            return .some(nil)
        }
        guard interval >= 1 else {
            throw ToolError("'repeat_interval' must be 1 or more.")
        }
        guard let rule = Recurrence(text, interval: interval) else {
            throw ToolError(
                "'\(text)' is not a repeat rule. Use daily, weekdays, weekly, monthly or yearly.")
        }
        return .some(rule)
    }

    static func priority(_ arguments: JSONValue) throws -> TaskPriority? {
        guard let text = arguments["priority"]?.stringValue, !text.isEmpty else { return nil }
        guard let priority = TaskPriority(rawValue: text.lowercased()) else {
            throw ToolError("'\(text)' is not a priority. Use low, normal or high.")
        }
        return priority
    }

    static func category(_ arguments: JSONValue) throws -> MemoryCategory? {
        guard let text = arguments["category"]?.stringValue, !text.isEmpty else { return nil }
        guard let category = MemoryCategory(rawValue: text.lowercased()) else {
            throw ToolError(
                "'\(text)' is not a memory category. Use preference, person, project or fact.")
        }
        return category
    }

    /// Reads tags given as a comma-separated string or as an array. `nil` when absent.
    static func tags(_ arguments: JSONValue, key: String = "tags") -> [String]? {
        guard let value = arguments[key] else { return nil }
        let raw: [String]
        if let array = value.arrayValue {
            raw = array.compactMap(\.stringValue)
        } else if let text = value.stringValue {
            raw = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        } else {
            return nil
        }
        return MomoStore.normalizedTags(raw)
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
