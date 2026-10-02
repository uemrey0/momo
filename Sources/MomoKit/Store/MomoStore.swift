import Foundation

/// Stores tasks, notes, habits, memories, routines and meetings in a single JSON file.
///
/// The file may be shared with other processes (the MCP server), so the store reloads it
/// whenever it changed on disk and writes atomically. It never writes over data it couldn't
/// read: an unreadable file is moved aside first, and a file from a newer Momo is left alone.
public actor MomoStore {
    public nonisolated let fileURL: URL
    private var data = MomoData()
    private var loadedModificationDate: Date?
    private var loadProblem: StoreProblem?
    private var observers: [UUID: AsyncStream<MomoData>.Continuation] = [:]

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Momo/data.json`
    public static var defaultFileURL: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Momo", isDirectory: true)
            .appendingPathComponent("data.json")
    }

    // MARK: - Observation

    /// A stream of snapshots, starting with the current one, emitted after every change.
    public func changes() -> AsyncStream<MomoData> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MomoData>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(snapshot())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    /// The current contents.
    public func snapshot() -> MomoData {
        reloadIfNeeded()
        return data
    }

    /// What went wrong reading the file, for the app to tell the user. `nil` when nothing did.
    public func problem() -> StoreProblem? {
        reloadIfNeeded()
        return loadProblem
    }

    // MARK: - Tasks

    public func tasks(includeDone: Bool = false) -> [TaskItem] {
        reloadIfNeeded()
        return data.tasks.filter { includeDone || !$0.isDone }
            .sorted {
                ($0.dueDate ?? .distantFuture, $0.createdAt) < (
                    $1.dueDate ?? .distantFuture, $1.createdAt
                )
            }
    }

    @discardableResult
    public func addTask(
        title: String, notes: String? = nil, dueDate: Date? = nil, remindAt: Date? = nil,
        recurrence: Recurrence? = nil, priority: TaskPriority = .normal, tags: [String] = []
    ) throws -> TaskItem {
        let task = TaskItem(
            title: title, notes: notes, dueDate: dueDate, remindAt: remindAt,
            recurrence: recurrence, priority: priority, tags: Self.normalizedTags(tags))
        try mutate { $0.tasks.append(task) }
        return task
    }

    /// Marks a task done. `reference` is an ID or part of the title.
    ///
    /// Completing a repeating task also adds its next occurrence, whose ID the returned task
    /// keeps in `nextOccurrenceID` (see ``task(id:)``).
    @discardableResult
    public func completeTask(
        _ reference: String, at now: Date = Date(), calendar: Calendar = .current
    ) throws -> TaskItem {
        let index = try taskIndex(for: reference, includeDone: false)
        try markDone(at: index, now: now, calendar: calendar)
        return data.tasks[index]
    }

    /// The task with exactly this ID, done or not.
    public func task(id: String) -> TaskItem? {
        reloadIfNeeded()
        return data.tasks.first { $0.id == id }
    }

    @discardableResult
    public func updateTask(
        _ reference: String, title: String? = nil, notes: String? = nil, dueDate: Date?? = nil,
        remindAt: Date?? = nil, recurrence: Recurrence?? = nil, priority: TaskPriority? = nil,
        tags: [String]? = nil
    ) throws -> TaskItem {
        // Overwriting text can't be undone, so it needs an exact ID or title.
        let index = try taskIndex(
            for: reference, includeDone: true, exactOnly: title != nil || notes != nil)
        try mutate {
            if let title { $0.tasks[index].title = title }
            if let notes { $0.tasks[index].notes = notes }
            if let dueDate { $0.tasks[index].dueDate = dueDate }
            if let remindAt { $0.tasks[index].remindAt = remindAt }
            if let recurrence { $0.tasks[index].recurrence = recurrence }
            if let priority { $0.tasks[index].priority = priority }
            if let tags { $0.tasks[index].tags = Self.normalizedTags(tags) }
        }
        return data.tasks[index]
    }

    @discardableResult
    public func deleteTask(_ reference: String) throws -> TaskItem {
        let index = try taskIndex(for: reference, includeDone: true, exactOnly: true)
        let task = data.tasks[index]
        try mutate { $0.tasks.remove(at: index) }
        return task
    }

    /// Ticks or unticks a task from the UI. Unticking a repeating task removes the occurrence
    /// its completion created, as long as that one is still open.
    public func setTaskDone(id: String, _ done: Bool, at now: Date = Date()) throws {
        let index = try taskIndex(for: id, includeDone: true)
        guard data.tasks[index].isDone != done else { return }
        if done {
            try markDone(at: index, now: now, calendar: .current)
            return
        }
        let nextID = data.tasks[index].nextOccurrenceID
        try mutate {
            $0.tasks[index].isDone = false
            $0.tasks[index].completedAt = nil
            $0.tasks[index].nextOccurrenceID = nil
            if let nextID, let next = $0.tasks.firstIndex(where: { $0.id == nextID }),
                !$0.tasks[next].isDone
            {
                $0.tasks.remove(at: next)
            }
        }
    }

    /// Completes the task at `index` and adds the next occurrence if it repeats.
    @discardableResult
    private func markDone(at index: Int, now: Date, calendar: Calendar) throws -> TaskItem? {
        let next = data.tasks[index].nextOccurrence(completedAt: now, calendar: calendar)
        try mutate {
            $0.tasks[index].isDone = true
            $0.tasks[index].completedAt = now
            $0.tasks[index].nextOccurrenceID = next?.id
            if let next { $0.tasks.append(next) }
        }
        return next
    }

    /// Lowercased, trimmed, without duplicates or a leading `#`.
    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.compactMap { tag in
            var cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while cleaned.hasPrefix("#") { cleaned.removeFirst() }
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { return nil }
            return cleaned
        }
    }

    private func taskIndex(
        for reference: String, includeDone: Bool, exactOnly: Bool = false
    ) throws -> Int {
        reloadIfNeeded()
        return try Self.index(
            in: data.tasks, reference: reference, kind: "task",
            id: \.id, title: \.title, isEligible: { includeDone || !$0.isDone },
            exactOnly: exactOnly)
    }

    // MARK: - Notes

    public func notes() -> [Note] {
        reloadIfNeeded()
        return data.notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func addNote(title: String, body: String) throws -> Note {
        let note = Note(title: title, body: body)
        try mutate { $0.notes.append(note) }
        return note
    }

    /// Notes whose title or body contains every word of the query.
    public func searchNotes(_ query: String) -> [Note] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return notes().filter { note in
            let haystack = (note.title + " " + note.body).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    @discardableResult
    public func appendToNote(_ reference: String, text: String) throws -> Note {
        let index = try noteIndex(for: reference)
        try mutate {
            $0.notes[index].body += ($0.notes[index].body.isEmpty ? "" : "\n") + text
            $0.notes[index].updatedAt = Date()
        }
        return data.notes[index]
    }

    /// Replaces a note's title and body, or adds it when no note has its ID.
    @discardableResult
    public func saveNote(_ note: Note) throws -> Note {
        reloadIfNeeded()
        var saved = note
        saved.updatedAt = Date()
        if let index = data.notes.firstIndex(where: { $0.id == note.id }) {
            try mutate { $0.notes[index] = saved }
        } else {
            try mutate { $0.notes.append(saved) }
        }
        return saved
    }

    @discardableResult
    public func deleteNote(_ reference: String) throws -> Note {
        let index = try noteIndex(for: reference, exactOnly: true)
        let note = data.notes[index]
        try mutate { $0.notes.remove(at: index) }
        return note
    }

    private func noteIndex(for reference: String, exactOnly: Bool = false) throws -> Int {
        reloadIfNeeded()
        return try Self.index(
            in: data.notes, reference: reference, kind: "note", id: \.id, title: \.title,
            isEligible: { _ in true }, exactOnly: exactOnly)
    }

    // MARK: - Habits

    public func habits() -> [Habit] {
        reloadIfNeeded()
        return data.habits.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func addHabit(name: String) throws -> Habit {
        reloadIfNeeded()
        if let existing = data.habits.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return existing
        }
        let habit = Habit(name: name)
        try mutate { $0.habits.append(habit) }
        return habit
    }

    /// Marks a habit done (or not) for a day, creating the habit if needed.
    @discardableResult
    public func logHabit(
        _ reference: String, on date: Date = Date(), done: Bool = true
    ) throws
        -> Habit
    {
        reloadIfNeeded()
        let index: Int
        if let found = try? Self.index(
            in: data.habits, reference: reference, kind: "habit", id: \.id, title: \.name,
            isEligible: { _ in true })
        {
            index = found
        } else {
            try addHabit(name: reference)
            index = data.habits.count - 1
        }
        let key = DayKey.string(for: date)
        try mutate {
            if done {
                $0.habits[index].completedDays.insert(key)
            } else {
                $0.habits[index].completedDays.remove(key)
            }
        }
        return data.habits[index]
    }

    @discardableResult
    public func deleteHabit(_ reference: String) throws -> Habit {
        reloadIfNeeded()
        let index = try Self.index(
            in: data.habits, reference: reference, kind: "habit", id: \.id, title: \.name,
            isEligible: { _ in true })
        let habit = data.habits[index]
        try mutate { $0.habits.remove(at: index) }
        return habit
    }

    // MARK: - Memories

    /// Memories from oldest to newest, optionally only those in one category.
    public func memories(in category: MemoryCategory? = nil) -> [Memory] {
        reloadIfNeeded()
        return data.memories.filter { category == nil || $0.category == category }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Saves a memory once. Remembering known text again only updates its category, when one
    /// is given.
    @discardableResult
    public func remember(_ text: String, category: MemoryCategory? = nil) throws -> Memory {
        reloadIfNeeded()
        if let index = data.memories.firstIndex(where: {
            $0.text.localizedCaseInsensitiveCompare(text) == .orderedSame
        }) {
            if let category, data.memories[index].category != category {
                try mutate { $0.memories[index].category = category }
            }
            return data.memories[index]
        }
        let memory = Memory(text: text, category: category ?? .fact)
        try mutate { $0.memories.append(memory) }
        return memory
    }

    @discardableResult
    public func forget(_ reference: String) throws -> Memory {
        reloadIfNeeded()
        let index = try Self.index(
            in: data.memories, reference: reference, kind: "memory", id: \.id, title: \.text,
            isEligible: { _ in true }, exactOnly: true)
        let memory = data.memories[index]
        try mutate { $0.memories.remove(at: index) }
        return memory
    }

    // MARK: - Routines

    /// Routines in the order they were created.
    public func routines() -> [Routine] {
        reloadIfNeeded()
        return data.routines.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func addRoutine(
        title: String, prompt: String, schedule: RoutineSchedule, isEnabled: Bool = true,
        now: Date = Date()
    ) throws -> Routine {
        let routine = Routine(
            title: title, prompt: prompt, schedule: schedule, isEnabled: isEnabled, createdAt: now)
        try mutate { $0.routines.append(routine) }
        return routine
    }

    /// Changes the given parts of a routine; `time` and `weekdays` can change independently.
    @discardableResult
    public func updateRoutine(
        _ reference: String, title: String? = nil, prompt: String? = nil,
        time: (hour: Int, minute: Int)? = nil, weekdays: Set<Int>? = nil, isEnabled: Bool? = nil
    ) throws -> Routine {
        let index = try routineIndex(for: reference)
        let previous = data.routines[index]
        var routine = previous
        if let title { routine.title = title }
        if let prompt { routine.prompt = prompt }
        routine.schedule = RoutineSchedule(
            hour: time?.hour ?? previous.schedule.hour,
            minute: time?.minute ?? previous.schedule.minute,
            weekdays: weekdays ?? previous.schedule.weekdays)
        if let isEnabled { routine.isEnabled = isEnabled }
        let saved = routine.edited(from: previous)
        try mutate { $0.routines[index] = saved }
        return saved
    }

    /// Replaces a routine, or adds it when no routine has its ID.
    @discardableResult
    public func saveRoutine(_ routine: Routine) throws -> Routine {
        reloadIfNeeded()
        if let index = data.routines.firstIndex(where: { $0.id == routine.id }) {
            let saved = routine.edited(from: data.routines[index])
            try mutate { $0.routines[index] = saved }
            return saved
        } else {
            try mutate { $0.routines.append(routine) }
        }
        return routine
    }

    /// Records that a routine ran, so it does not run again for the same scheduled time.
    public func markRoutineRun(id: String, at date: Date = Date()) throws {
        reloadIfNeeded()
        guard let index = data.routines.firstIndex(where: { $0.id == id }) else { return }
        try mutate { $0.routines[index].lastRun = date }
    }

    @discardableResult
    public func deleteRoutine(_ reference: String) throws -> Routine {
        let index = try routineIndex(for: reference, exactOnly: true)
        let routine = data.routines[index]
        try mutate { $0.routines.remove(at: index) }
        return routine
    }

    private func routineIndex(for reference: String, exactOnly: Bool = false) throws -> Int {
        reloadIfNeeded()
        return try Self.index(
            in: data.routines, reference: reference, kind: "routine", id: \.id, title: \.title,
            isEligible: { _ in true }, exactOnly: exactOnly)
    }

    // MARK: - Meetings

    /// Meetings, most recent first.
    public func meetings() -> [Meeting] {
        reloadIfNeeded()
        return data.meetings.sorted { $0.startedAt > $1.startedAt }
    }

    /// The meeting with exactly this ID.
    public func meeting(id: String) -> Meeting? {
        reloadIfNeeded()
        return data.meetings.first { $0.id == id }
    }

    /// Finds a meeting by ID or title; "latest" (or "last") is the most recent one. Several
    /// meetings often share a title (a daily stand-up), so the newest match wins.
    public func findMeeting(_ reference: String) throws -> Meeting {
        let sorted = meetings()
        let needle = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["latest", "last", "recent", "most recent"].contains(needle.lowercased()) {
            guard let latest = sorted.first else { throw ToolError("No meetings yet.") }
            return latest
        }
        if let exact = sorted.first(where: { $0.id == needle.lowercased() }) { return exact }
        if let titled = sorted.first(where: {
            $0.title.localizedCaseInsensitiveCompare(needle) == .orderedSame
        }) {
            return titled
        }
        if let partial = sorted.first(where: { $0.title.localizedCaseInsensitiveContains(needle) })
        {
            return partial
        }
        throw ToolError("No meeting matches '\(reference)'. Use list_meetings to see them.")
    }

    /// Replaces a meeting, or adds it when no meeting has its ID.
    @discardableResult
    public func saveMeeting(_ meeting: Meeting) throws -> Meeting {
        reloadIfNeeded()
        if let index = data.meetings.firstIndex(where: { $0.id == meeting.id }) {
            try mutate { $0.meetings[index] = meeting }
        } else {
            try mutate { $0.meetings.append(meeting) }
        }
        return meeting
    }

    @discardableResult
    public func deleteMeeting(_ reference: String) throws -> Meeting {
        let meeting = try findMeeting(reference)
        try mutate { $0.meetings.removeAll { $0.id == meeting.id } }
        return meeting
    }

    /// Adds a meeting's action items to the task list, once each: items that already became
    /// tasks are skipped. `itemIDs` limits it to some items; `nil` adds them all.
    ///
    /// Each task notes who owns it and which meeting it came from, keeps the deadline when
    /// one was said, and is tagged "meeting".
    @discardableResult
    public func addActionItemsAsTasks(
        meetingID: String, itemIDs: Set<String>? = nil
    ) throws -> [TaskItem] {
        reloadIfNeeded()
        guard let index = data.meetings.firstIndex(where: { $0.id == meetingID }) else {
            throw ToolError("No meeting has the ID '\(meetingID)'.")
        }
        let meeting = data.meetings[index]
        var items = meeting.actionItems
        var added: [TaskItem] = []
        for position in items.indices {
            let item = items[position]
            guard item.taskID == nil, itemIDs?.contains(item.id) ?? true else { continue }
            var details: [String] = []
            if let owner = item.owner, !owner.isEmpty { details.append("Owner: \(owner)") }
            if item.dueDate == nil, let due = item.dueText, !due.isEmpty {
                details.append("Due: \(due)")
            }
            details.append(
                "From the meeting “\(meeting.title)” on \(DayKey.string(for: meeting.startedAt))")
            let task = TaskItem(
                title: item.text, notes: details.joined(separator: "\n"), dueDate: item.dueDate,
                tags: ["meeting"])
            items[position].taskID = task.id
            added.append(task)
        }
        guard !added.isEmpty else { return [] }
        try mutate {
            $0.tasks.append(contentsOf: added)
            $0.meetings[index].actionItems = items
        }
        return added
    }

    /// Deletes everything.
    public func eraseAll() throws {
        try mutate { $0 = MomoData() }
    }

    // MARK: - Persistence

    private func mutate(_ change: (inout MomoData) -> Void) throws {
        reloadIfNeeded()
        if let error = loadProblem?.writeError(for: fileURL) { throw error }
        var updated = data
        change(&updated)
        try write(updated)
        data = updated
        for observer in observers.values { observer.yield(updated) }
    }

    private func write(_ value: MomoData) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: fileURL, options: [.atomic])
        loadedModificationDate = modificationDate()
    }

    private func reloadIfNeeded() {
        let modified = modificationDate()
        guard modified != loadedModificationDate else { return }
        loadedModificationDate = modified
        guard modified != nil else {
            data = MomoData()
            return
        }
        let skipped = SkippedElements()
        let decoded: MomoData
        do {
            let contents = try Data(contentsOf: fileURL)
            decoded = try StoreFile.decoder(counting: skipped).decode(MomoData.self, from: contents)
        } catch {
            // Writing would replace everything in the file, so it is moved aside first.
            let backup = try? StoreFile.backUp(fileURL, label: "corrupt", keepingOriginal: false)
            if backup != nil { loadedModificationDate = nil }
            loadProblem = .unreadable(backup: backup)
            data = MomoData()
            for observer in observers.values { observer.yield(data) }
            return
        }
        if decoded.version > MomoData.currentVersion {
            loadProblem = .newerVersion(decoded.version)
        } else if skipped.count > 0 {
            // The next write drops the skipped items, so the file is kept as it is.
            let backup = try? StoreFile.backUp(fileURL, label: "backup", keepingOriginal: true)
            loadProblem = .skippedItems(count: skipped.count, backup: backup)
        } else if loadProblem?.writeError(for: fileURL) != nil {
            // The file was fixed. A problem that left a backup stays, so the app can still tell.
            loadProblem = nil
        }
        data = decoded
        for observer in observers.values { observer.yield(decoded) }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate]
            as? Date
    }

    /// Finds an item by exact ID, then exact title, then a unique partial title match.
    ///
    /// - Parameter exactOnly: Skips the partial match, for changes that can't be undone, so a
    ///   vague reference can't hit the wrong item. Partial matches are listed in the error.
    static func index<Item>(
        in items: [Item], reference: String, kind: String, id: KeyPath<Item, String>,
        title: KeyPath<Item, String>, isEligible: (Item) -> Bool, exactOnly: Bool = false
    ) throws -> Int {
        let needle = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = items.firstIndex(where: { $0[keyPath: id] == needle.lowercased() }) {
            return index
        }
        let eligible = items.indices.filter { isEligible(items[$0]) }
        if let index = eligible.first(where: {
            items[$0][keyPath: title].localizedCaseInsensitiveCompare(needle) == .orderedSame
        }) {
            return index
        }
        let partial = eligible.filter {
            items[$0][keyPath: title].localizedCaseInsensitiveContains(needle)
        }
        if partial.count == 1, !exactOnly { return partial[0] }
        if partial.isEmpty {
            throw ToolError("No \(kind) matches '\(reference)'.")
        }
        let names = partial.prefix(5).map {
            "\(items[$0][keyPath: id]): \(items[$0][keyPath: title])"
        }
        if exactOnly {
            throw ToolError(
                "No \(kind) is exactly '\(reference)'. Close matches: "
                    + "\(names.joined(separator: "; ")). Use the ID.")
        }
        throw ToolError(
            "Several \(kind)s match '\(reference)': \(names.joined(separator: "; ")). Use the ID.")
    }
}
