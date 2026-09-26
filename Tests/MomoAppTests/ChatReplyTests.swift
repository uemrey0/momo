import Foundation
import MomoBrain
import MomoKit
import Testing

@testable import MomoApp

@MainActor
@Suite("Chat replies")
struct ChatReplyTests {
    @Test("keeps what Momo says between steps apart from its answer")
    func separatesAnswer() {
        var message = ChatMessage(role: .assistant, text: "", isStreaming: true)
        message.appendText("I'll check your tasks.")
        message.appendStep(ToolActivity(toolName: "list_tasks", state: .succeeded))
        message.appendText("You have ")
        message.appendText("two tasks.")
        #expect(message.text == "I'll check your tasks.You have two tasks.")
        #expect(message.parts.count == 3)
        #expect(message.answer == "You have two tasks.")
    }

    @Test("uses the whole text when there were no steps")
    func plainAnswer() {
        var message = ChatMessage(role: .assistant, text: "")
        message.appendText("Hello!")
        #expect(message.answer == "Hello!")
        #expect(!message.hasWork)
    }

    @Test("falls back to the last thing said when a brain finishes silently")
    func silentFinish() {
        var message = ChatMessage(role: .assistant, text: "", isStreaming: true)
        message.appendText("I'll draw a cat.")
        message.appendStep(ToolActivity(toolName: "generate_image", state: .succeeded))
        #expect(message.answer.isEmpty)
        message.isStreaming = false
        #expect(message.answer == "I'll draw a cat.")
    }

    @Test("explains errors with the actions that fix them")
    func classifiesIssues() {
        #expect(ChatIssue(message: "Rate limit or quota reached (429).").kind == .rateLimit)
        #expect(ChatIssue(error: URLError(.notConnectedToInternet)).kind == .network)
        let signIn = ChatIssue(message: "Codex needs you to sign in again in Settings → AI.")
        #expect(signIn.kind == .signIn)
        #expect(signIn.actions.first == .openAISettings)
        #expect(
            ChatIssue(message: "No on-device brain is available right now.").kind == .noBrain)
        let other = ChatIssue(message: "Something odd")
        #expect(other.kind == .other)
        #expect(other.actions == [.retry])
        #expect(other.details == "Something odd")
    }

    @Test("offers to allow a missing permission, then to try again")
    func permissionIssue() {
        let issue = ChatIssue.missing(.calendars)
        #expect(issue.kind == .permission(.calendars))
        #expect(issue.actions == [.allow(.calendars), .retry])
    }

    @Test("describes a step's work by its duration")
    func stepDuration() {
        var message = ChatMessage(role: .assistant, text: "")
        message.date = Date(timeIntervalSince1970: 0)
        message.finishedAt = Date(timeIntervalSince1970: 12)
        #expect(message.duration == 12)
    }
}
