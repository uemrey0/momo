import Foundation
import Testing

@testable import MomoVoice

/// Records what the fake brain saw.
final class BrainLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
}

@Suite("ask_momo", .timeLimit(.minutes(1)))
struct MomoRealtimeAgentTests {
    @Test("declares one required request and optional confirmation fields")
    func function() {
        let function = MomoRealtimeAgent.askMomo
        #expect(function.name == "ask_momo")
        #expect(function.parameters.map(\.name) == ["request", "confirmation_id", "confirmed"])
        #expect(function.parameters.filter(\.isRequired).map(\.name) == ["request"])
        #expect(function.parameters.last?.kind == .boolean)
        let schema = RealtimeParameter.schema(function.parameters)
        #expect(schema["required"] as? [String] == ["request"])
    }

    @Test("instructions delegate everything real and describe the confirmation flow")
    func instructions() {
        let text = MomoRealtimeAgent.instructions(
            .init(userName: "Ufuk", language: "tr-TR", additionalInstructions: "Be cheeky."))
        #expect(text.hasPrefix("You are Momo"))
        #expect(text.contains("the user, Ufuk,"))
        #expect(text.contains("Speak Turkish"))
        #expect(text.contains("ALWAYS call ask_momo"))
        #expect(text.contains("confirmation_id"))
        #expect(text.contains("Never invent results"))
        #expect(text.hasSuffix("Be cheeky."))
        let plain = MomoRealtimeAgent.instructions()
        #expect(plain.contains("Speak the user's language"))
        #expect(!plain.contains("More about you"))
    }

    @Test("reads calls from the model's arguments")
    func calls() {
        func call(_ arguments: String, name: String = "ask_momo") -> AskMomoCall? {
            AskMomoCall(RealtimeFunctionCall(id: "c", name: name, arguments: arguments))
        }
        #expect(
            call(#"{"request":" Yarın 9'da diş hekimi "}"#)
                == AskMomoCall(request: "Yarın 9'da diş hekimi"))
        #expect(
            call(#"{"request":"Delete it","confirmation_id":"confirm-1","confirmed":true}"#)
                == AskMomoCall(request: "Delete it", confirmationID: "confirm-1", confirmed: true))
        #expect(call(#"{"confirmation_id":"confirm-2","confirmed":"no"}"#)?.confirmed == false)
        #expect(call(#"{"confirmation_id":"confirm-2"}"#)?.isConfirmationAnswer == true)
        #expect(call(#"{"request":""}"#) == nil)
        #expect(call(#"{"request":"x"}"#, name: "other") == nil)
        #expect(call("not json") == nil)
    }

    @Test("encodes results as JSON with a status")
    func results() throws {
        let done = try #require(RealtimeJSON.object(AskMomoResult.answer("**Added** it.").output))
        #expect(done["status"] as? String == "done")
        #expect(done["answer"] as? String == "Added it.")
        let confirm = try #require(
            RealtimeJSON.object(
                AskMomoResult.needsConfirmation(id: "confirm-1", question: "Delete?").output))
        #expect(confirm["status"] as? String == "needs_confirmation")
        #expect(confirm["confirmation_id"] as? String == "confirm-1")
        #expect(confirm["question"] as? String == "Delete?")
        let failed = try #require(RealtimeJSON.object(AskMomoResult.failed("Offline.").output))
        #expect(failed["status"] as? String == "failed")
        #expect(failed["error"] as? String == "Offline.")
    }

    @Test("returns the brain's answer")
    func answer() async {
        let log = BrainLog()
        let coordinator = AskMomoCoordinator { request, _ in
            log.add(request)
            return "Done."
        }
        #expect(await coordinator.handle(AskMomoCall(request: "Add milk")) == .answer("Done."))
        #expect(log.all == ["Add milk"])
    }

    @Test("carries a confirmation question through the conversation", arguments: [true, false])
    func confirmation(yes: Bool) async {
        let coordinator = AskMomoCoordinator { _, confirm in
            await confirm("Delete the note Shopping?") ? "Deleted." : "Kept it."
        }
        let first = await coordinator.handle(AskMomoCall(request: "Delete the note Shopping"))
        #expect(
            first == .needsConfirmation(id: "confirm-1", question: "Delete the note Shopping?"))
        #expect(await coordinator.pendingConfirmationID == "confirm-1")
        let second = await coordinator.handle(
            AskMomoCall(
                request: "Delete the note Shopping", confirmationID: "confirm-1", confirmed: yes))
        #expect(second == .answer(yes ? "Deleted." : "Kept it."))
        #expect(await coordinator.pendingConfirmationID == nil)
    }

    @Test("a new request answers a waiting question with no")
    func superseded() async {
        let log = BrainLog()
        let coordinator = AskMomoCoordinator { request, confirm in
            if request == "Delete everything" {
                log.add("answer: \(await confirm("Really?"))")
                return "unused"
            }
            return "Weather is sunny."
        }
        _ = await coordinator.handle(AskMomoCall(request: "Delete everything"))
        #expect(
            await coordinator.handle(AskMomoCall(request: "Weather?"))
                == .answer("Weather is sunny."))
        for _ in 0..<100 where log.all.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(log.all == ["answer: false"])
    }

    @Test("rejects answers to questions nobody asked, and reports failures")
    func failures() async {
        struct Offline: LocalizedError { var errorDescription: String? { "No brain is ready." } }
        let coordinator = AskMomoCoordinator { _, _ in throw Offline() }
        guard
            case .failed = await coordinator.handle(
                AskMomoCall(request: "", confirmationID: "confirm-9", confirmed: true))
        else {
            Issue.record("expected a failure")
            return
        }
        #expect(
            await coordinator.handle(AskMomoCall(request: "x")) == .failed("No brain is ready."))
    }

    @Test("cancel ends a waiting call")
    func cancel() async {
        let log = BrainLog()
        let coordinator = AskMomoCoordinator { _, _ in
            log.add("started")
            try await Task.sleep(for: .seconds(30))
            return "late"
        }
        let call = Task { await coordinator.handle(AskMomoCall(request: "Slow")) }
        for _ in 0..<200 where log.all.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        await coordinator.cancel()
        #expect(await call.value == .failed("The request was cancelled."))
    }
}
