import Foundation

/// Momo's assistant as a cloud realtime model reaches it through `ask_momo`.
@MainActor
public protocol RealtimeBrain: AnyObject, Sendable {
    /// Runs `request` through the assistant, with its tools, routing and consent, and returns
    /// the answer. Yes-or-no questions go through `confirm`, which the realtime model asks
    /// aloud. Cancelling the task stops the request.
    func run(
        _ request: String, confirm: @escaping AskMomoCoordinator.Confirm
    ) async throws
        -> String
}

/// Decides whether a realtime session that closed on its own is opened again.
public enum RealtimeReconnectPolicy {
    /// How many times one conversation reconnects.
    public static let maximumReconnects = 1

    /// Whether to reconnect after the service closed the session with `error`.
    /// - Parameters:
    ///   - isMidConversation: The user is talking, Momo is speaking or working on a request,
    ///     or a question waits for an answer. Otherwise the conversation just ends.
    ///   - reconnects: How often this conversation reconnected already.
    public static func shouldReconnect(
        after error: CloudVoiceError?, isMidConversation: Bool, reconnects: Int
    ) -> Bool {
        guard isMidConversation, reconnects < maximumReconnects else { return false }
        // A rejected key, a missing model or an exhausted quota fails the same way again.
        if let status = error?.status, [400, 401, 403, 404, 429].contains(status) {
            return false
        }
        return true
    }
}

/// A live conversation with a cloud realtime model (OpenAI Realtime, Gemini Live) as the live
/// layer, and Momo's assistant as the brain behind it.
///
/// The model hears the user, decides when a turn ends, answers small talk itself and speaks
/// natively. Everything real goes to the brain through `ask_momo` (``AskMomoCoordinator``),
/// whose confirmation questions come back through the model as `needs_confirmation`.
///
/// The conversation hosts the audio (``RealtimeAudioIO``): the echo-cancelled microphone goes
/// to the session, the model's speech plays from a jitter buffer, and when the user talks
/// over Momo playback stops at once and the session learns how much was heard. After Momo
/// finishes, it listens for a follow-up for ``Settings/followUpWindow`` seconds; the
/// conversation ends when that passes in silence, after a closing phrase ("thanks, that's
/// all", once the model said goodbye) or on ``end()``. A session the service closes in the
/// middle of an exchange is reopened once (``RealtimeReconnectPolicy``); the new session
/// doesn't remember what was said.
@MainActor
public final class RealtimeConversation: LiveConversing {
    /// How the conversation behaves.
    public struct Settings: Sendable, Equatable {
        /// The service, model and key.
        public var service: RealtimeVoiceService
        /// Instructions, voice, language and the `ask_momo` tool.
        public var session: RealtimeSessionConfiguration
        /// How long Momo listens for a follow-up after it finished, and for the first turn.
        public var followUpWindow: TimeInterval
        /// Push to talk: the microphone only reaches the model while
        /// ``RealtimeConversation/holdsWindowOpen`` is set; silence is sent otherwise, so the
        /// service still notices the end of the turn.
        public var pushToTalk: Bool
        /// How long a goodbye may take after a closing phrase.
        public var closingGrace: TimeInterval

        public init(
            service: RealtimeVoiceService, session: RealtimeSessionConfiguration,
            followUpWindow: TimeInterval = 8, pushToTalk: Bool = false,
            closingGrace: TimeInterval = 6
        ) {
            self.service = service
            self.session = session
            self.followUpWindow = followUpWindow
            self.pushToTalk = pushToTalk
            self.closingGrace = closingGrace
        }
    }

    /// Makes a session for a service; tests pass one with a fake transport.
    public typealias SessionFactory = @MainActor (RealtimeVoiceService) -> RealtimeVoiceSession

