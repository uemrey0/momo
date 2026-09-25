import Foundation

/// Stores tasks, notes, habits and memories in a single JSON file.
///
/// The file may be shared with other processes (the MCP server), so the store reloads it
/// whenever it changed on disk and writes atomically.
public actor MomoStore {
    public nonisolated let fileURL: URL
    private var data = MomoData()
    private var loadedModificationDate: Date?
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
        title: String, notes: String? = nil, dueDate: Date? = nil, remindAt: Date? = nil
    ) throws -> TaskItem {
        let task = TaskItem(title: title, notes: notes, dueDate: dueDate, remindAt: remindAt)
        try mutate { $0.tasks.append(task) }
        return task
    }

    /// Marks a task done. `reference` is an ID or part of the title.
    @discardableResult
    public func completeTask(_ reference: String) throws -> TaskItem {
        let index = try taskIndex(for: reference, includeDone: false)
        try mutate {
            $0.tasks[index].isDone = true
            $0.tasks[index].completedAt = Date()
        }
        return data.tasks[index]
    }

    @discardableResult
    public func updateTask(
        _ reference: String, title: String? = nil, notes: String? = nil, dueDate: Date?? = nil,
        remindAt: Date?? = nil
    ) throws -> TaskItem {
        let index = try taskIndex(for: reference, includeDone: true)
        try mutate {
            if let title { $0.tasks[index].title = title }
            if let notes { $0.tasks[index].notes = notes }
            if let dueDate { $0.tasks[index].dueDate = dueDate }
            if let remindAt { $0.tasks[index].remindAt = remindAt }
        }
        return data.tasks[index]
    }

    @discardableResult
    public func deleteTask(_ reference: String) throws -> TaskItem {
        let index = try taskIndex(for: reference, includeDone: true)
        let task = data.tasks[index]
        try mutate { $0.tasks.remove(at: index) }
        return task
    }

    public func setTaskDone(id: String, _ done: Bool) throws {
        let index = try taskIndex(for: id, includeDone: true)
        try mutate {
            $0.tasks[index].isDone = done
            $0.tasks[index].completedAt = done ? Date() : nil
        }
    }

    private func taskIndex(for reference: String, includeDone: Bool) throws -> Int {
        reloadIfNeeded()
        return try Self.index(
            in: data.tasks, reference: reference, kind: "task",
            id: \.id, title: \.title, isEligible: { includeDone || !$0.isDone })
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
        let index = try noteIndex(for: reference)
        let note = data.notes[index]
        try mutate { $0.notes.remove(at: index) }
        return note
    }

    private func noteIndex(for reference: String) throws -> Int {
        reloadIfNeeded()
        return try Self.index(
            in: data.notes, reference: reference, kind: "note", id: \.id, title: \.title,
            isEligible: { _ in true })
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

    public func memories() -> [Memory] {
        reloadIfNeeded()
        return data.memories.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func remember(_ text: String) throws -> Memory {
        reloadIfNeeded()
        if let existing = data.memories.first(where: {
            $0.text.localizedCaseInsensitiveCompare(text) == .orderedSame
        }) {
            return existing
        }
        let memory = Memory(text: text)
        try mutate { $0.memories.append(memory) }
        return memory
    }

    @discardableResult
    public func forget(_ reference: String) throws -> Memory {
        reloadIfNeeded()
        let index = try Self.index(
            in: data.memories, reference: reference, kind: "memory", id: \.id, title: \.text,
            isEligible: { _ in true })
        let memory = data.memories[index]
        try mutate { $0.memories.remove(at: index) }
        return memory
    }

    /// Deletes everything.
    public func eraseAll() throws {
        try mutate { $0 = MomoData() }
    }

    // MARK: - Persistence

    private func mutate(_ change: (inout MomoData) -> Void) throws {
        reloadIfNeeded()
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
        guard modified != nil, let contents = try? Data(contentsOf: fileURL) else {
            data = MomoData()
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(MomoData.self, from: contents) {
            data = decoded
            for observer in observers.values { observer.yield(decoded) }
        }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate]
            as? Date
    }

    /// Finds an item by exact ID, then exact title, then a unique partial title match.
    static func index<Item>(
        in items: [Item], reference: String, kind: String, id: KeyPath<Item, String>,
        title: KeyPath<Item, String>, isEligible: (Item) -> Bool
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
        if partial.count == 1 { return partial[0] }
        if partial.isEmpty {
            throw ToolError("No \(kind) matches '\(reference)'.")
        }
        let names = partial.prefix(5).map {
            "\(items[$0][keyPath: id]): \(items[$0][keyPath: title])"
        }
        throw ToolError(
            "Several \(kind)s match '\(reference)': \(names.joined(separator: "; ")). Use the ID.")
    }
}
