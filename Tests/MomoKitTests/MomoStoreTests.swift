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
        try await store.forget("name")
        #expect(await store.memories().isEmpty)
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
}
