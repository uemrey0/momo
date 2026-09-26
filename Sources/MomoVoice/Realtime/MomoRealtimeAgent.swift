import Foundation

/// How a cloud realtime model works as Momo's live layer.
///
/// The realtime model hears and speaks, handles turn-taking and small talk, and hands
/// everything real to Momo's assistant (the brain) through one function, ``askMomo``. The
/// brain runs with its tools, routing, consent and masking as for any other request, and the
/// realtime model voices its answer.
///
/// ## The ask_momo contract
///
/// The model calls `ask_momo` with `request`: the user's request restated completely in their
/// language, including anything from the conversation it depends on (the brain does not hear
/// the conversation). The app answers with an ``AskMomoResult``, sent as a JSON object:
///
/// - `{"status": "done", "answer": "..."}`: the brain's answer as plain speech text.
/// - `{"status": "needs_confirmation", "confirmation_id": "confirm-1", "question": "..."}`:
///   the brain needs a yes or no before it acts (a tool that needs confirmation, or consent
///   to use a cloud brain).
/// - `{"status": "failed", "error": "..."}`: the request could not be done.
///
/// ## Conversational confirmation
///
/// The brain's confirmation question is answered by voice, inside the conversation:
///
/// 1. The model calls `ask_momo(request: "Delete the note Shopping")`.
/// 2. The brain reaches a tool that needs confirmation and suspends. The pending call returns
///    `needs_confirmation` with a `confirmation_id` and the question.
/// 3. The model asks the user the question in its own words and waits.
/// 4. The user answers. The model calls `ask_momo` again with the same `request`, the
///    `confirmation_id` and `confirmed` (true for yes, false for no or anything unclear it
///    could not resolve by asking once more).
/// 5. The suspended brain resumes with that answer, and this second call returns its final
///    result (or another confirmation).
///
/// ``AskMomoCoordinator`` implements the app's side: it runs the brain, parks its
/// confirmation questions and matches the answers by id. A new request while a question is
/// waiting counts as "no" for that question.
public enum MomoRealtimeAgent {
    /// The name of the delegate function.
    public static let functionName = "ask_momo"

    /// The one function the realtime model gets: hand a request to Momo's assistant.
    public static let askMomo = RealtimeFunction(
        name: functionName,
        description: """
            Hands a request to Momo's assistant, which can see and change the user's tasks, \
            reminders, notes, habits, calendar, memories and files, act on the Mac, and look \
            things up on the web. Call it for anything actionable, anything about the user or \
            their data, and anything that needs current information. Returns a JSON object \
            with a status: done (with the answer to relay), needs_confirmation (ask the user \
            the question, then call again with confirmation_id and confirmed) or failed.
            """,
        parameters: [
            RealtimeParameter(
                name: "request",
                description: """
                    The user's request restated completely in the user's language, so it \
                    stands alone: include names, dates, times and what words like "it" or \
                    "tomorrow" refer to. Momo's assistant does not hear the conversation.
                    """),
            RealtimeParameter(
                name: "confirmation_id",
                description: """
                    Only when answering a needs_confirmation result: its confirmation_id.
                    """, isRequired: false),
            RealtimeParameter(
                name: "confirmed", kind: .boolean,
                description: """
                    Only with confirmation_id: true if the user said yes, false if they said \
                    no or did not agree.
                    """, isRequired: false),
        ])

    /// What the instructions say about the conversation.
    public struct Context: Sendable, Equatable {
        /// The character's name.
        public var assistantName: String
        /// The user's name, when Momo knows it.
        public var userName: String?
        /// The conversation language as a BCP 47 code, when known.
        public var language: String?
        /// More instructions: the user's chosen personality, or anything the app adds.
        public var additionalInstructions: String?

        public init(
            assistantName: String = "Momo", userName: String? = nil, language: String? = nil,
            additionalInstructions: String? = nil
        ) {
            self.assistantName = assistantName
            self.userName = userName
            self.language = language
            self.additionalInstructions = additionalInstructions
        }
    }

