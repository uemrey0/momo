import Foundation
import Testing

@testable import MomoKit

@Suite("MomoStore")
struct MomoStoreTests {
    @Test("adds, completes and lists tasks")
    func tasks() async throws {
        let store = temporaryStore()
        let milk = try await store.addTask(title: "Buy milk")
        try await store.addTask(title: "Call Ayşe", dueDate: Date(timeIntervalSinceNow: 3600))
        #expect(await store.tasks().count == 2)
        #expect(await store.tasks().first?.title == "Call Ayşe")

        try await store.completeTask(milk.id)
        #expect(await store.tasks().count == 1)
        #expect(await store.tasks(includeDone: true).count == 2)
    }

    @Test("finds items by partial title and rejects ambiguous references")
    func references() async throws {
        let store = temporaryStore()
        try await store.addTask(title: "Write report")
        try await store.addTask(title: "Write email")
        await #expect(throws: ToolError.self) { try await store.completeTask("write") }
        let done = try await store.completeTask("report")
        #expect(done.title == "Write report")
        await #expect(throws: ToolError.self) { try await store.completeTask("missing") }
    }

    @Test("persists and reloads changes made by another process")
    func persistence() async throws {
        let first = temporaryStore()
        try await first.addNote(title: "Ideas", body: "Momo wears a hat")
        let second = MomoStore(fileURL: first.fileURL)
        #expect(await second.searchNotes("hat").count == 1)

        try await second.appendToNote("Ideas", text: "and a scarf")
        try await Task.sleep(for: .milliseconds(20))
        let body = await first.notes().first?.body
        #expect(body?.contains("scarf") == true)
    }

    @Test("saves edits to a note in place")
    func saveNote() async throws {
        let store = temporaryStore()
        var note = try await store.addNote(title: "Draft", body: "one")
        note.body = "two"
        try await store.saveNote(note)
        let notes = await store.notes()
        #expect(notes.count == 1)
        #expect(notes.first?.id == note.id)
        #expect(notes.first?.body == "two")
    }

    @Test("tracks habit streaks")
    func habits() async throws {
        let store = temporaryStore()
        let calendar = Calendar.current
        let today = Date()
        for offset in 0..<3 {
            let day = try #require(calendar.date(byAdding: .day, value: -offset, to: today))
            try await store.logHabit("Drink water", on: day)
        }
        let habit = try #require(await store.habits().first)
        #expect(habit.streak(asOf: today) == 3)
        #expect(await store.habits().count == 1)
    }

    @Test("remembers each fact once and forgets it")
    func memories() async throws {
        let store = temporaryStore()
        try await store.remember("The user's name is Emre")
        try await store.remember("the user's name is emre")
        #expect(await store.memories().count == 1)
        try await store.forget("The user's name is Emre")
        #expect(await store.memories().isEmpty)
    }

    @Test("files memories by category and updates the category of a known memory")
    func memoryCategories() async throws {
        let store = temporaryStore()
        try await store.remember("Prefers short answers", category: .preference)
        try await store.remember("Ayşe is the user's sister")
        #expect(await store.memories(in: .preference).count == 1)
        #expect(await store.memories(in: .fact).count == 1)
        let updated = try await store.remember("ayşe is the user's sister", category: .person)
        #expect(updated.category == .person)
        #expect(await store.memories().count == 2)
        // Remembering again without a category keeps the one it has.
        try await store.remember("Ayşe is the user's sister")
        #expect(await store.memories(in: .person).count == 1)
    }

    @Test("completing a repeating task adds the next occurrence")
    func recurringTasks() async throws {
        let store = temporaryStore()
        let calendar = testCalendar()
        let due = date(2026, 9, 25, 18)
        let task = try await store.addTask(
            title: "Take out the trash", dueDate: due, remindAt: due.addingTimeInterval(-3600),
            recurrence: Recurrence(frequency: .weekly), priority: .high, tags: ["#Home", "home"])
        #expect(task.tags == ["home"])
        let done = try await store.completeTask(
            "trash", at: date(2026, 9, 26, 10), calendar: calendar)
        #expect(done.isDone)
        let nextID = try #require(done.nextOccurrenceID)
        let next = try #require(await store.task(id: nextID))
        #expect(next.dueDate == date(2026, 10, 2, 18))
        #expect(next.remindAt == date(2026, 10, 2, 17))
        #expect(next.priority == .high)
        #expect(await store.tasks().map(\.id) == [nextID])
    }

