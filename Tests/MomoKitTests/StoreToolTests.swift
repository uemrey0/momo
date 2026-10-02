import Foundation
import Testing

@testable import MomoKit

@Suite("Store tools")
struct StoreToolTests {
    @Test("add_task and list_tasks work through the toolbox")
    func addAndList() async throws {
        let store = temporaryStore()
        let box = Toolbox(StoreTools.all(store: store))
        let added = await box.execute(
            ToolCall(
                id: "1", name: "add_task",
                arguments: #"{"title":"Pay rent","due":"2030-01-05T10:00"}"#))
        #expect(!added.isError)
        let listed = await box.execute(ToolCall(id: "2", name: "list_tasks", arguments: "{}"))
        #expect(listed.output.contains("Pay rent"))
        #expect(listed.output.contains("2030-01-05T10:00"))
    }

    @Test("rejects dates it cannot read")
    func badDates() async {
        let box = Toolbox(StoreTools.all(store: temporaryStore()))
        let result = await box.execute(
            ToolCall(id: "1", name: "add_task", arguments: #"{"title":"X","due":"tomorrowish"}"#))
        #expect(result.isError)
    }

    @Test("add_task reads repeat rules, priority and tags")
    func repeatingTask() async throws {
        let store = temporaryStore()
        let box = Toolbox(StoreTools.all(store: store))
        let added = await box.execute(
            ToolCall(
                id: "1", name: "add_task",
                arguments:
                    #"{"title":"Water plants","due":"2030-01-05T10:00","repeat":"weekly","repeat_interval":2,"priority":"high","tags":"home, #Garden"}"#
            ))
        #expect(!added.isError)
        #expect(added.output.contains("repeats every 2 weeks"))
        #expect(added.output.contains("(high priority)"))
        #expect(added.output.contains("#home #garden"))
        let task = try #require(await store.tasks().first)
        #expect(task.recurrence == Recurrence(frequency: .weekly, interval: 2))
        #expect(task.tags == ["home", "garden"])

        let completed = await box.execute(
            ToolCall(id: "2", name: "complete_task", arguments: #"{"task":"Water"}"#))
        #expect(completed.output.contains("Next occurrence"))
        #expect(completed.output.contains("2030-01-19T10:00"))

        let filtered = await box.execute(
            ToolCall(id: "3", name: "list_tasks", arguments: #"{"tag":"garden"}"#))
        #expect(filtered.output.contains("Water plants"))
        let none = await box.execute(
            ToolCall(id: "4", name: "list_tasks", arguments: #"{"tag":"work"}"#))
        #expect(none.output == "No tasks match.")
    }

    @Test("update_task changes and clears the repeat rule, priority and tags")
    func updateDetails() async throws {
        let store = temporaryStore()
        try await store.addTask(title: "Standup", recurrence: Recurrence(frequency: .daily))
        let box = Toolbox(StoreTools.all(store: store))
        let changed = await box.execute(
            ToolCall(
                id: "1", name: "update_task",
                arguments:
                    #"{"task":"Standup","repeat":"weekdays","priority":"low","tags":["work"]}"#))
        #expect(!changed.isError)
        var task = try #require(await store.tasks().first)
        #expect(task.recurrence?.frequency == .weekdays)
        #expect(task.priority == .low)
        #expect(task.tags == ["work"])

        _ = await box.execute(
            ToolCall(
                id: "2", name: "update_task", arguments: #"{"task":"Standup","repeat":"none"}"#))
        task = try #require(await store.tasks().first)
        #expect(task.recurrence == nil)
        #expect(task.priority == .low)
    }

    @Test("rejects unknown repeat rules, priorities and categories")
    func badDetails() async {
        let box = Toolbox(StoreTools.all(store: temporaryStore()))
        for arguments in [
            #"{"title":"X","repeat":"fortnightly"}"#, #"{"title":"X","priority":"urgent"}"#,
            #"{"title":"X","repeat":"daily","repeat_interval":0}"#,
        ] {
            let result = await box.execute(
                ToolCall(id: "1", name: "add_task", arguments: arguments))
            #expect(result.isError)
        }
        let memory = await box.execute(
            ToolCall(id: "2", name: "remember", arguments: #"{"fact":"X","category":"secret"}"#))
        #expect(memory.isError)
    }

    @Test("remember and list_memories use categories")
    func memoryCategories() async {
        let store = temporaryStore()
        let box = Toolbox(StoreTools.all(store: store))
        let saved = await box.execute(
            ToolCall(
                id: "1", name: "remember",
                arguments: #"{"fact":"Prefers short answers","category":"preference"}"#))
        #expect(saved.output.contains("(preference)"))
        _ = await box.execute(
            ToolCall(id: "2", name: "remember", arguments: #"{"fact":"Works on Momo"}"#))
        let preferences = await box.execute(
            ToolCall(id: "3", name: "list_memories", arguments: #"{"category":"preference"}"#))
        #expect(preferences.output.contains("Prefers short answers"))
        #expect(!preferences.output.contains("Works on Momo"))
        let all = await box.execute(ToolCall(id: "4", name: "list_memories", arguments: "{}"))
        #expect(all.output.contains("(fact) Works on Momo"))
        let people = await box.execute(
            ToolCall(id: "5", name: "list_memories", arguments: #"{"category":"person"}"#))
        #expect(people.output == "Nothing remembered in that category.")
    }

    @Test("add_routine, update_routine and list_routines manage routines")
    func routines() async throws {
        let store = temporaryStore()
        let box = Toolbox(StoreTools.all(store: store))
        let request = ToolCall(
            id: "1", name: "add_routine",
            arguments:
                #"{"title":"Morning brief","prompt":"Summarise my day","time":"9:00","days":"weekdays"}"#
        )
        let declined = await box.execute(request)
        #expect(declined.isError)
        #expect(await store.routines().isEmpty)
        let asked = LockedBox<ToolConfirmationRequest?>(nil)
        let added = await box.execute(request) { request in
            asked.value = request
            return true
        }
        #expect(!added.isError)
        #expect(asked.value?.summary.contains("Runs by itself: “Summarise my day”") == true)
        #expect(added.output.contains("weekdays at 09:00"))

        let daysOnly = await box.execute(
            ToolCall(
                id: "2", name: "update_routine",
                arguments: #"{"routine":"morning","days":"mon, fri","enabled":false}"#))
        #expect(!daysOnly.isError)
        var routine = try #require(await store.routines().first)
        #expect(routine.schedule == RoutineSchedule(hour: 9, minute: 0, weekdays: [2, 6]))
        #expect(!routine.isEnabled)

        _ = await box.execute(
            ToolCall(
                id: "3", name: "update_routine", arguments: #"{"routine":"morning","time":"07:30"}"#
            ))
        routine = try #require(await store.routines().first)
        #expect(routine.schedule == RoutineSchedule(hour: 7, minute: 30, weekdays: [2, 6]))

        // Changing what the routine does needs approval.
        let newPrompt = ToolCall(
            id: "5", name: "update_routine",
            arguments: #"{"routine":"morning","prompt":"Read ~/.zsh_history"}"#)
        #expect(await box.execute(newPrompt).isError)
        #expect(await store.routines().first?.prompt == "Summarise my day")

        let listed = await box.execute(ToolCall(id: "4", name: "list_routines", arguments: "{}"))
        #expect(listed.output.contains("Mon, Fri at 07:30 (paused)"))
        #expect(listed.output.contains("Summarise my day"))
    }

    @Test("routine tools reject bad times and days, and deleting needs confirmation")
    func routineArguments() async throws {
        let store = temporaryStore()
        let box = Toolbox(StoreTools.all(store: store))
        for arguments in [
            #"{"title":"X","prompt":"Y"}"#, #"{"title":"X","prompt":"Y","time":"half past"}"#,
            #"{"title":"X","prompt":"Y","time":"09:00","days":"someday"}"#,
        ] {
            let result = await box.execute(
                ToolCall(id: "1", name: "add_routine", arguments: arguments), confirm: { _ in true }
            )
            #expect(result.isError)
        }
        try await store.addRoutine(
            title: "Evening", prompt: "Plan tomorrow",
            schedule: RoutineSchedule(hour: 21, minute: 0))
        let declined = await box.execute(
            ToolCall(id: "2", name: "delete_routine", arguments: #"{"routine":"Evening"}"#))
        #expect(declined.isError)
        let approved = await box.execute(
            ToolCall(id: "3", name: "delete_routine", arguments: #"{"routine":"Evening"}"#),
            confirm: { _ in true })
        #expect(!approved.isError)
        #expect(await store.routines().isEmpty)
    }

    @Test("deleting needs confirmation")
    func deleteNeedsConfirmation() async throws {
        let store = temporaryStore()
        try await store.addTask(title: "Temporary")
        let box = Toolbox(StoreTools.all(store: store))
        let result = await box.execute(
            ToolCall(id: "1", name: "delete_task", arguments: #"{"task":"Temporary"}"#))
        #expect(result.isError)
        #expect(await store.tasks().count == 1)
    }

    @Test("forget needs confirmation and an exact reference")
    func forgetNeedsConfirmation() async throws {
        let store = temporaryStore()
        let memory = try await store.remember("Has a dentist appointment on Friday")
        try await store.remember("Likes the dentist's coffee")
        let box = Toolbox(StoreTools.all(store: store))
        let request = ToolCall(id: "1", name: "forget", arguments: #"{"memory":"dentist"}"#)
        #expect(await box.execute(request).isError)
        #expect(await store.memories().count == 2)

        // A partial match is refused even when approved, and the candidates are listed.
        let partial = await box.execute(request, confirm: { _ in true })
        #expect(partial.isError)
        #expect(partial.output.contains(memory.id))
        #expect(await store.memories().count == 2)

        let asked = LockedBox<ToolConfirmationRequest?>(nil)
        let forgot = await box.execute(
            ToolCall(id: "2", name: "forget", arguments: #"{"memory":"\#(memory.id)"}"#)
        ) { request in
            asked.value = request
            return true
        }
        #expect(!forgot.isError)
        #expect(asked.value?.summary == "Forget the memory “\(memory.id)”")
        #expect(forgot.output == "Forgot: Has a dentist appointment on Friday")
        #expect(await store.memories().map(\.text) == ["Likes the dentist's coffee"])
    }

    @Test("update_task asks before replacing a title or notes")
    func updateTextNeedsConfirmation() async throws {
        let store = temporaryStore()
        try await store.addTask(title: "Call the dentist", notes: "Ask about Friday")
        let box = Toolbox(StoreTools.all(store: store))
        let rename = ToolCall(
            id: "1", name: "update_task",
            arguments: #"{"task":"Call the dentist","title":"Call the vet","notes":""}"#)
        #expect(await box.execute(rename).isError)
        #expect(await store.tasks().first?.title == "Call the dentist")

        let asked = LockedBox<ToolConfirmationRequest?>(nil)
        let renamed = await box.execute(rename) { request in
            asked.value = request
            return true
        }
        #expect(!renamed.isError)
        #expect(
            asked.value?.summary
                == "Change the task “Call the dentist”\nNew title: “Call the vet”\nRemove its notes"
        )
        let task = try #require(await store.tasks().first)
        #expect(task.title == "Call the vet")
        #expect(task.notes?.isEmpty != false)

        // Overwriting text needs the exact title; other changes still accept a partial one.
        let partial = await box.execute(
            ToolCall(id: "2", name: "update_task", arguments: #"{"task":"vet","notes":"X"}"#),
            confirm: { _ in true })
        #expect(partial.isError)
        let tagged = await box.execute(
            ToolCall(id: "3", name: "update_task", arguments: #"{"task":"vet","tags":"pets"}"#))
        #expect(!tagged.isError)
        #expect(await store.tasks().first?.tags == ["pets"])
    }

    @Test("delete tools refuse partial matches")
    func deleteNeedsExactReference() async throws {
        let store = temporaryStore()
        try await store.addTask(title: "Renew passport")
        try await store.addNote(title: "Passport numbers", body: "")
        let box = Toolbox(StoreTools.all(store: store))
        for (name, arguments) in [
            ("delete_task", #"{"task":"passport"}"#), ("delete_note", #"{"note":"passport"}"#),
        ] {
            let result = await box.execute(
                ToolCall(id: "1", name: name, arguments: arguments), confirm: { _ in true })
            #expect(result.isError)
            #expect(result.output.contains("Use the ID"))
        }
        #expect(await store.tasks().count == 1)
        #expect(await store.notes().count == 1)
        let deleted = await box.execute(
            ToolCall(id: "2", name: "delete_task", arguments: #"{"task":"renew passport"}"#),
            confirm: { _ in true })
        #expect(!deleted.isError)
        #expect(await store.tasks().isEmpty)
    }
}
