import Foundation

/// What the brain reports while answering a live turn.
public enum LiveBrainEvent: Sendable, Equatable {
    /// More reply text, possibly Markdown.
    case text(String)
    /// A tool started; `label` describes it for the user ("Checking the weather").
    case toolStarted(label: String)
    /// A tool finished.
    case toolFinished
    /// The brain needs a yes or no (consent to use a remote brain, confirming an action).
    /// `question` is said aloud; the bubble shows buttons too.
    case prompt(question: String)
    /// The question was answered, by voice or with a button.
    case promptResolved
    /// The reply is complete.
    case finished
    /// The reply failed; `message` explains why.
    case failed(String)
}

/// Momo's brain as the live layer sees it: it answers turns with streamed events.
@MainActor
public protocol LiveBrain: AnyObject {
    /// Starts answering `turn`. Events arrive through `handler` until ``LiveBrainEvent/finished``
    /// or ``LiveBrainEvent/failed(_:)``. Returns `false` when the brain can't take it now.
    func send(_ turn: String, handler: @escaping (LiveBrainEvent) -> Void) -> Bool
    /// Stops the reply in progress; no more events arrive for it.
    func cancel()
    /// Answers the open question.
    func answerPrompt(_ answer: SpokenAnswer)
    /// A short spoken acknowledgement for `turn` in the user's language ("Takvimine
    /// bakıyorum."), written by a fast local brain, or `nil` when none is ready. It must not
    /// answer the turn, only say what Momo is about to do.
    func acknowledgement(for turn: String, completion: @escaping (String?) -> Void)
}

/// Phrases the live layer says on its own, in the user's language.
public struct LiveConversationPhrases: Sendable, Equatable {
    /// Short acknowledgements when the brain is slow ("One moment.", "Let me check.").
    public var acknowledgements: [String]
    /// Asked once when a yes-or-no answer was unclear.
    public var unclearAnswer: String
    /// Said when the user closes the conversation.
    public var farewells: [String]
    /// Said when the reply failed.
    public var failure: String

    public init(
        acknowledgements: [String], unclearAnswer: String, farewells: [String], failure: String
    ) {
        self.acknowledgements = acknowledgements
        self.unclearAnswer = unclearAnswer
        self.farewells = farewells
        self.failure = failure
    }
}

/// The live layer in front of Momo's brain: listens and talks naturally while the brain does
/// the real work.
///
/// Each finished turn goes to the brain at once, and the streaming reply is spoken sentence
/// by sentence (``SpeechSentenceSplitter``). While the brain is slow, ``LiveReplyPlanner``
/// fills the silence with a short acknowledgement or the running tool's label, never over the
/// answer. The user can talk over Momo at any time: the reply stops and what they say is the
/// next turn. After Momo finishes, it keeps listening for a follow-up for
/// ``Settings/followUpWindow`` seconds; the conversation ends when that passes in silence,
/// when the user says a closing phrase ("thanks, that's all", "teşekkürler") or when
/// ``end()`` is called. Consent and confirmation questions are asked aloud and answered with
/// a spoken yes or no; an unclear answer is asked once more, then the buttons stay.
@MainActor
public final class LiveConversation {
    /// Where the conversation is.
    public enum State: Sendable, Equatable {
        case idle
        case starting
        /// Listening for the user's turn.
        case listening
        /// The brain works on a reply (Momo may be saying an acknowledgement).
        case thinking
        /// Momo is saying the reply.
        case speaking
        /// Momo asked a yes-or-no question and listens for the answer.
        case awaitingAnswer
        /// The question stays open for the buttons; turns are not listened to meanwhile.
        case awaitingButtons
        /// Momo finished and listens for a follow-up.
        case followUp
        /// Momo says goodbye.
        case closing
    }

    /// How the conversation behaves.
    public struct Settings: Sendable, Equatable {
        /// How the speech layer listens and speaks.
        public var speech: LiveSpeechConfiguration
        /// How long Momo listens for a follow-up after it finished, and for the first turn.
        public var followUpWindow: TimeInterval
        /// Timing of acknowledgements.
        public var planner: LiveReplyPlanner.Configuration

        public init(
            speech: LiveSpeechConfiguration, followUpWindow: TimeInterval = 8,
            planner: LiveReplyPlanner.Configuration = .init()
        ) {
            self.speech = speech
            self.followUpWindow = followUpWindow
            self.planner = planner
        }
    }

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    /// Whether Momo's voice is playing (a reply, an acknowledgement or a question).
    public private(set) var isSpeaking = false {
        didSet { if isSpeaking != oldValue { onSpeakingChange?(isSpeaking) } }
    }
    /// While set (push to talk held), the follow-up window never runs out.
    public var holdsWindowOpen = false {
        didSet { if !holdsWindowOpen { restartWindow() } }
    }