    @Test("unticking a repeating task removes the occurrence it created")
    func untickRecurring() async throws {
        let store = temporaryStore()
        let task = try await store.addTask(
            title: "Stretch", dueDate: Date(), recurrence: Recurrence(frequency: .daily))
        try await store.setTaskDone(id: task.id, true)
        #expect(await store.tasks(includeDone: true).count == 2)
        try await store.setTaskDone(id: task.id, true)
        #expect(await store.tasks(includeDone: true).count == 2)
        try await store.setTaskDone(id: task.id, false)
        let tasks = await store.tasks(includeDone: true)
        #expect(tasks.map(\.id) == [task.id])
        #expect(tasks.first?.isDone == false)
    }

    @Test("adds, updates, runs and deletes routines")
    func routines() async throws {
        let store = temporaryStore()
        let routine = try await store.addRoutine(
            title: "Morning brief", prompt: "Summarise my day",
            schedule: RoutineSchedule(hour: 9, minute: 0, weekdays: RoutineSchedule.workweek))
        let updated = try await store.updateRoutine(
            "morning", prompt: "Summarise my day and the weather", isEnabled: false)
        #expect(updated.id == routine.id)
        #expect(!updated.isEnabled)
        let now = Date()
        try await store.markRoutineRun(id: routine.id, at: now)
        #expect(await store.routines().first?.lastRun == now)
        var edited = updated
        edited.title = "Morning"
        try await store.saveRoutine(edited)
        #expect(await store.routines().map(\.title) == ["Morning"])
        try await store.deleteRoutine(routine.id)
        #expect(await store.routines().isEmpty)
    }

    @Test("publishes changes")
    func changes() async throws {
        let store = temporaryStore()
        let stream = await store.changes()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        try await store.addTask(title: "Observe me")
        let next = await iterator.next()
        #expect(next?.tasks.count == 1)
    }

    @Test("moves an unreadable file aside instead of writing over it")
    func corruptFile() async throws {
        let url = temporaryStore().fileURL
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let garbage = Data(#"{"tasks": [{"id": "a1", "title": "Keep me""#.utf8)
        try garbage.write(to: url)

        let store = MomoStore(fileURL: url)
        #expect(await store.tasks().isEmpty)
        let backup = try #require(await store.problem()?.backup)
        #expect(backup.deletingLastPathComponent().path == folder.path)
        #expect(backup.lastPathComponent.hasPrefix("data.corrupt-"))
        #expect(backup.pathExtension == "json")
        #expect(try Data(contentsOf: backup) == garbage)

        try await store.addTask(title: "Fresh start")
        #expect(try Data(contentsOf: backup) == garbage)
        #expect(await MomoStore(fileURL: url).tasks().map(\.title) == ["Fresh start"])
        #expect(await store.problem() == .unreadable(backup: backup))
    }

    @Test("skips a damaged item, keeps the rest and backs up the original")
    func damagedItem() async throws {
        let first = temporaryStore()
        try await first.addTask(title: "Buy milk")
        try await first.addNote(title: "Ideas", body: "Momo wears a hat")
        try await first.remember("The user's name is Emre")
        var json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: first.fileURL))
                as? [String: Any])
        json["tasks"] = (json["tasks"] as? [Any] ?? []) + [["title": 42]]
        json["notes"] = (json["notes"] as? [Any] ?? []) + ["not a note"]
        let damaged = try JSONSerialization.data(withJSONObject: json)
        try damaged.write(to: first.fileURL)

        let store = MomoStore(fileURL: first.fileURL)
        #expect(await store.tasks().map(\.title) == ["Buy milk"])
        #expect(await store.notes().map(\.title) == ["Ideas"])
        #expect(await store.memories().count == 1)
        let problem = try #require(await store.problem())
        guard case .skippedItems(let count, let backup?) = problem else {
            Issue.record("Unexpected problem: \(problem)")
            return
        }
        #expect(count == 2)
        #expect(backup.lastPathComponent.hasPrefix("data.backup-"))
        #expect(try Data(contentsOf: backup) == damaged)

        try await store.addTask(title: "Call Ayşe")
        #expect(await MomoStore(fileURL: first.fileURL).tasks().count == 2)
    }

    @Test("reads a file from a newer Momo but refuses to write it")
    func newerVersion() async throws {
        let first = temporaryStore()
        try await first.addTask(title: "Buy milk")
        var json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: first.fileURL))
                as? [String: Any])
        json["version"] = MomoData.currentVersion + 1
        json["somethingNew"] = ["kept": true]
        let newer = try JSONSerialization.data(withJSONObject: json)
        try newer.write(to: first.fileURL)

        let store = MomoStore(fileURL: first.fileURL)
        #expect(await store.tasks().map(\.title) == ["Buy milk"])
        #expect(await store.problem() == .newerVersion(MomoData.currentVersion + 1))
        await #expect(throws: ToolError.self) { try await store.addTask(title: "Call Ayşe") }
        await #expect(throws: ToolError.self) { try await store.eraseAll() }
        #expect(try Data(contentsOf: first.fileURL) == newer)
    }
}
