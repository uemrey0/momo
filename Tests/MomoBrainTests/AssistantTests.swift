import Foundation
import MomoKit
import Testing

@testable import MomoBrain

/// A scripted provider that records what it was asked.
struct FakeProvider: ChatProvider {
    let info: ProviderInfo
    var ready = true
    var reply: [ChatEvent]
    let seen = LockedBox<[ChatRequest]>([])
    var callsTool: ToolCall?

    func availability() async -> ProviderAvailability {
        ready ? .ready : .unavailable("off")
    }

    func respond(
        to request: ChatRequest, runTool: @escaping ToolRunner
    )
        -> AsyncThrowingStream<ChatEvent, any Error>
    {
        seen.append(request)
        let reply = reply
        let callsTool = callsTool
        return AsyncThrowingStream { continuation in
            Task {
                if let callsTool {
                    continuation.yield(.toolStarted(callsTool))
                    continuation.yield(.toolFinished(await runTool(callsTool)))
                }
                for event in reply { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

@Suite("Assistant")
struct AssistantTests {
    let local = FakeProvider(
        info: ProviderInfo(id: "local", name: "Local", kind: .local), reply: [.text("local answer")]
    )

    func configuration(
        _ providers: [any ChatProvider], toolbox: Toolbox = Toolbox()
    ) -> Assistant.Configuration {
        Assistant.Configuration(
            providers: providers, toolbox: toolbox, policy: RoutingPolicy(),
            masksPersonalData: true, systemPrompt: "Mail: boss@company.com")
    }

    func run(
        _ assistant: Assistant, _ message: String, _ configuration: Assistant.Configuration,
        consent: RemoteConsent = .allowOnce
    ) async throws -> [AssistantEvent] {
        var events: [AssistantEvent] = []
        for try await event in await assistant.reply(
            to: message, configuration: configuration, consent: { _, _, _ in consent },
            confirm: { _ in true })
        {
            events.append(event)
        }
        return events
    }

    @Test("answers simple requests locally and keeps history")
    func local() async throws {
        let assistant = Assistant()
        let events = try await run(assistant, "hi", configuration([local]))
        #expect(events.first == .brainSelected(local.info, .onlyOption))
        #expect(events.last == .text("local answer"))
        #expect(await assistant.history.count == 2)
    }

    @Test("masks personal data for remote brains and restores it in replies and tools")
    func masking() async throws {
        let recorded = LockedBox<[String]>([])
        let tool = ClosureTool(ToolDefinition(name: "note", description: "Note")) { arguments in
            recorded.append(arguments["text"]?.stringValue ?? "")
            return "saved for ayse@example.com"
        }
        let remote = FakeProvider(
            info: ProviderInfo(id: "remote", name: "Remote", kind: .apiKey),
            reply: [.text("I emailed [EMA"), .text("IL_2] for you")],
            callsTool: ToolCall(id: "1", name: "note", arguments: #"{"text":"call [EMAIL_2]"}"#))
        let assistant = Assistant()
        await assistant.setForcedProvider("remote")
        let events = try await run(
            assistant, "Write to ayse@example.com",
            configuration([remote], toolbox: Toolbox([tool])))

        let sent = try #require(remote.seen.value.first)
        #expect(!sent.systemPrompt.contains("boss@company.com"))
        #expect(!(sent.turns.last?.text.contains("ayse@example.com") ?? true))
        let reply = events.compactMap { if case .text(let text) = $0 { text } else { nil } }
            .joined()
        #expect(reply == "I emailed ayse@example.com for you")
        #expect(recorded.value == ["call ayse@example.com"])
        #expect(await assistant.history.last?.text == reply)
    }

    @Test("falls back to the local brain when the user declines remote use")
    func consentUseLocal() async throws {
        let remote = FakeProvider(
            info: ProviderInfo(id: "remote", name: "Remote", kind: .subscription),
            reply: [.text("remote")])
        let assistant = Assistant()
        await assistant.setForcedProvider("remote")
        let events = try await run(
            assistant, "hi", configuration([local, remote]), consent: .useLocal)
        #expect(events.contains(.text("local answer")))
        #expect(remote.seen.value.isEmpty)
    }

    @Test("does nothing when the user cancels")
    func consentCancel() async throws {
        let remote = FakeProvider(
            info: ProviderInfo(id: "remote", name: "Remote", kind: .apiKey), reply: [.text("x")])
        let assistant = Assistant()
        await assistant.setForcedProvider("remote")
        let events = try await run(assistant, "hi", configuration([remote]), consent: .cancel)
        #expect(events.isEmpty)
        #expect(await assistant.history.isEmpty)
    }

    @Test("explains why no brain is available")
    func noBrain() async {
        var off = local
        off.ready = false
        let assistant = Assistant()
        await #expect(throws: ProviderError.self) {
            _ = try await run(assistant, "hi", configuration([off]))
        }
    }
}
