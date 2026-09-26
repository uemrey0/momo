import Foundation
import Testing

@testable import MomoVoice

/// A clock the test moves forward by hand.
@MainActor
final class TestClock: LiveClock {
    private(set) var now: TimeInterval = 100
    private var actions: [(id: Int, time: TimeInterval, action: @MainActor () -> Void)] = []
    private var nextID = 0

    func schedule(
        after delay: TimeInterval, _ action: @escaping @MainActor () -> Void
    )
        -> LiveTimer
    {
        nextID += 1
        let id = nextID
        actions.append((id, now + delay, action))
        return LiveTimer { [weak self] in self?.actions.removeAll { $0.id == id } }
    }

    /// Moves time forward, running every action that falls due, in order.
    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let next = actions.filter({ $0.time <= end }).min(by: { $0.time < $1.time }) {
            actions.removeAll { $0.id == next.id }
            now = max(now, next.time)
            next.action()
        }
        now = end
    }
}

/// Records what the conversation asks the speech layer to do.
@MainActor
final class FakeSpeechIO: LiveSpeechIO {
    enum Command: Equatable {
        case start
        case stop
        case speak(id: String, text: String, isFinal: Bool)
        case cancelSpeech
        case pauseListening
        case resumeListening
        case endTurn
    }

    var onEvent: ((LiveSpeechEvent) -> Void)?
    private(set) var isRunning = false
    private(set) var commands: [Command] = []

    func start(_ configuration: LiveSpeechConfiguration) async throws {
        isRunning = true
        commands.append(.start)
        onEvent?(.listening)
    }

    func stop() {
        isRunning = false
        commands.append(.stop)
    }

    func speak(id: String, text: String, isFinal: Bool) {
        commands.append(.speak(id: id, text: text, isFinal: isFinal))
    }

    func cancelSpeech() { commands.append(.cancelSpeech) }
    func pauseListening() { commands.append(.pauseListening) }
    func resumeListening() { commands.append(.resumeListening) }
    func endTurn() { commands.append(.endTurn) }

    /// What was spoken, as (id, text) pairs, leaving out empty final chunks.
    var spoken: [String] {
        commands.compactMap {
            if case .speak(_, let text, _) = $0, !text.isEmpty { text } else { nil }
        }
    }

    /// The id of the last utterance spoken to.
    var lastSpokenID: String? {
        commands.reversed().lazy.compactMap {
            if case .speak(let id, _, _) = $0 { id } else { nil }
        }.first
    }

    func send(_ event: LiveSpeechEvent) { onEvent?(event) }
}

/// A brain the test answers for.
@MainActor
final class FakeBrain: LiveBrain {
    private(set) var turns: [String] = []
    private(set) var cancels = 0
    private(set) var answers: [SpokenAnswer] = []
    var acknowledgement: String?
    var answersAcknowledgement = true
    private var handler: ((LiveBrainEvent) -> Void)?

    func send(_ turn: String, handler: @escaping (LiveBrainEvent) -> Void) -> Bool {
        turns.append(turn)
        self.handler = handler
        return true
    }

    func cancel() {
        cancels += 1
        handler = nil
    }

    func answerPrompt(_ answer: SpokenAnswer) {
        answers.append(answer)
    }

    func acknowledgement(for turn: String, completion: @escaping (String?) -> Void) {
        if answersAcknowledgement { completion(acknowledgement) }
    }

    func emit(_ event: LiveBrainEvent) { handler?(event) }
}

@MainActor
@Suite("Live conversation")
struct LiveConversationTests {
    let io = FakeSpeechIO()
    let brain = FakeBrain()
    let clock = TestClock()
    let phrases = LiveConversationPhrases(
        acknowledgements: ["One moment.", "Let me check."], unclearAnswer: "Yes or no?",
        farewells: ["Bye!"], failure: "Sorry, that didn't work.")

    func makeConversation(window: TimeInterval = 8) -> LiveConversation {
        LiveConversation(
            io: io, brain: brain, phrases: phrases,
            settings: .init(
                speech: LiveSpeechConfiguration(locale: Locale(identifier: "en_US")),
                followUpWindow: window),
            clock: clock)
    }

