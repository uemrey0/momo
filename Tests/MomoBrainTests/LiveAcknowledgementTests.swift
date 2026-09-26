import Foundation
import MomoKit
import Testing

@testable import MomoBrain

@Suite("Live acknowledgements")
struct LiveAcknowledgementTests {
    @Test(
        "keeps one short sentence",
        arguments: [
            ("Takvimine bakıyorum.", "Takvimine bakıyorum."),
            ("\"Let me check the weather\"", "Let me check the weather."),
            ("Looking that up! One sec.", "Looking that up!"),
            ("Hemen not alıyorum.\nBaşka bir şey?", "Hemen not alıyorum."),
        ])
    func keeps(reply: String, expected: String) {
        #expect(LiveAcknowledgement.clean(reply) == expected)
    }

    @Test(
        "rejects questions, long answers and nothing",
        arguments: [
            "What would you like me to check?", "", "   ",
            "It will be sunny tomorrow with a high of twenty degrees and light wind.", "🙂",
        ])
    func rejects(reply: String) {
        #expect(LiveAcknowledgement.clean(reply) == nil)
    }

    @Test("asks the fast brain with its own instructions and no tools")
    func asks() async {
        let provider = FakeProvider(
            info: ProviderInfo(id: "apple", name: "Apple", kind: .local),
            reply: [.text("Takvimine "), .text("bakıyorum.")])
        let text = await LiveAcknowledgement.make(for: "Yarın ne var?", with: provider)
        #expect(text == "Takvimine bakıyorum.")
        let request = provider.seen.value.first
        #expect(request?.systemPrompt == LiveAcknowledgement.instructions)
        #expect(request?.tools.isEmpty == true)
        #expect(request?.turns.last?.text == "Yarın ne var?")
    }

    @Test("gives up on a slow brain")
    func slow() async {
        struct SlowProvider: ChatProvider {
            let info = ProviderInfo(id: "slow", name: "Slow", kind: .local)
            func availability() async -> ProviderAvailability { .ready }
            func respond(
                to request: ChatRequest, runTool: @escaping ToolRunner
            )
                -> AsyncThrowingStream<ChatEvent, any Error>
            {
                AsyncThrowingStream { continuation in
                    let task = Task {
                        try? await Task.sleep(for: .seconds(5))
                        continuation.yield(.text("Too late."))
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        }
        let start = Date()
        let text = await LiveAcknowledgement.make(
            for: "Hi", with: SlowProvider(), timeout: .milliseconds(100))
        #expect(text == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