    public var onStateChange: ((State) -> Void)?
    public var onSpeakingChange: ((Bool) -> Void)?
    /// The words of the user's current turn so far.
    public var onPartial: ((String) -> Void)?
    /// A turn that was sent to the brain.
    public var onTurn: ((String) -> Void)?
    /// The microphone level, 0...1.
    public var onLevel: ((Double) -> Void)?
    /// The output level, 0...1, for the mouth.
    public var onMouth: ((Double) -> Void)?
    /// A problem worth showing; the conversation may go on.
    public var onError: ((String) -> Void)?
    /// The conversation ended and the microphone is closed.
    public var onEnded: (() -> Void)?

    private let io: any LiveSpeechIO
    private let brain: any LiveBrain
    private let phrases: LiveConversationPhrases
    private let clock: any LiveClock
    private let settings: Settings

    private var planner: LiveReplyPlanner
    private var splitter = SpeechSentenceSplitter()
    private var replyNumber = 0
    private var segmentNumber = 0
    private var utteranceNumber = 0
    /// The utterance the answer's sentences go to.
    private var replyID = ""
    /// Set when the brain finished: the utterance whose end ends the reply.
    private var finalReplyID: String?
    private var isBrainRunning = false
    private var acknowledgementID: String?
    private var promptID: String?
    private var farewellID: String?
    private var hasRepeatedQuestion = false
    /// A turn whose reply was cancelled before a word of it was said, because the user kept
    /// talking; it is sent again together with what they add.
    private var unansweredTurn: String?
    private var currentTurn = ""
    private var window: LiveTimer?
    private var ticker: LiveTimer?
    private var closingTimer: LiveTimer?
    private var hasEnded = false

    public init(
        io: any LiveSpeechIO, brain: any LiveBrain, phrases: LiveConversationPhrases,
        settings: Settings, clock: any LiveClock = SystemLiveClock(), firstPhrase: Int = 0
    ) {
        self.io = io
        self.brain = brain
        self.phrases = phrases
        self.settings = settings
        self.clock = clock
        planner = LiveReplyPlanner(
            configuration: settings.planner, cannedPhrases: phrases.acknowledgements,
            firstPhrase: firstPhrase)
    }

    /// Opens the microphone and starts listening; `firstTurn` (from "Hey Momo, …") is sent
    /// right away.
    public func start(firstTurn: String? = nil) async throws {
        guard state == .idle, !hasEnded else { return }
        state = .starting
        io.onEvent = { [weak self] event in self?.handle(event) }
        do {
            try await io.start(settings.speech)
        } catch {
            state = .idle
            hasEnded = true
            throw error
        }
        guard state == .starting else { return }
        state = .listening
        if let firstTurn, !firstTurn.trimmingCharacters(in: .whitespaces).isEmpty {
            heard(firstTurn)
        } else {
            restartWindow()
        }
    }

    /// Ends the conversation now: stops speaking, cancels an unfinished reply and closes the
    /// microphone.
    public func end() {
        guard !hasEnded else { return }
        hasEnded = true
        window?.cancel()
        ticker?.cancel()
        closingTimer?.cancel()
        if isBrainRunning {
            isBrainRunning = false
            brain.cancel()
        }
        io.stop()
        isSpeaking = false
        state = .idle
        onEnded?()
    }

    /// Ends the user's turn now (push to talk let go).
    public func endTurn() {
        guard !hasEnded else { return }
        io.endTurn()
    }

    /// Stops Momo at once so the user can talk (push to talk pressed while Momo talks).
    public func interrupt() {
        guard !hasEnded else { return }
        switch state {
        case .thinking, .speaking:
            stopReply()
            state = .listening
        case .closing:
            end()
        default:
            if isSpeaking { io.cancelSpeech() }
            promptID = nil
        }
        isSpeaking = false
        restartWindow()
    }

    // MARK: - Speech events

    private func handle(_ event: LiveSpeechEvent) {
        guard !hasEnded else { return }
        switch event {
        case .listening:
            break
        case .level(let level):
            onLevel?(level)
        case .speechStarted:
            restartWindow()
            if state == .followUp { state = .listening }
        case .partial(let text):
            restartWindow()
            onPartial?(text)
            if state == .followUp { state = .listening }
            userKeptTalking(text)
        case .turn(let text):
            heard(text)
        case .speakingStarted:
            isSpeaking = true
            window?.cancel()
        case .mouth(let level):
            onMouth?(level)
        case .speakingFinished(let id):
            finishedSpeaking(id)
        case .interrupted(let id):
            interrupted(id)
        case .error(let message, let isFatal):
            onError?(message)
            if isFatal { end() }
        case .stopped:
            end()
        }
    }