    @Test("sends each turn at once and speaks the reply sentence by sentence")
    func streaming() async throws {
        let conversation = makeConversation()
        var states: [LiveConversation.State] = []
        conversation.onStateChange = { states.append($0) }
        try await conversation.start()
        io.send(.partial("what's the"))
        io.send(.turn("What's the weather?"))
        #expect(brain.turns == ["What's the weather?"])
        #expect(conversation.state == .thinking)

        brain.emit(.text("It's **sunny** and 20 degrees."))
        #expect(io.spoken.isEmpty)
        brain.emit(.text(" Want a"))
        #expect(io.spoken == ["It's sunny and 20 degrees."])
        #expect(conversation.state == .speaking)
        brain.emit(.text(" reminder?"))
        brain.emit(.finished)
        #expect(io.spoken == ["It's sunny and 20 degrees.", "Want a reminder?"])
        let replyID = try #require(io.lastSpokenID)
        #expect(io.commands.last == .speak(id: replyID, text: "", isFinal: true))

        io.send(.speakingStarted(id: replyID))
        #expect(conversation.isSpeaking)
        io.send(.speakingFinished(id: replyID))
        #expect(conversation.state == .followUp)
        #expect(!conversation.isSpeaking)
        #expect(states == [.starting, .listening, .thinking, .speaking, .followUp])
    }

    @Test("says a contextual acknowledgement when the brain is slow, and stops it for the answer")
    func contextualAcknowledgement() async throws {
        brain.acknowledgement = "Checking your calendar."
        let conversation = makeConversation()
        try await conversation.start()
        io.send(.turn("What's on tomorrow?"))
        clock.advance(by: 0.5)
        #expect(io.spoken.isEmpty)
        clock.advance(by: 0.4)
        #expect(io.spoken == ["Checking your calendar."])
        let ackID = try #require(io.lastSpokenID)
        io.send(.speakingStarted(id: ackID))

        brain.emit(.text("You have two meetings. "))
        brain.emit(.text("The first"))
        #expect(io.commands.suffix(2).first == .cancelSpeech)
        #expect(io.spoken.last == "You have two meetings.")
        // Only one acknowledgement per reply.
        clock.advance(by: 5)
        #expect(io.spoken.count == 2)
    }

    @Test("falls back to a canned phrase when no contextual one arrives in time")
    func cannedAcknowledgement() async throws {
        brain.answersAcknowledgement = false
        let conversation = makeConversation()
        try await conversation.start()
        io.send(.turn("Summarise my notes"))
        clock.advance(by: 0.9)
        #expect(io.spoken.isEmpty)
        clock.advance(by: 0.4)
        #expect(io.spoken == ["One moment."])
    }

    @Test("never acknowledges a reply that starts quickly")
    func fastReply() async throws {
        let conversation = makeConversation()
        try await conversation.start()
        io.send(.turn("Hi"))
        brain.emit(.text("Hi there! "))
        brain.emit(.text("How can I help?"))
        clock.advance(by: 2)
        #expect(io.spoken == ["Hi there!"])
    }

    @Test("says what a tool does when nothing else is being said")
    func toolLabel() async throws {
        brain.answersAcknowledgement = false
        let conversation = makeConversation()
        try await conversation.start()
        io.send(.turn("Weather in Paris?"))
        brain.emit(.toolStarted(label: "Checking the weather"))
        #expect(io.spoken == ["Checking the weather"])
        clock.advance(by: 2)
        #expect(io.spoken == ["Checking the weather"])
        brain.emit(.toolFinished)
        brain.emit(.text("It's raining in Paris."))
        brain.emit(.finished)
        #expect(io.spoken == ["Checking the weather", "It's raining in Paris."])
    }

    @Test("a reply that says something before its tool keeps quiet about the tool")
    func textBeforeTool() async throws {
        let conversation = makeConversation()
        try await conversation.start()
        io.send(.turn("Add milk"))
        brain.emit(.text("Sure, adding it"))
        brain.emit(.toolStarted(label: "Adding a task"))
        #expect(io.spoken == ["Sure, adding it"])
    }