    public private(set) var state: LiveConversation.State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
            updateWindow(restart: true)
        }
    }
    /// Whether the model's speech is playing.
    public private(set) var isSpeaking = false {
        didSet { if isSpeaking != oldValue { onSpeakingChange?(isSpeaking) } }
    }
    /// Whether an `ask_momo` request is running.
    public private(set) var isWorking = false {
        didSet { if isWorking != oldValue { onWorkingChange?(isWorking) } }
    }
    public var holdsWindowOpen = false {
        didSet {
            route.sendsSilence = settings.pushToTalk && !holdsWindowOpen
            updateWindow(restart: true)
        }
    }

    public var onStateChange: ((LiveConversation.State) -> Void)?
    public var onSpeakingChange: ((Bool) -> Void)?
    /// What the user said so far in this turn, as the service transcribes it.
    public var onPartial: ((String) -> Void)?
    /// What the model said so far in its current response.
    public var onAssistantTranscript: ((String) -> Void)?
    /// An `ask_momo` request started (`true`) or all of them ended (`false`).
    public var onWorkingChange: ((Bool) -> Void)?
    public var onLevel: ((Double) -> Void)?
    public var onMouth: ((Double) -> Void)?
    public var onError: ((String) -> Void)?
    /// The session failed for good (not a normal end); the app may prefer another engine next
    /// time. ``onEnded`` follows.
    public var onFailure: ((String) -> Void)?
    /// What a session exchanged, once it closed: its display name and usage, for the privacy
    /// log. Called once per session, also for one replaced by a reconnect.
    public var onUsage: ((String, RealtimeUsage) -> Void)?
    public var onEnded: (() -> Void)?

    private let settings: Settings
    private let audio: any RealtimeAudioIO
    private let coordinator: AskMomoCoordinator
    private let makeSession: SessionFactory
    private let clock: any LiveClock
    private let route: RealtimeAudioRoute
    private let frames: AsyncStream<Data>
    private let frameContinuation: AsyncStream<Data>.Continuation

    private var session: RealtimeVoiceSession?
    private var sessionNumber = 0
    private var eventsTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var reconnects = 0
    private var isReconnecting = false
    private var hasEnded = false
    private var hasHeardUser = false
    private var isUserSpeaking = false
    /// The model is producing a response (audio or transcript arrived, not done yet).
    private var responseOpen = false
    /// After a barge-in, what is left of the cancelled response is dropped until it ends.
    private var dropsResponse = false
    private var pendingCalls: Set<String> = []
    /// The last result asked the user a question; the model waits for the answer.
    private var awaitingConfirmation = false
    private var sessionEndingSoon = false
    private var closingResponseSeen = false
    private var assistantText = ""
    private var window: LiveTimer?
    private var poller: LiveTimer?
    private var closingTimer: LiveTimer?

    public init(
        settings: Settings, audio: any RealtimeAudioIO, brain: any RealtimeBrain,
        clock: any LiveClock = SystemLiveClock(),
        makeSession: @escaping SessionFactory = { RealtimeVoiceSession(service: $0) }
    ) {
        self.settings = settings
        self.audio = audio
        self.clock = clock
        self.makeSession = makeSession
        coordinator = AskMomoCoordinator { request, confirm in
            try await brain.run(request, confirm: confirm)
        }
        route = RealtimeAudioRoute(sendsSilence: settings.pushToTalk)
        (frames, frameContinuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .bufferingNewest(50))
    }

    // MARK: - Session

    /// Opens the microphone, connects and starts listening; `firstTurn` (from "Hey Momo, …")
    /// is sent as text and answered right away. Throws when the microphone or the service
    /// can't be reached, so the app can use another engine.
    public func start(firstTurn: String? = nil) async throws {
        guard state == .idle, !hasEnded else { return }
        state = .starting
        let session = makeSession(settings.service)
        do {
            try await audio.start(
                inputSampleRate: session.inputSampleRate,
                outputSampleRate: session.outputSampleRate,
                microphone: Self.makeMicrophoneSink(frameContinuation))
            guard !hasEnded else { throw CancellationError() }
            startSendingFrames()
            try await connect(session)
            guard !hasEnded else { throw CancellationError() }
        } catch {
            if !hasEnded {
                hasEnded = true
                shutDown()
                state = .idle
            }
            throw error
        }
        state = .listening
        if let firstTurn = firstTurn?.trimmingCharacters(in: .whitespacesAndNewlines),
            !firstTurn.isEmpty
        {
            hasHeardUser = true
            onPartial?(firstTurn)
            await session.sendUserText(firstTurn)
        }
        schedulePoll()
        updateWindow(restart: true)
    }

    /// Ends the conversation now: stops speaking, cancels a running request and closes the
    /// session and the microphone.
    public func end() {
        guard !hasEnded else { return }
        hasEnded = true
        shutDown()
        isSpeaking = false
        isWorking = false
        state = .idle
        onEnded?()
    }

    /// Push to talk let go: the model hears silence from now on and ends the turn itself.
    public func endTurn() {}

    /// Stops Momo at once so the user can talk (push to talk pressed while Momo talks).
    public func interrupt() {
        guard !hasEnded else { return }
        if state == .closing {
            end()
            return
        }
        bargeIn()
        updateState()
    }

    private func connect(_ session: RealtimeVoiceSession) async throws {
        self.session = session
        sessionNumber += 1
        let number = sessionNumber
        route.session = session
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in session.events {
                guard let self, self.sessionNumber == number else { return }
                self.handle(event)
            }
        }
        try await session.connect(settings.session)
    }

    private func startSendingFrames() {
        let frames = frames
        let route = route
        frameTask = Task.detached {
            for await frame in frames {
                guard let session = route.session else { continue }
                await session.sendAudio(route.sendsSilence ? Data(count: frame.count) : frame)
            }
        }
    }

    private func shutDown() {
        window?.cancel()
        poller?.cancel()
        closingTimer?.cancel()
        eventsTask?.cancel()
        eventsTask = nil
        audio.stop()
        frameContinuation.finish()
        frameTask = nil
        route.session = nil
        let coordinator = coordinator
        Task { await coordinator.cancel() }
        pendingCalls = []
        if let session {
            self.session = nil
            close(session)
        }
    }

    /// Closes a session and reports its usage once it has its final totals.
    private func close(_ session: RealtimeVoiceSession) {
        // Held strongly: the app lets go of an ended conversation before the totals arrive.
        let report = onUsage
        Task {
            await session.close()
            let usage = await session.usage
            guard usage.textCharactersSent > 0 || usage.inputAudioSeconds > 0 else { return }
            report?(session.displayName, usage)
        }
    }

    // Audio callbacks run on audio threads, so they must not inherit main actor isolation.
    private nonisolated static func makeMicrophoneSink(
        _ continuation: AsyncStream<Data>.Continuation
    ) -> @Sendable (Data) -> Void {
        { frame in continuation.yield(frame) }
    }

    // MARK: - Events

    private func handle(_ event: RealtimeEvent) {
        guard !hasEnded else { return }
        switch event {
        case .ready:
            break
        case .userSpeechStarted:
            hasHeardUser = true
            isUserSpeaking = true
            bargeIn()
            updateState()
            updateWindow(restart: true)
        case .userSpeechStopped:
            isUserSpeaking = false
            updateState()
            updateWindow(restart: true)
        case .userTranscript(let text, let isFinal):
            heard(text, isFinal: isFinal)
        case .assistantTranscriptDelta(let delta):
            guard !dropsResponse else { return }
            beginResponse()
            assistantText += delta
            onAssistantTranscript?(assistantText)
        case .assistantTranscriptDone(let text):
            guard !dropsResponse else { return }
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != assistantText {
                assistantText = text
                onAssistantTranscript?(text)
            }
        case .assistantAudio(let audio):
            guard !dropsResponse else { return }
            beginResponse()
            self.audio.play(audio)
            updateState()
        case .responseDone:
            responseDone()
        case .functionCall(let call):
            answer(call)
        case .functionCallsCancelled(let ids):
            pendingCalls.subtract(ids)
            if pendingCalls.isEmpty {
                let coordinator = coordinator
                Task { await coordinator.cancel() }
                isWorking = false
                updateState()
            }
        case .sessionEnding:
            sessionEndingSoon = true
        case .error(let error):
            onError?(error.message)
        case .closed(let error):
            sessionClosed(error)
        }
    }

    private func heard(_ text: String, isFinal: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        hasHeardUser = true
        onPartial?(text)
        if isFinal {
            isUserSpeaking = false
            if SpeechText.isClosingPhrase(text) { beginClosing() }
        }
        updateState()
        updateWindow(restart: true)
    }

    private func beginResponse() {
        guard !responseOpen else { return }
        responseOpen = true
        assistantText = ""
        audio.startResponse()
        if state == .closing { closingResponseSeen = true }
    }

    private func responseDone() {
        if dropsResponse {
            dropsResponse = false
            responseOpen = false
            return
        }
        responseOpen = false
        audio.finishResponse()
        updateState()
        updateWindow(restart: true)
    }

    /// The user talks over Momo: playback stops at once, and the session cancels the response
    /// and learns how much of it was heard.
    private func bargeIn() {
        let wasPlaying = audio.isPlaying
        let played = wasPlaying ? audio.interruptPlayback() : nil
        if responseOpen { dropsResponse = true }
        if wasPlaying || responseOpen, let session {
            Task { await session.interrupt(playedMilliseconds: played) }
        }
        if wasPlaying {
            isSpeaking = false
            onMouth?(0)
        }
    }

    // MARK: - ask_momo

    private func answer(_ call: RealtimeFunctionCall) {
        guard let session else { return }
        guard let ask = AskMomoCall(call) else {
            let failure = AskMomoResult.failed("Unknown function or missing request.").output
            Task { await session.sendFunctionResult(failure, for: call) }
            return
        }
        hasHeardUser = true
        awaitingConfirmation = false
        pendingCalls.insert(call.id)
        isWorking = true
        updateState()
        let coordinator = coordinator
        let number = sessionNumber
        Task { [weak self] in
            let result = await coordinator.handle(ask)
            guard let self, !self.hasEnded, self.pendingCalls.remove(call.id) != nil else {
                return
            }
            // A session replaced by a reconnect can't take the result any more; the exchange
            // is still in the chat.
            if self.sessionNumber == number {
                await session.sendFunctionResult(result.output, for: call)
            }
            if case .needsConfirmation = result { self.awaitingConfirmation = true }
            if self.pendingCalls.isEmpty { self.isWorking = false }
            self.updateState()
            self.updateWindow(restart: true)
        }
    }

    // MARK: - State

    private var isMidConversation: Bool {
        isWorking || isUserSpeaking || responseOpen || audio.isPlaying || awaitingConfirmation
    }

    private func updateState() {
        guard !hasEnded, ![.idle, .starting, .closing].contains(state) else { return }
        if audio.isPlaying {
            state = .speaking
        } else if isUserSpeaking || !hasHeardUser {
            state = .listening
        } else if isWorking || responseOpen {
            // Working on a request, or the model's answer is on its way.
            state = .thinking
        } else if awaitingConfirmation {
            state = .awaitingAnswer
        } else {
            state = .followUp
        }
    }

    /// Watches playback for the mouth and for the end of Momo's speech.
    private func schedulePoll() {
        poller = clock.schedule(after: 0.05) { [weak self] in
            guard let self, !self.hasEnded else { return }
            self.poll()
            self.schedulePoll()
        }
    }

    private func poll() {
        let playing = audio.isPlaying
        if playing != isSpeaking {
            isSpeaking = playing
            if !playing { onMouth?(0) }
        }
        if playing { onMouth?(audio.outputLevel) }
        onLevel?(audio.inputLevel)
        if state == .closing {
            if closingResponseSeen, !responseOpen, !playing { end() }
            return
        }
        updateState()
    }

    private func beginClosing() {
        guard state != .closing else { return }
        state = .closing
        closingResponseSeen = responseOpen
        closingTimer = clock.schedule(after: settings.closingGrace) { [weak self] in
            self?.end()
        }
    }

    /// Starts or stops the follow-up window: the conversation ends when it passes while
    /// nobody talks and nothing is being worked on.
    private func updateWindow(restart: Bool) {
        let waits =
            !hasEnded && [.listening, .followUp, .awaitingAnswer].contains(state)
            && !isUserSpeaking && !holdsWindowOpen && !responseOpen && !isWorking
            && !isReconnecting
        guard waits else {
            window?.cancel()
            window = nil
            return
        }
        guard restart || window == nil else { return }
        window?.cancel()
        let delay =
            hasHeardUser && state != .awaitingAnswer
            ? settings.followUpWindow : max(settings.followUpWindow, 8)
        window = clock.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.window = nil
            guard !self.hasEnded, !self.isMidConversation || self.awaitingConfirmation,
                [.listening, .followUp, .awaitingAnswer].contains(self.state),
                !self.holdsWindowOpen
            else { return }
            self.end()
        }
    }

    // MARK: - Reconnecting

    private func sessionClosed(_ error: CloudVoiceError?) {
        // A session that fails while starting is reported by ``start(firstTurn:)``.
        guard !hasEnded, state != .starting, let closed = session else { return }
        let expected = sessionEndingSoon
        sessionEndingSoon = false
        if RealtimeReconnectPolicy.shouldReconnect(
            after: error, isMidConversation: isMidConversation, reconnects: reconnects)
        {
            reconnects += 1
            close(closed)
            reconnect()
            return
        }
        if let error, !expected {
            onError?(error.message)
            onFailure?(error.message)
        }
        end()
    }

    /// Opens a new session with the same settings; the microphone keeps running.
    private func reconnect() {
        _ = audio.interruptPlayback()
        responseOpen = false
        dropsResponse = false
        isUserSpeaking = false
        isReconnecting = true
        updateWindow(restart: false)
        let session = makeSession(settings.service)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.connect(session)
                guard !self.hasEnded else { return }
                self.isReconnecting = false
                self.updateState()
                self.updateWindow(restart: true)
            } catch {
                guard !self.hasEnded else { return }
                self.isReconnecting = false
                let message = error.localizedDescription
                self.onError?(message)
                self.onFailure?(message)
                self.end()
            }
        }
    }
}

/// Where microphone frames go: the current session, shared with the task that sends them.
final class RealtimeAudioRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var _session: RealtimeVoiceSession?
    private var _sendsSilence: Bool

    init(sendsSilence: Bool) {
        _sendsSilence = sendsSilence
    }

    var session: RealtimeVoiceSession? {
        get { lock.withLock { _session } }
        set { lock.withLock { _session = newValue } }
    }

    /// Push to talk with the key up: the model hears silence instead of the microphone.
    var sendsSilence: Bool {
        get { lock.withLock { _sendsSilence } }
        set { lock.withLock { _sendsSilence = newValue } }
    }
}