    /// The system instructions for the realtime model.
    public static func instructions(_ context: Context = Context()) -> String {
        let name = context.assistantName
        let user = context.userName.map { "the user, \($0)," } ?? "the user"
        let language =
            context.language.flatMap { Locale(identifier: "en").localizedString(forIdentifier: $0) }
            .map { "Speak \($0) unless the user speaks another language; then switch with them." }
            ?? "Speak the user's language, and switch when they do."
        var text = """
            You are \(name), a small, warm and playful assistant character who lives in the \
            notch of the user's Mac. You are talking with \(user) live, by voice.

            # How you talk
            - Keep replies short and natural, like a spoken conversation: usually one to \
            three sentences.
            - No lists, headings, links, emoji or Markdown. Say numbers, dates and times the \
            way people say them.
            - \(language)
            - Answer greetings, small talk, jokes and simple general knowledge yourself.
            - If the user talks over you, stop and listen.

            # What you hand to Momo
            You cannot see the user's tasks, reminders, notes, habits, calendar, memories, \
            files, apps, screen or messages, you cannot look anything up, and you cannot do \
            anything on the Mac. Momo's assistant can, through the ask_momo function. ALWAYS \
            call ask_momo for:
            - anything to do: add, change or complete tasks, reminders, notes, habits or \
            events; open apps; run shortcuts; send or change anything;
            - anything about the user or their data: plans, schedule, notes, preferences, \
            people, or what they told \(name) before;
            - anything that needs current information: news, weather, prices, opening hours, \
            facts that may have changed, anything to look up;
            - anything about files, the screen or what is on the Mac;
            - anything you are not sure you can answer correctly.
            When in doubt, call ask_momo.

            # How to call ask_momo
            - Put the whole request in `request`, in the user's language, restated so it \
            stands alone: names, dates, times, and what "it", "that" or "tomorrow" refer to. \
            Momo's assistant does not hear the conversation.
            - First say a very short, natural filler in the user's language, such as "One \
            moment" or "Let me check", then call. Don't repeat the request back.
            - Make one call at a time and wait for its result. Put several requests into one \
            call.

            # Using the result
            - status "done": tell the user the answer briefly, in your own words. Keep names, \
            numbers and times exact; don't read out formatting, identifiers or raw data.
            - status "needs_confirmation": Momo needs a yes or no before it acts. Ask the user \
            the question in your own words and wait. When they answer, call ask_momo again \
            with the same request, the confirmation_id from the result, and confirmed true \
            for yes or false for no. If the answer is unclear, ask once more; if they change \
            the subject, call with confirmed false. Never decide for the user.
            - status "failed": say briefly that it didn't work, and why if the result says.
            - Never invent results, never say something was done unless the result says so, \
            and never make up anything about the user.
            """
        if let extra = context.additionalInstructions?
            .trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty
        {
            text += "\n\n# More about you\n\(extra)"
        }
        return text
    }
}

/// An `ask_momo` call, read from the model's arguments.
public struct AskMomoCall: Sendable, Equatable {
    /// The request restated for the brain.
    public var request: String
    /// The id of the confirmation this call answers, if any.
    public var confirmationID: String?
    /// The user's answer to that confirmation.
    public var confirmed: Bool?

    public init(request: String, confirmationID: String? = nil, confirmed: Bool? = nil) {
        self.request = request
        self.confirmationID = confirmationID
        self.confirmed = confirmed
    }