    @Test("talking over Momo stops the reply and the next turn is a new message")
    func bargeIn() async throws {
        let conversation = makeConversation()
        try await conversation.start()
        io.send(.turn("Tell me a story"))
        brain.emit(.text("Once upon a time there was a fox. "))
        brain.emit(.text("It lived"))
        let replyID = try #require(io.lastSpokenID)
        io.send(.speakingStarted(id: replyID))
        io.send(.speechStarted)
        io.send(.interrupted(id: replyID))
        #expect(brain.cancels == 1)
        #expect(conversation.state == .listening)
        // Late events from the cancelled reply are ignored.
        brain.emit(.text(" in a forest. "))
        #expect(io.spoken == ["Once upon a time there was a fox."])
        io.send(.turn("Actually, what time is it?"))
        #expect(brain.turns == ["Tell me a story", "Actually, what time is it?"])
    }

    @Test("when the user keeps talking before the answer, the turn is sent again with the rest")
    func keptTalking() async throws {
        let conversation = makeConversation()
        try await conversation.start()
        io.send(.turn("What's the weather"))
        io.send(.partial("in Paris"))
        #expect(brain.cancels == 1)
        io.send(.turn("in Paris"))
        #expect(brain.turns == ["What's the weather", "What's the weather in Paris"])
    }

    @Test("talking over an acknowledgement keeps the request running")
    func overAcknowledgement() async throws {
        brain.answersAcknowledgement = false
        let conversation = makeConversation()
        try await conversation.start()
        io.send(.turn("Plan my day"))
        clock.advance(by: 1.3)
        let ackID = try #require(io.lastSpokenID)
        io.send(.speakingStarted(id: ackID))
        io.send(.interrupted(id: ackID))
        #expect(brain.cancels == 0)
        brain.emit(.text("First, the gym. "))
        brain.emit(.finished)
        #expect(io.spoken.last == "First, the gym.")
    }

    @Test("listens for a follow-up, then ends in silence")
    func followUpWindow() async throws {
        let conversation = makeConversation(window: 8)
        var ended = false
        conversation.onEnded = { ended = true }
        try await conversation.start()
        io.send(.turn("Hi"))
        brain.emit(.text("Hello!"))
        brain.emit(.finished)
        let replyID = try #require(io.lastSpokenID)
        io.send(.speakingStarted(id: replyID))
        clock.advance(by: 20)
        #expect(!ended)
        io.send(.speakingFinished(id: replyID))
        clock.advance(by: 5)
        io.send(.speechStarted)
        clock.advance(by: 7)
        #expect(!ended)
        clock.advance(by: 1.5)
        #expect(ended)
        #expect(io.commands.last == .stop)
    }

    @Test("push to talk keeps the window open while the key is held")
    func holdToTalk() async throws {
        let conversation = makeConversation(window: 8)
        var ended = false
        conversation.onEnded = { ended = true }
        try await conversation.start()
        conversation.holdsWindowOpen = true
        clock.advance(by: 30)
        #expect(!ended)
        conversation.endTurn()
        #expect(io.commands.last == .endTurn)
        conversation.holdsWindowOpen = false
        clock.advance(by: 8.1)
        #expect(ended)
    }

    @Test("a closing phrase says goodbye and ends")
    func closing() async throws {
        let conversation = makeConversation()
        var ended = false
        conversation.onEnded = { ended = true }
        try await conversation.start()
        io.send(.turn("Teşekkürler, bu kadar."))
        #expect(brain.turns.isEmpty)
        #expect(io.spoken == ["Bye!"])
        #expect(conversation.state == .closing)
        let id = try #require(io.lastSpokenID)
        io.send(.speakingStarted(id: id))
        io.send(.speakingFinished(id: id))
        #expect(ended)
    }