    /// The user talks while the brain is still working and Momo hasn't said a word of the
    /// answer: they weren't done, so the turn is cancelled and sent again with what they add.
    private func userKeptTalking(_ text: String) {
        guard state == .thinking, !planner.hasAnswer,
            text.filter(\.isLetter).count >= 2
        else { return }
        unansweredTurn = currentTurn
        stopReply()
        state = .listening
    }

    private func finishedSpeaking(_ id: String) {
        if id == acknowledgementID {
            acknowledgementID = nil
            planner.acknowledgementFinished()
        }
        isSpeaking = false
        if id == farewellID {
            end()
        } else if id == promptID {
            promptID = nil
            if state == .thinking || state == .speaking || state == .awaitingAnswer {
                state = .awaitingAnswer
            }
            restartWindowForAnswer()
        } else if id == finalReplyID {
            replyDone()
        } else if !isBrainRunning, finalReplyID == nil, acknowledgementID == nil,
            state == .thinking
        {
            // An acknowledgement ended a reply that had nothing to say.
            replyDone()
        }
    }

    private func interrupted(_ id: String) {
        isSpeaking = false
        if id == acknowledgementID {
            // The brain goes on: talking over "one moment" is no reason to drop the request.
            // If the user says words, ``userKeptTalking(_:)`` sends the turn again with them.
            acknowledgementID = nil
            planner.acknowledgementFinished()
            return
        }
        if id == promptID {
            // The user answers over the question; that's fine.
            promptID = nil
            state = .awaitingAnswer
            return
        }
        if id == farewellID {
            end()
            return
        }
        stopReply()
        state = .listening
        restartWindow()
    }

    // MARK: - Turns

    private func heard(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch state {
        case .awaitingAnswer:
            guard !text.isEmpty else { return }
            answered(text)
            return
        case .awaitingButtons, .closing, .idle, .starting:
            return
        default:
            break
        }
        guard !text.isEmpty else {
            if !isBrainRunning, state == .listening { state = .followUp }
            restartWindow()
            return
        }
        if SpeechText.isClosingPhrase(text) {
            close()
            return
        }
        if isBrainRunning || state == .speaking { stopReply() }
        var turn = text
        if let unanswered = unansweredTurn {
            turn = unanswered + " " + text
            unansweredTurn = nil
        }
        send(turn)
    }

    private func send(_ turn: String) {
        replyNumber += 1
        let number = replyNumber
        segmentNumber = 0
        replyID = nextReplySegment()
        finalReplyID = nil
        currentTurn = turn
        splitter.reset()
        planner.begin(at: clock.now)
        hasRepeatedQuestion = false
        window?.cancel()
        let accepted = brain.send(turn) { [weak self] event in
            guard let self, self.replyNumber == number, !self.hasEnded else { return }
            self.handle(event)
        }
        guard accepted else {
            onError?(phrases.failure)
            state = .followUp
            restartWindow()
            return
        }
        isBrainRunning = true
        state = .thinking
        onTurn?(turn)
        brain.acknowledgement(for: turn) { [weak self] text in
            guard let self, self.replyNumber == number, !self.hasEnded else { return }
            self.planner.contextualAcknowledgementArrived(text)
            self.apply(self.planner.tick(at: self.clock.now))
        }
        scheduleTick(for: number)
    }

    private func nextReplySegment() -> String {
        segmentNumber += 1
        return "reply-\(replyNumber)-\(segmentNumber)"
    }

    private func scheduleTick(for number: Int) {
        ticker?.cancel()
        ticker = clock.schedule(after: 0.1) { [weak self] in
            guard let self, self.replyNumber == number, !self.hasEnded, self.isBrainRunning,
                !self.planner.hasAnswer
            else { return }
            self.apply(self.planner.tick(at: self.clock.now))
            self.scheduleTick(for: number)
        }
    }

    /// Cancels the reply in progress and whatever Momo is saying.
    private func stopReply() {
        ticker?.cancel()
        if isBrainRunning {
            isBrainRunning = false
            brain.cancel()
        }
        replyNumber += 1
        planner.finish()
        splitter.reset()
        acknowledgementID = nil
        promptID = nil
        finalReplyID = nil
        io.cancelSpeech()
        if state == .awaitingButtons { io.resumeListening() }
        isSpeaking = false
    }

    private func close() {
        stopReply()
        state = .closing
        window?.cancel()
        guard !phrases.farewells.isEmpty else {
            end()
            return
        }
        let farewell = phrases.farewells[replyNumber % phrases.farewells.count]
        utteranceNumber += 1
        let id = "bye-\(utteranceNumber)"
        farewellID = id
        io.speak(id: id, text: farewell, isFinal: true)
        // Never hang on a farewell that doesn't play.
        closingTimer = clock.schedule(after: 4) { [weak self] in self?.end() }
    }

