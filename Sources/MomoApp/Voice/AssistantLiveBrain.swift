import Foundation
import MomoVoice

/// Momo's assistant as the brain of a live conversation: turns become chat messages with a
/// spoken reply style, and the streaming reply, its tools and its questions are passed on.
///
/// ``VoiceController`` forwards the assistant's prompt and request callbacks here while a
/// live conversation runs.
@MainActor
final class AssistantLiveBrain: LiveBrain {
    private weak var assistant: AssistantController?
    private var handler: ((LiveBrainEvent) -> Void)?

    init(assistant: AssistantController) {
        self.assistant = assistant
    }

    /// Whether a live turn is being answered.
    var isAnswering: Bool { handler != nil }

    func send(_ turn: String, handler: @escaping (LiveBrainEvent) -> Void) -> Bool {
        guard let assistant, !assistant.isBusy else { return false }
        self.handler = handler
        assistant.onReplyEvent = { [weak self] event in self?.replyEvent(event) }
        assistant.send(turn, spoken: true)
        guard assistant.isBusy else {
            self.handler = nil
            return false
        }
        return true
    }

    func cancel() {
        handler = nil
        assistant?.onReplyEvent = nil
        if let assistant, assistant.isBusy { assistant.stop() }
    }

    func answerPrompt(_ answer: SpokenAnswer) {
        guard let assistant else { return }
        if assistant.consentPrompt != nil {
            assistant.answerConsent(answer == .yes ? .allowOnce : .useLocal)
        } else if assistant.confirmationPrompt != nil {
            assistant.answerConfirmation(answer == .yes)
        }
    }

    func acknowledgement(for turn: String, completion: @escaping (String?) -> Void) {
        guard let assistant else {
            completion(nil)
            return
        }
        Task { completion(await assistant.quickAcknowledgement(for: turn)) }
    }

    // MARK: - Forwarded from the assistant

    /// A consent or confirmation question appeared.
    func promptAppeared() {
        guard let assistant, let handler else { return }
        if let prompt = assistant.consentPrompt {
            handler(
                .prompt(
                    question: String(format: L("Can I ask %@? Say yes or no."), prompt.brain.name)))
        } else if let prompt = assistant.confirmationPrompt {
            handler(.prompt(question: prompt.summary + " " + L("Should I go ahead?")))
        }
    }

    /// The question was answered, by voice or with a button.
    func promptAnswered() {
        handler?(.promptResolved)
    }

    /// The request ended.
    func requestFinished() {
        guard let handler else { return }
        self.handler = nil
        assistant?.onReplyEvent = nil
        if let issue = assistant?.lastRequestIssue {
            handler(.failed(Self.spoken(issue, brain: assistant?.lastBrainName)))
        } else if let error = assistant?.lastRequestError {
            handler(
                .failed(Self.spoken(ChatIssue(message: error), brain: assistant?.lastBrainName)))
        } else {
            handler(.finished)
        }
    }

    /// What went wrong, in words Momo can say: what happened and what to do about it, never
    /// the raw error (which stays in the chat).
    static func spoken(_ issue: ChatIssue, brain: String?) -> String {
        let name = brain.map(spokenName)
        switch issue.kind {
        case .rateLimit:
            return name.map {
                String(
                    format: L(
                        "%@ has reached its usage limit. Try again later, or pick another brain in AI settings."
                    ),
                    $0)
            } ?? issue.title + ". " + issue.message
        case .signIn:
            return name.map {
                String(
                    format: L("%@ needs you to sign in again. Open AI settings to reconnect it."),
                    $0)
            } ?? issue.title + ". " + issue.message
        case .network, .noBrain, .setup, .permission:
            return issue.title + ". " + issue.message
        case .other:
            return name.map {
                String(format: L("%@ ran into a problem. The details are in the chat."), $0)
            } ?? L("Something went wrong. The details are in the chat.")
        }
    }

    /// A brain's name as said aloud: "ChatGPT (Codex)" becomes "ChatGPT".
    static func spokenName(_ name: String) -> String {
        let base = name.split(separator: "(").first.map(String.init) ?? name
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    private func replyEvent(_ event: ReplyStreamEvent) {
        switch event {
        case .brainSelected(let name, let isRemote):
            // A brain off the Mac takes a few seconds; say which one works on it.
            if isRemote {
                handler?(.status(String(format: L("Checking with %@."), Self.spokenName(name))))
            }
        case .text(let text): handler?(.text(text))
        case .toolStarted(let label): handler?(.toolStarted(label: label))
        case .toolFinished: handler?(.toolFinished)
        }
    }
}