    @Test("asks questions aloud and hears yes or no, asking once more when unclear")
    func questions() async throws {
        let conversation = makeConversation()
        try await conversation.start()
        io.send(.turn("Delete my notes"))
        brain.emit(.text("Okay."))
        brain.emit(.prompt(question: "Delete 3 notes? Should I go ahead?"))
        #expect(io.spoken == ["Okay.", "Delete 3 notes? Should I go ahead?"])
        #expect(conversation.state == .awaitingAnswer)
        let questionID = try #require(io.lastSpokenID)
        io.send(.speakingFinished(id: questionID))

        io.send(.turn("hmm"))
        #expect(io.spoken.last == "Yes or no?")
        #expect(brain.answers.isEmpty)
        io.send(.turn("evet"))
        #expect(brain.answers == [.yes])
        #expect(conversation.state == .thinking)
        brain.emit(.text("Done, they're gone."))
        brain.emit(.finished)
        #expect(io.spoken.last == "Done, they're gone.")
        #expect(brain.turns == ["Delete my notes"])
    }

    @Test("an answer that stays unclear leaves the buttons and stops listening")
    func buttons() async throws {
        let conversation = makeConversation()
        try await conversation.start()
        io.send(.turn("Ask Claude"))
        brain.emit(.prompt(question: "Can I ask Claude?"))
        io.send(.turn("what"))
        io.send(.turn("maybe"))
        #expect(conversation.state == .awaitingButtons)
        #expect(io.commands.last == .pauseListening)
        io.send(.turn("yes"))
        #expect(brain.answers.isEmpty)
        brain.emit(.promptResolved)
        #expect(io.commands.contains(.resumeListening))
        #expect(conversation.state == .thinking)
    }

    @Test("a failed reply is said and the conversation goes on")
    func failure() async throws {
        let conversation = makeConversation()
        var errors: [String] = []
        conversation.onError = { errors.append($0) }
        try await conversation.start()
        io.send(.turn("Hi"))
        brain.emit(.failed("No brain is ready."))
        #expect(errors == ["No brain is ready."])
        #expect(io.spoken == ["Sorry, that didn't work."])
        let id = try #require(io.lastSpokenID)
        io.send(.speakingFinished(id: id))
        #expect(conversation.state == .followUp)
    }

    @Test("ending cancels the reply and closes the microphone")
    func end() async throws {
        let conversation = makeConversation()
        try await conversation.start(firstTurn: "What time is it")
        #expect(brain.turns == ["What time is it"])
        conversation.end()
        #expect(brain.cancels == 1)
        #expect(io.commands.last == .stop)
        #expect(conversation.state == .idle)
    }
}

@Suite("Reply planning")
struct ReplyPlannerTests {
    @Test("rotates canned phrases so replies don't all start alike")
    func rotation() {
        var planner = LiveReplyPlanner(cannedPhrases: ["A.", "B."], firstPhrase: 1)
        planner.begin(at: 0)
        #expect(planner.tick(at: 1.3) == [.speakAcknowledgement("B.")])
        planner.begin(at: 10)
        #expect(planner.tick(at: 11.3) == [.speakAcknowledgement("A.")])
    }

    @Test("waits for the contextual acknowledgement within the grace period")
    func grace() {
        var planner = LiveReplyPlanner(cannedPhrases: ["A."])
        planner.begin(at: 0)
        #expect(planner.tick(at: 0.9).isEmpty)
        planner.contextualAcknowledgementArrived("Looking it up.")
        #expect(planner.tick(at: 1.0) == [.speakAcknowledgement("Looking it up.")])
        #expect(planner.isAcknowledging)
        #expect(planner.answer("Found it.") == [.cancelAcknowledgement, .speakAnswer("Found it.")])
        #expect(planner.answer("Next.") == [.speakAnswer("Next.")])
    }

    @Test("says at most two different tool labels")
    func toolLabels() {
        var planner = LiveReplyPlanner(cannedPhrases: [])
        planner.begin(at: 0)
        #expect(
            planner.toolStarted(label: "Searching the web") == [
                .speakAcknowledgement("Searching the web")
            ])
        #expect(planner.toolStarted(label: "Reading a page").isEmpty)
        planner.acknowledgementFinished()
        #expect(planner.toolStarted(label: "Searching the web").isEmpty)
        #expect(
            planner.toolStarted(label: "Reading a page") == [
                .speakAcknowledgement("Reading a page")
            ])
        planner.acknowledgementFinished()
        #expect(planner.toolStarted(label: "Checking the time").isEmpty)
    }
}
