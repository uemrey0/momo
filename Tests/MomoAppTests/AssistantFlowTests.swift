import Foundation
import MomoBrain
import MomoKit
import Testing

@testable import MomoApp

@MainActor
@Suite("Assistant run, stop and retry")
struct AssistantFlowTests {
    private func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, text: text) }
    private func answer(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: text)
    }
    private func failure(_ text: String) -> ChatMessage { ChatMessage(role: .error, text: text) }

    // MARK: - Retry

    @Test("asking again drops the failed answer and keeps everything before it")
    func retryAfterError() throws {
        let messages = [
            user("Hi"), answer("Hello!"), user("Plan my day"), failure("Rate limit (429)"),
        ]
        let plan = try #require(RetryPlan(messages: messages))
        #expect(plan.request.text == "Plan my day")
        #expect(plan.messages.map(\.text) == ["Hi", "Hello!", "Plan my day"])
        #expect(plan.messages.last?.id == messages[2].id)
    }

    @Test("asking again replaces an answer that was given, too")
    func retryReplacesAnswer() throws {
        let plan = try #require(
            RetryPlan(messages: [user("Write a haiku"), answer("Old haiku")]))
        #expect(plan.request.text == "Write a haiku")
        #expect(plan.messages.count == 1)
        #expect(plan.history.isEmpty)
    }

    @Test("the brain's history is the chat before the request, without errors")
    func retryHistory() throws {
        var earlier = answer("Done, I added it.")
        earlier.toolRecords = [ToolRecord(name: "add_task", arguments: "{}", result: "ok")]
        let messages = [
            user("Add milk"), failure("Offline"), user("Add milk"), earlier,
            user("And eggs?"), answer("Added eggs."),
        ]
        let plan = try #require(RetryPlan(messages: messages))
        #expect(plan.request.text == "And eggs?")
        #expect(
            plan.history == [
                ChatTurn(role: .user, text: "Add milk"),
                ChatTurn(role: .user, text: "Add milk"),
                ChatTurn(
                    role: .assistant, text: "Done, I added it.", toolRecords: earlier.toolRecords),
            ])
        // Neither the replaced answer nor the request itself is history yet.
        #expect(!plan.history.contains { $0.text == "Added eggs." || $0.text == "And eggs?" })
    }

    @Test("the request keeps its attachments when asked again")
    func retryKeepsAttachments() throws {
        let image = ChatAttachment(
            name: "photo.png", content: .image(data: Data([1, 2, 3]), mimeType: "image/png"))
        let request = ChatMessage(role: .user, text: "What's this?", attachments: [image])
        let plan = try #require(RetryPlan(messages: [request, failure("Oops")]))
        #expect(plan.request.attachments == [image])
    }

    @Test("there is nothing to ask again without a user message")
    func retryWithoutRequest() {
        #expect(RetryPlan(messages: []) == nil)
        #expect(RetryPlan(messages: [answer("Good morning!")]) == nil)
    }

    @Test("a message can be asked again only once it was answered or failed")
    func retryPossibility() {
        #expect(RetryPlan.isPossible(in: [user("Hi"), answer("Hello")]))
        #expect(RetryPlan.isPossible(in: [user("Hi"), failure("Offline")]))
        #expect(!RetryPlan.isPossible(in: [user("Hi")]))
        #expect(!RetryPlan.isPossible(in: []))
        // A greeting Momo started with is no request.
        #expect(!RetryPlan.isPossible(in: [answer("Good morning!")]))
    }

    @Test("the controller offers to retry only when idle and there is an answer")
    func controllerCanRetry() {
        let assistant = makeController()
        #expect(!assistant.canRetry)
        assistant.messages = [user("Hi")]
        #expect(!assistant.canRetry)
        assistant.messages.append(failure("Offline"))
        #expect(assistant.canRetry)
    }

    @Test("a new conversation clears the chat and its retry")
    func newConversation() {
        let assistant = makeController()
        assistant.messages = [user("Hi"), answer("Hello")]
        assistant.newConversation()
        #expect(assistant.messages.isEmpty)
        #expect(!assistant.canRetry)
        #expect(!assistant.isBusy)
        #expect(assistant.conversationID == nil)
    }

    // MARK: - Stop

    @Test("stopping ends the answer and fails the steps still running")
    func stopMarksRunningSteps() {
        var message = ChatMessage(role: .assistant, text: "", isStreaming: true)
        message.appendStep(ToolActivity(toolName: "list_tasks", state: .succeeded))
        message.appendStep(ToolActivity(toolName: "read_screen", state: .running))
        let stoppedAt = Date(timeIntervalSince1970: 100)
        message.markStopped(at: stoppedAt)
        #expect(!message.isStreaming)
        #expect(message.finishedAt == stoppedAt)
        #expect(message.activities.map(\.state) == [.succeeded, .failed])
    }

    @Test("stopping leaves a finished answer alone")
    func stopKeepsFinishedAnswer() {
        var message = ChatMessage(role: .assistant, text: "Done")
        message.appendStep(ToolActivity(toolName: "add_task", state: .running))
        message.markStopped(at: Date())
        #expect(message.finishedAt == nil)
        #expect(message.activities.first?.state == .running)
    }

    @Test("stopping when nothing runs keeps the chat as it is")
    func stopWhileIdle() {
        let assistant = makeController()
        assistant.messages = [user("Hi"), answer("Hello")]
        assistant.stop()
        #expect(assistant.messages.map(\.text) == ["Hi", "Hello"])
        #expect(!assistant.isBusy)
    }

    // MARK: - Steps

    @Test("a finished tool marks its latest running step")
    func finishLatestRunningStep() {
        var message = ChatMessage(role: .assistant, text: "", isStreaming: true)
        message.appendStep(ToolActivity(toolName: "search_notes", state: .running))
        message.appendStep(ToolActivity(toolName: "search_notes", state: .running))
        let finishedAt = Date(timeIntervalSince1970: 50)
        message.finishStep(
            named: "search_notes", succeeded: true, missingPermission: nil, at: finishedAt)
        #expect(message.activities.map(\.state) == [.running, .succeeded])
        #expect(message.activities[1].finishedAt == finishedAt)
        message.finishStep(
            named: "search_notes", succeeded: false, missingPermission: .calendars,
            at: finishedAt)
        #expect(message.activities.map(\.state) == [.failed, .succeeded])
        #expect(message.activities[0].missingPermission == .calendars)
    }

    @Test("a tool that finishes without a running step changes nothing")
    func finishUnknownStep() {
        var message = ChatMessage(role: .assistant, text: "")
        message.appendStep(ToolActivity(toolName: "add_task", state: .succeeded))
        let before = message
        message.finishStep(named: "add_task", succeeded: false, missingPermission: nil, at: Date())
        message.finishStep(named: "open_app", succeeded: true, missingPermission: nil, at: Date())
        #expect(message == before)
    }

    // MARK: - Errors

    @Test("a failed request shows its error with the issue that explains it")
    func failureMessage() {
        let message = ChatMessage.failure(URLError(.notConnectedToInternet))
        #expect(message.role == .error)
        #expect(message.text == URLError(.notConnectedToInternet).localizedDescription)
        #expect(message.issue?.kind == .network)
        #expect(message.turn == nil)
    }

    @Test("provider errors map to the issue that fixes them")
    func providerErrorIssues() {
        #expect(ChatMessage.failure(ProviderError("Invalid API key (401)")).issue?.kind == .signIn)
        #expect(
            ChatMessage.failure(ProviderError("Too many requests")).issue?.kind == .rateLimit)
        #expect(
            ChatMessage.failure(ProviderError("ollama was not found")).issue?.kind == .setup)
        #expect(
            ChatMessage.failure(ProviderError("The request timed out.")).issue?.kind == .network)
    }

    // MARK: - History

    @Test("a reopened conversation tells the brain which attachments are gone")
    func savedAttachmentsInHistory() {
        var message = user("Summarise this")
        message.savedAttachments = [.init(name: "report.pdf", isImage: false)]
        #expect(
            message.turn?.text
                == "Summarise this\n\n(Attached earlier, no longer available: report.pdf)")
    }

    @Test("saving a message counts steps still running as failed")
    func storedRunningStep() {
        var message = answer("Partial")
        message.appendStep(ToolActivity(toolName: "read_screen", state: .running))
        message.appendStep(ToolActivity(toolName: "add_task", state: .succeeded))
        let restored = ChatMessage(stored: message.stored)
        #expect(restored.role == .assistant)
        #expect(restored.text == "Partial")
        #expect(restored.activities.map(\.state) == [.failed, .succeeded])
    }

    // MARK: - Background jobs

    @Test("a background job asks for consent once and remembers the answer")
    func consentMemory() async {
        let asks = Counter()
        let memory = ConsentMemory { _, _, _ in
            await asks.increment()
            return .allowForConversation
        }
        let brain = ProviderInfo(id: "openai", name: "ChatGPT", kind: .apiKey)
        let first = await memory.answer(brain: brain, reason: .tooLongForLocal, masked: true)
        let second = await memory.answer(brain: brain, reason: .tooLongForLocal, masked: true)
        #expect(first == .allowForConversation)
        // The rest of the job is one request, so it is allowed once rather than for good.
        #expect(second == .allowOnce)
        #expect(await asks.value == 1)
    }

    @Test("a declined background job stays declined")
    func consentMemoryDeclined() async {
        let memory = ConsentMemory { _, _, _ in .cancel }
        let brain = ProviderInfo(id: "openai", name: "ChatGPT", kind: .apiKey)
        _ = await memory.answer(brain: brain, reason: .noLocalBrain, masked: false)
        #expect(await memory.answer(brain: brain, reason: .noLocalBrain, masked: false) == .cancel)
    }

    @Test("background requests fit the smallest ready on-device brain")
    func backgroundBudget() {
        func status(
            _ id: String, _ kind: BrainKind, _ length: Int, ready: Bool = true
        )
            -> ProviderStatus
        {
            ProviderStatus(
                info: ProviderInfo(id: id, name: id, kind: kind, comfortableLength: length),
                availability: ready ? .ready : .unavailable("off"))
        }
        // 60% of the smallest ready local brain; a remote brain doesn't count.
        #expect(
            AssistantController.backgroundRequestBudget(for: [
                status("apple", .local, 10_000), status("ollama", .local, 30_000),
                status("openai", .apiKey, 5_000),
            ]) == 6_000)
        // Unavailable brains are ignored.
        #expect(
            AssistantController.backgroundRequestBudget(for: [
                status("apple", .local, 5_000, ready: false), status("ollama", .local, 20_000),
            ]) == 12_000)
        // Without a local brain, the smallest ready brain; without any, a default.
        #expect(
            AssistantController.backgroundRequestBudget(for: [status("openai", .apiKey, 30_000)])
                == 18_000)
        #expect(AssistantController.backgroundRequestBudget(for: []) == 14_400)
        // Kept between 4,000 and 40,000 characters.
        #expect(
            AssistantController.backgroundRequestBudget(for: [status("tiny", .local, 1_000)])
                == 4_000)
        #expect(
            AssistantController.backgroundRequestBudget(for: [status("big", .local, 1_000_000)])
                == 40_000)
    }

    // MARK: - Prompts

    @Test("a confirmation warns when outside text may be steering Momo")
    func confirmationText() {
        let plain = ToolConfirmationRequest(toolName: "run_command", summary: "Run ls")
        #expect(AssistantController.confirmationText(for: plain) == "Run ls")
        let steered = ToolConfirmationRequest(
            toolName: "run_command", summary: "Run ls", reason: .untrustedContent)
        let text = AssistantController.confirmationText(for: steered)
        #expect(text.hasPrefix("Run ls\n\n"))
        #expect(text.count > "Run ls\n\n".count)
    }

    @Test("consent explains each reason for going remote differently")
    func consentExplanations() {
        let brain = ProviderInfo(id: "openai", name: "ChatGPT", kind: .apiKey)
        let reasons: [RoutingReason] = [
            .difficultRequest(difficulty: 3), .tooLongForLocal, .noLocalBrain, .userChoice,
            .imageAttached, .onlyOption,
        ]
        let explanations = reasons.map {
            ConsentPrompt(brain: brain, reason: $0, masksData: true).explanation
        }
        #expect(Set(explanations).count == reasons.count)
        #expect(explanations.allSatisfy { !$0.isEmpty })
    }

    // MARK: - Helpers

    private func makeController() -> AssistantController {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaults = UserDefaults(suiteName: "momo-tests-\(UUID().uuidString)") ?? .standard
        return AssistantController(
            store: MomoStore(fileURL: folder.appendingPathComponent("data.json")),
            settings: AppSettings(defaults: defaults))
    }
}

/// Counts calls across actors.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
