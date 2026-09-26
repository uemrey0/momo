import Foundation
import MomoVoice

/// Momo's assistant behind a cloud realtime model: each `ask_momo` request becomes a spoken
/// chat message, so it lands in the chat history with its reply, and the assistant's consent
/// and confirmation questions are handed to the model to ask aloud.
///
/// ``VoiceController`` forwards the assistant's prompt and request callbacks here while a
/// realtime conversation runs.
@MainActor
final class AssistantRealtimeBrain: RealtimeBrain {
    /// A request that didn't produce an answer.
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private weak var assistant: AssistantController?
    /// The running tool's activity label ("Checking your calendar"), or `nil` between tools.
    var onActivity: ((String?) -> Void)?

    private var continuation: CheckedContinuation<String, any Error>?
    private var confirm: AskMomoCoordinator.Confirm?
    private var reply = ""
    private var askedPrompt: UUID?

    init(assistant: AssistantController) {
        self.assistant = assistant
    }

    func run(
        _ request: String, confirm: @escaping AskMomoCoordinator.Confirm
    ) async throws -> String {
        try Task.checkCancellation()
        guard let assistant else { throw CancellationError() }
        guard !assistant.isBusy else {
            throw Failure(message: "Momo is still busy with another request.")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.confirm = confirm
                reply = ""
                assistant.onReplyEvent = { [weak self] event in self?.replyEvent(event) }
                assistant.send(request, spoken: true)
                guard assistant.isBusy else {
                    finish(.failure(Failure(message: "Momo couldn't take the request.")))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// Stops the request in progress.
    func cancel() {
        guard continuation != nil else { return }
        if let assistant, assistant.isBusy { assistant.stop() }
        finish(.failure(CancellationError()))
    }

    // MARK: - Forwarded from the assistant

    /// A consent or confirmation question appeared: the model asks it and brings the answer.
    func promptAppeared() {
        guard let assistant, let confirm, continuation != nil else { return }
        let question: String
        let id: UUID
        if let prompt = assistant.consentPrompt {
            question = String(
                format: L("Can I ask %@? It isn't on this Mac."), prompt.brain.name)
            id = prompt.id
        } else if let prompt = assistant.confirmationPrompt {
            question = prompt.summary
            id = prompt.id
        } else {
            return
        }
        guard askedPrompt != id else { return }
        askedPrompt = id
        Task { [weak self] in
            let approved = await confirm(question)
            self?.answer(approved, to: id)
        }
    }

    /// The request ended.
    func requestFinished() {
        guard continuation != nil else { return }
        if let error = assistant?.lastRequestError {
            finish(.failure(Failure(message: error)))
        } else if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finish(.failure(Failure(message: "The request stopped without an answer.")))
        } else {
            finish(.success(reply))
        }
    }

    private func answer(_ approved: Bool, to id: UUID) {
        guard let assistant else { return }
        // A button may have answered already.
        if assistant.consentPrompt?.id == id {
            assistant.answerConsent(approved ? .allowOnce : .useLocal)
        } else if assistant.confirmationPrompt?.id == id {
            assistant.answerConfirmation(approved)
        }
    }

    private func replyEvent(_ event: ReplyStreamEvent) {
        switch event {
        case .text(let text): reply += text
        case .toolStarted(let label): onActivity?(label)
        case .toolFinished: onActivity?(nil)
        }
    }

    private func finish(_ result: Result<String, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        confirm = nil
        askedPrompt = nil
        assistant?.onReplyEvent = nil
        onActivity?(nil)
        continuation.resume(with: result)
    }
}
