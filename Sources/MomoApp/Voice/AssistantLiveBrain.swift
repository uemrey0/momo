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
        if let error = assistant?.lastRequestError {
            handler(.failed(error))
        } else {
            handler(.finished)
        }
    }

    private func replyEvent(_ event: ReplyStreamEvent) {
        switch event {
        case .text(let text): handler?(.text(text))
        case .toolStarted(let label): handler?(.toolStarted(label: label))
        case .toolFinished: handler?(.toolFinished)
        }
    }
}
