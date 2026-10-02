import Foundation
import MomoKit
import Testing

@testable import MomoBrain

@Suite("Conversation history")
struct HistoryTests {
    let local = FakeProvider(
        info: ProviderInfo(id: "local", name: "Local", kind: .local), reply: [.text("ok")])

    func configuration(
        _ providers: [any ChatProvider], toolbox: Toolbox = Toolbox()
    ) -> Assistant.Configuration {
        Assistant.Configuration(
            providers: providers, toolbox: toolbox, policy: RoutingPolicy(),
            masksPersonalData: true, systemPrompt: "You are Momo.")
    }

    func run(
        _ assistant: Assistant, _ message: String, _ configuration: Assistant.Configuration
    ) async throws {
        for try await _ in await assistant.reply(
            to: message, configuration: configuration, consent: { _, _, _ in .allowOnce },
            confirm: { _ in true })
        {}
    }

    @Test("continues a restored conversation with its earlier turns and tool records")
    func restore() async throws {
        let assistant = Assistant()
        let earlier = [
            ChatTurn(role: .user, text: "What's on my list?"),
            ChatTurn(
                role: .assistant, text: "Milk and bread.",
                toolRecords: [
                    ToolRecord(name: "list_tasks", arguments: "{}", result: "a1: Milk; b2: Bread")
                ]),
        ]
        await assistant.restore(history: earlier)
        try await run(assistant, "Delete the second one", configuration([local]))

        let sent = try #require(local.seen.value.first)
        #expect(sent.turns.count == 3)
        #expect(sent.turns[1].contextText.contains("b2: Bread"))
        #expect(await assistant.history.count == 4)

        await assistant.reset()
        #expect(await assistant.history.isEmpty)
    }

    @Test("keeps a compact record of the tools a reply used, masked when sent remotely")
    func toolRecords() async throws {
        let tool = ClosureTool(ToolDefinition(name: "find_contact", description: "Find")) { _ in
            "Found ayse@example.com (id c7)"
        }
        let remote = FakeProvider(
            info: ProviderInfo(id: "remote", name: "Remote", kind: .apiKey),
            reply: [.text("Found her.")],
            callsTool: ToolCall(id: "1", name: "find_contact", arguments: #"{"name":"Ayşe"}"#))
        let assistant = Assistant()
        await assistant.setForcedProvider("remote")
        let configuration = configuration([remote], toolbox: Toolbox([tool]))
        try await run(assistant, "Find Ayşe", configuration)

        // The history keeps the real data...
        let record = try #require(await assistant.history.last?.toolRecords.first)
        #expect(record.name == "find_contact")
        #expect(record.arguments == #"{"name":"Ayşe"}"#)
        #expect(record.result.contains("Found ayse@example.com (id c7)"))
        // A tool Momo doesn't know may return outside text, so it is marked as such.
        #expect(record.result.hasPrefix("<untrusted_content source=\"find_contact\">"))

        // ...but the next request only carries it masked.
        try await run(assistant, "Email her", configuration)
        let sent = try #require(remote.seen.value.last)
        let context = sent.turns[1].contextText
        #expect(context.contains("Tools used this turn"))
        #expect(context.contains("(id c7)"))
        #expect(!context.contains("ayse@example.com"))
    }

    @Test("renders tool records after the reply text and merges them when alternating")
    func contextText() {
        let turn = ChatTurn(
            role: .assistant, text: "Done.",
            toolRecords: [ToolRecord(name: "add_task", arguments: "{}", result: "ok")])
        #expect(turn.contextText.hasPrefix("Done.\n\nTools used this turn"))
        #expect(ChatTurn(role: .user, text: "hi").contextText == "hi")

        let toolsOnly = ChatTurn(
            role: .assistant, text: "",
            toolRecords: [ToolRecord(name: "list_tasks", arguments: "{}", result: "none")])
        let merged = ChatTurn.alternating([
            .init(role: .user, text: "a"), toolsOnly, .init(role: .assistant, text: "b"),
        ])
        #expect(merged.count == 2)
        #expect(merged[1].text == "b")
        #expect(merged[1].toolRecords.count == 1)
    }

    @Test("sends tool records of earlier turns to OpenAI-compatible servers")
    func openAIContext() async throws {
        let (session, host) = MockURLProtocol.session(responses: [
            .init(body: sse([#"{"choices":[{"delta":{"content":"Deleted."}}]}"#, "[DONE]"]))
        ])
        let provider = OpenAICompatibleProvider(
            info: ProviderInfo(id: "test", name: "Test", kind: .apiKey),
            baseURL: URL(string: "https://\(host)/v1")!, model: "m", apiKey: "k", session: session)
        let turns = [
            ChatTurn(role: .user, text: "List"),
            ChatTurn(
                role: .assistant, text: "Two tasks.",
                toolRecords: [ToolRecord(name: "list_tasks", arguments: "{}", result: "b2: Bread")]),
            ChatTurn(role: .user, text: "Delete the second one"),
        ]
        for try await _ in provider.respond(
            to: ChatRequest(systemPrompt: "s", turns: turns),
            runTool: { call in
                ToolResult(callID: call.id, name: call.name, output: "")
            })
        {}
        let body = try #require(MockURLProtocol.requestBodies(host: host).first)
        #expect(body.contains("b2: Bread"))
        #expect(body.contains("Tools used this turn"))
    }
}