    /// Reads a function call; `nil` when it is another function or has neither a request nor
    /// a confirmation answer.
    public init?(_ call: RealtimeFunctionCall) {
        guard call.name == MomoRealtimeAgent.functionName,
            let arguments = RealtimeJSON.object(call.arguments)
        else { return nil }
        let request = (arguments["request"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmationID = (arguments["confirmation_id"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let confirmed =
            arguments["confirmed"] as? Bool
            ?? (arguments["confirmed"] as? String).map {
                ["true", "yes"].contains($0.lowercased())
            }
        guard !request.isEmpty || confirmationID != nil else { return nil }
        self.init(request: request, confirmationID: confirmationID, confirmed: confirmed)
    }

    /// Whether the call answers a confirmation question.
    public var isConfirmationAnswer: Bool { confirmationID != nil }
}

/// The result of an `ask_momo` call, sent back to the realtime model.
public enum AskMomoResult: Sendable, Equatable {
    /// The brain's answer. Markdown is turned into plain speech text.
    case answer(String)
    /// The brain needs a yes or no before it continues.
    case needsConfirmation(id: String, question: String)
    /// The request could not be done; the message says why.
    case failed(String)

    /// The result as the JSON object string the function returns.
    public var output: String {
        let object: [String: Any] =
            switch self {
            case .answer(let text):
                ["status": "done", "answer": SpeechText.plain(fromMarkdown: text)]
            case .needsConfirmation(let id, let question):
                [
                    "status": "needs_confirmation", "confirmation_id": id,
                    "question": SpeechText.plain(fromMarkdown: question),
                ]
            case .failed(let message):
                ["status": "failed", "error": message]
            }
        return (try? RealtimeJSON.string(object)) ?? #"{"status":"failed"}"#
    }
}

/// Runs `ask_momo` requests through the brain and carries its confirmation questions through
/// the voice conversation.
///
/// ```swift
/// let coordinator = AskMomoCoordinator { request, confirm in
///     try await assistant.answer(request, confirm: confirm)  // the brain, with its tools
/// }
/// // On .functionCall(call):
/// if let ask = AskMomoCall(call) {
///     let result = await coordinator.handle(ask)
///     await session.sendFunctionResult(result.output, for: call)
/// }
/// ```
///
/// When the brain calls `confirm(question)`, the pending ``handle(_:)`` returns
/// ``AskMomoResult/needsConfirmation(id:question:)`` and the brain waits. The model asks the
/// user and calls `ask_momo` again with the confirmation id; that ``handle(_:)`` resumes the
/// brain with the answer and returns what it does next. One request runs at a time: a new
/// request answers a waiting question with "no" and replaces the old one. Call ``cancel()``
/// when the session ends or the model cancels its call.
public actor AskMomoCoordinator {
    /// Asks the user a yes-or-no question and returns the answer.
    public typealias Confirm = @Sendable (_ question: String) async -> Bool
    /// Runs one request through the brain and returns its answer.
    public typealias Run =
        @Sendable (_ request: String, _ confirm: @escaping Confirm)
        async throws -> String

    private let run: Run
    private var generation = 0
    private var task: Task<Void, Never>?
    private var waiter: CheckedContinuation<AskMomoResult, Never>?
    private var outcomes: [AskMomoResult] = []
    private var pending: (id: String, continuation: CheckedContinuation<Bool, Never>)?
    private var confirmationCount = 0

    public init(run: @escaping Run) {
        self.run = run
    }

    /// The id of the question waiting for the user's answer, if any.
    public var pendingConfirmationID: String? { pending?.id }

    /// Handles one `ask_momo` call and returns what to send back.
    public func handle(_ call: AskMomoCall) async -> AskMomoResult {
        if let id = call.confirmationID {
            guard let question = pending, question.id == id else {
                return .failed(
                    "No question is waiting for that answer. Call ask_momo again with the "
                        + "full request.")
            }
            pending = nil
            question.continuation.resume(returning: call.confirmed ?? false)
            return await nextOutcome()
        }
        start(call.request)
        return await nextOutcome()
    }

    /// Stops the current request: a waiting question counts as "no", and a waiting call gets
    /// a failed result.
    public func cancel() {
        supersede(with: .failed("The request was cancelled."))
    }

    private func start(_ request: String) {
        supersede(with: .failed("A newer request replaced this one."))
        let generation = generation
        let run = run
        // The task holds the coordinator until the brain finishes or is cancelled.
        task = Task {
            let confirm: Confirm = { question in
                await self.confirm(question, generation: generation)
            }
            let result: AskMomoResult
            do {
                result = .answer(try await run(request, confirm))
            } catch is CancellationError {
                return
            } catch {
                result = .failed(error.localizedDescription)
            }
            self.deliver(result, generation: generation)
        }
    }

    private func supersede(with result: AskMomoResult) {
        generation += 1
        task?.cancel()
        task = nil
        outcomes = []
        if let question = pending {
            pending = nil
            question.continuation.resume(returning: false)
        }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: result)
        }
    }

    private func confirm(_ question: String, generation: Int) async -> Bool {
        guard generation == self.generation, pending == nil else { return false }
        confirmationCount += 1
        let id = "confirm-\(confirmationCount)"
        return await withCheckedContinuation { continuation in
            pending = (id, continuation)
            deliver(.needsConfirmation(id: id, question: question), generation: generation)
        }
    }

    private func deliver(_ result: AskMomoResult, generation: Int) {
        guard generation == self.generation else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: result)
        } else {
            outcomes.append(result)
        }
    }

    private func nextOutcome() async -> AskMomoResult {
        if !outcomes.isEmpty { return outcomes.removeFirst() }
        return await withCheckedContinuation { continuation in
            // Only one call waits at a time; an older one (a parallel call) gets an answer
            // instead of hanging.
            waiter?.resume(returning: .failed("Only one request can run at a time."))
            waiter = continuation
        }
    }
}
