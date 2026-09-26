import Foundation
import Testing

@testable import MomoKit

private func temporaryConversationStore(
    maximumConversations: Int = 200, maximumMessages: Int = 400
) -> ConversationStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("momo-tests-\(UUID().uuidString)")
        .appendingPathComponent("conversations.json")
    return ConversationStore(
        fileURL: url, maximumConversations: maximumConversations,
        maximumMessages: maximumMessages)
}

private func conversation(
    _ texts: [String], updatedAt: Date = Date(), id: String = UUID().uuidString
) -> Conversation {
    Conversation(
        id: id, updatedAt: updatedAt,
        messages: texts.enumerated().map { index, text in
            ConversationMessage(role: index.isMultiple(of: 2) ? .user : .assistant, text: text)
        })
}

@Suite("ConversationStore")
struct ConversationStoreTests {
    @Test("titles a conversation after the first user message")
    func title() {
        let long = String(repeating: "word ", count: 40)
        #expect(conversation(["  Plan my\n day  ", "Sure"]).title == "Plan my day")
        let title = conversation([long]).title
        #expect(title.count == Conversation.titleLength)
        #expect(title.hasSuffix("…"))
        let attachmentsOnly = Conversation(messages: [
            ConversationMessage(
                role: .user, text: " ",
                attachments: [
                    .init(name: "shot.png", isImage: true), .init(name: "notes.md", isImage: false),
                ])
        ])
        #expect(attachmentsOnly.title == "shot.png, notes.md")
    }

    @Test("saves, reloads in another instance and lists the newest first")
    func persistence() async throws {
        let store = temporaryConversationStore()
        let older = conversation(["First"], updatedAt: Date(timeIntervalSinceNow: -60))
        try await store.save(older)
        var newer = conversation(["Second", "Reply"])
        newer.messages[1].toolRecords = [
            ToolRecord(name: "list_tasks", arguments: "{}", result: "a1: Milk")
        ]
        newer.messages[1].brainKind = .apiKey
        try await store.save(newer)

        let reloaded = ConversationStore(fileURL: store.fileURL)
        let all = await reloaded.all()
        #expect(all.map(\.title) == ["Second", "First"])
        #expect(all.first?.messages[1].toolRecords.first?.result == "a1: Milk")
        #expect(all.first?.messages[1].brainKind == .apiKey)

        // Saving again replaces the conversation and moves it to the top.
        var updated = older
        updated.messages.append(ConversationMessage(role: .assistant, text: "Answer"))
        updated.updatedAt = Date(timeIntervalSinceNow: 10)
        try await reloaded.save(updated)
        #expect(await reloaded.all().map(\.id) == [older.id, newer.id])
        #expect(await reloaded.conversation(id: older.id)?.messages.count == 2)

        try await reloaded.delete(id: older.id)
        #expect(await reloaded.all().map(\.id) == [newer.id])
    }

    @Test("does not save empty conversations")
    func empty() async throws {
        let store = temporaryConversationStore()
        try await store.save(Conversation())
        #expect(await store.all().isEmpty)
    }

    @Test("searches titles and messages ignoring case and diacritics")
    func search() async throws {
        let store = temporaryConversationStore()
        try await store.save(conversation(["Call Ayşe about the trip", "Sure"]))
        try await store.save(conversation(["Groceries", "Buy MILK and bread"]))
        try await store.save(conversation(["Işık bill", "Paid"]))

        #expect(await store.search("ayse").map(\.title) == ["Call Ayşe about the trip"])
        #expect(await store.search("milk bread").map(\.title) == ["Groceries"])
        #expect(await store.search("isik").map(\.title) == ["Işık bill"])
        #expect(await store.search("milk trip").isEmpty)
        #expect(await store.search("  ").count == 3)
    }

    @Test("keeps only the newest conversations and messages")
    func caps() async throws {
        let store = temporaryConversationStore(maximumConversations: 3, maximumMessages: 4)
        for index in 0..<5 {
            try await store.save(
                conversation(
                    ["Chat \(index)"], updatedAt: Date(timeIntervalSinceNow: Double(index))))
        }
        #expect(await store.all().map(\.title) == ["Chat 4", "Chat 3", "Chat 2"])

        let long = conversation((0..<10).map { "Message \($0)" })
        let saved = try await store.save(long)
        #expect(saved.messages.map(\.text) == ["Message 6", "Message 7", "Message 8", "Message 9"])
        #expect(saved.title == "Message 0")
    }

    @Test("reads files without newer fields")
    func decodesOlderFiles() throws {
        let json = #"""
            [{"id":"c1","title":"Hi","createdAt":"2026-01-01T10:00:00Z",
              "updatedAt":"2026-01-01T10:00:00Z","messages":[{"role":"user","text":"Hi"}]}]
            """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([Conversation].self, from: Data(json.utf8))
        #expect(decoded.first?.messages.first?.toolRecords == [])
        #expect(decoded.first?.messages.first?.activities == [])
        #expect(decoded.first?.messages.first?.attachments == [])
    }
}

@Suite("Tool records")
struct ToolRecordTests {
    @Test("keeps small records as they are, with whitespace condensed")
    func small() {
        let records = ToolRecord.compact([
            ToolRecord(name: "list_tasks", arguments: "{ }", result: "a1: Milk\nb2: Bread")
        ])
        #expect(
            records == [
                ToolRecord(name: "list_tasks", arguments: "{ }", result: "a1: Milk b2: Bread")
            ])
    }

    @Test("fits a turn's records into the budget, sharing it between results")
    func budget() {
        let long = String(repeating: "x", count: 5_000)
        let records = ToolRecord.compact(
            [
                ToolRecord(name: "short", arguments: "{}", result: "ok"),
                ToolRecord(name: "search_notes", arguments: #"{"query":"trip"}"#, result: long),
                ToolRecord(name: "read_screen", arguments: "{}", result: long),
            ], budget: 1_500)
        let total = records.reduce(0) { $0 + $1.name.count + $1.arguments.count + $1.result.count }
        #expect(total <= 1_500)
        #expect(records.count == 3)
        #expect(records[0].result == "ok")
        #expect(records[1].result.hasSuffix("…"))
        #expect(records[1].result.count > 600)
    }

    @Test("drops the oldest calls when even their arguments don't fit")
    func dropsOldest() {
        let arguments = String(repeating: "a", count: 300)
        let records = ToolRecord.compact(
            (0..<20).map { ToolRecord(name: "tool\($0)", arguments: arguments, result: "done") },
            budget: 1_500)
        #expect(records.last?.name == "tool19")
        #expect(records.count < 20)
        #expect(records.allSatisfy { $0.arguments.count <= 200 })
    }

    @Test("renders records as context lines")
    func render() {
        #expect(ToolRecord.render([]) == "")
        let text = ToolRecord.render([
            ToolRecord(name: "list_tasks", arguments: "{}", result: "a1: Milk"),
            ToolRecord(
                name: "delete_task", arguments: #"{"id":"zz"}"#, result: "No task", isError: true),
        ])
        #expect(text.hasPrefix("Tools used this turn"))
        #expect(text.contains("- list_tasks {} → a1: Milk"))
        #expect(text.contains(#"- delete_task {"id":"zz"} → error: No task"#))
    }
}