    // MARK: - Brain events

    private func handle(_ event: LiveBrainEvent) {
        switch event {
        case .text(let chunk):
            for sentence in splitter.append(chunk) { apply(planner.answer(sentence)) }
        case .toolStarted(let label):
            for sentence in splitter.flush() { apply(planner.answer(sentence)) }
            apply(planner.toolStarted(label: label))
        case .toolFinished:
            break
        case .prompt(let question):
            ask(question)
        case .promptResolved:
            promptResolved()
        case .finished:
            for sentence in splitter.flush() { apply(planner.answer(sentence)) }
            finishReply()
        case .failed(let message):
            onError?(message)
            splitter.reset()
            apply(planner.answer(phrases.failure))
            finishReply()
        }
    }

    private func apply(_ actions: [LiveReplyPlanner.Action]) {
        for action in actions {
            switch action {
            case .speakAcknowledgement(let text):
                utteranceNumber += 1
                let id = "ack-\(utteranceNumber)"
                acknowledgementID = id
                io.speak(id: id, text: text, isFinal: true)
            case .cancelAcknowledgement:
                acknowledgementID = nil
                io.cancelSpeech()
            case .speakAnswer(let sentence):
                io.speak(id: replyID, text: sentence, isFinal: false)
                if state == .thinking { state = .speaking }
            }
        }
    }

    private func finishReply() {
        isBrainRunning = false
        ticker?.cancel()
        planner.finish()
        if planner.hasAnswer {
            finalReplyID = replyID
            io.speak(id: replyID, text: "", isFinal: true)
            if state == .thinking { state = .speaking }
        } else if acknowledgementID == nil {
            replyDone()
        }
        // Otherwise the acknowledgement that is playing ends the reply.
    }

    private func replyDone() {
        finalReplyID = nil
        isSpeaking = false
        guard state != .closing, state != .awaitingButtons else { return }
        state = .followUp
        restartWindow()
    }

    // MARK: - Questions

    private func ask(_ question: String) {
        // Finish what was said so far, so the question plays right after it.
        for sentence in splitter.flush() { apply(planner.answer(sentence)) }
        if planner.hasAnswer {
            io.speak(id: replyID, text: "", isFinal: true)
            replyID = nextReplySegment()
        }
        ticker?.cancel()
        planner.finish()
        if acknowledgementID != nil {
            acknowledgementID = nil
            io.cancelSpeech()
        }
        hasRepeatedQuestion = false
        state = .awaitingAnswer
        sayQuestion(question)
    }

    private func sayQuestion(_ text: String) {
        utteranceNumber += 1
        let id = "prompt-\(utteranceNumber)"
        promptID = id
        io.speak(id: id, text: text, isFinal: true)
    }

    private func answered(_ text: String) {
        if let answer = SpeechText.answer(in: text) {
            brain.answerPrompt(answer)
            promptResolved()
            return
        }
        if !hasRepeatedQuestion {
            hasRepeatedQuestion = true
            sayQuestion(phrases.unclearAnswer)
        } else {
            // Still unclear: leave the buttons and stop listening until one is pressed.
            state = .awaitingButtons
            window?.cancel()
            io.pauseListening()
        }
    }

    private func promptResolved() {
        if state == .awaitingButtons { io.resumeListening() }
        if promptID != nil {
            promptID = nil
            io.cancelSpeech()
        }
        guard state == .awaitingAnswer || state == .awaitingButtons else { return }
        window?.cancel()
        state = .thinking
        planner.begin(at: clock.now)
        planner.contextualAcknowledgementArrived(nil)
        scheduleTick(for: replyNumber)
    }

    // MARK: - Listening window

    /// Starts the follow-up window again: the conversation ends after it passes without
    /// the user speaking.
    private func restartWindow() {
        window?.cancel()
        if state == .awaitingAnswer, promptID == nil {
            restartWindowForAnswer()
            return
        }
        guard !hasEnded, [.listening, .followUp].contains(state), !holdsWindowOpen else {
            return
        }
        window = clock.schedule(after: settings.followUpWindow) { [weak self] in
            guard let self, !self.holdsWindowOpen,
                [.listening, .followUp].contains(self.state)
            else { return }
            self.end()
        }
    }

    /// Waits a while for a spoken answer; the question stays open for the buttons.
    private func restartWindowForAnswer() {
        window?.cancel()
        window = clock.schedule(after: settings.followUpWindow) { [weak self] in
            guard let self, self.state == .awaitingAnswer else { return }
            self.state = .awaitingButtons
            self.io.pauseListening()
        }
    }
}
