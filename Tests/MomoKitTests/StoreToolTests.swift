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
}
