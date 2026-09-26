import Foundation

/// A live, two-way voice conversation with a cloud speech-to-speech model.
///
/// The session connects over WebSocket, streams microphone audio in and speech out, and
/// reports what happens as ``events``. The service decides when the user finished a turn and
/// answers on its own; the app plays ``RealtimeEvent/assistantAudio(_:)``, stops playback on
/// ``RealtimeEvent/userSpeechStarted`` (barge-in) and answers
/// ``RealtimeEvent/functionCall(_:)``s.
///
/// ```swift
/// let session = RealtimeVoiceSession(service: .openAI(apiKey: key))
/// Task { for await event in session.events { handle(event) } }
/// try await session.connect(RealtimeSessionConfiguration(
///     instructions: MomoRealtimeAgent.instructions(.init(language: "tr-TR")),
///     language: "tr-TR", tools: [MomoRealtimeAgent.askMomo]))
/// await session.sendAudio(frame)  // PCM16 at session.inputSampleRate
/// ```
///
/// A session connects once and does not reconnect: after ``RealtimeEvent/closed(_:)``, make a
/// new one. Audio sent to it leaves the Mac (see ``RealtimeVoicePrivacy``); ``usage`` has the
/// totals for the privacy log. The API key is never logged or included in errors.
public actor RealtimeVoiceSession {
    /// Where a session is in its life.
    public enum State: Sendable, Equatable {
        case idle, connecting, ready, closed
    }

    /// Everything that happens in the session, in order. Finishes after
    /// ``RealtimeEvent/closed(_:)``.
    public nonisolated let events: AsyncStream<RealtimeEvent>
    /// The service and model, for logs; never contains the key.
    public nonisolated let displayName: String
    /// The sample rate of the PCM16 audio ``sendAudio(_:)`` takes.
    public nonisolated let inputSampleRate: Int
    /// The sample rate of the PCM16 audio in ``RealtimeEvent/assistantAudio(_:)``.
    public nonisolated let outputSampleRate: Int

    public private(set) var state = State.idle

    private let eventContinuation: AsyncStream<RealtimeEvent>.Continuation
    private var codec: any RealtimeCodec
    private let factory: any RealtimeTransportFactory
    private let readyTimeout: TimeInterval
    private var transport: (any RealtimeTransport)?
    private var outgoing: AsyncStream<String>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var closeError: CloudVoiceError?
    private var totals = RealtimeUsage()
    private var readyDate: Date?
    private var closedDate: Date?

    /// Creates a session for `service`. `readyTimeout` is how long ``connect(_:)`` waits for
    /// the service to accept the configuration.
    public init(
        service: RealtimeVoiceService,
        transportFactory: any RealtimeTransportFactory = URLSessionRealtimeTransportFactory(),
        readyTimeout: TimeInterval = 15
    ) {
        let codec: any RealtimeCodec =
            switch service {
            case .openAI(let apiKey, let model): OpenAIRealtimeCodec(apiKey: apiKey, model: model)
            }
        self.init(
            codec: codec, displayName: service.displayName, transportFactory: transportFactory,
            readyTimeout: readyTimeout)
    }

    init(
        codec: any RealtimeCodec, displayName: String,
        transportFactory: any RealtimeTransportFactory, readyTimeout: TimeInterval
    ) {
        self.codec = codec
        self.displayName = displayName
        inputSampleRate = codec.inputSampleRate
        outputSampleRate = codec.outputSampleRate
        factory = transportFactory
        self.readyTimeout = readyTimeout
        (events, eventContinuation) = AsyncStream.makeStream(of: RealtimeEvent.self)
    }

    /// What the session exchanged so far.
    public var usage: RealtimeUsage {
        var usage = totals
        if let readyDate {
            usage.sessionSeconds = max(0, (closedDate ?? Date()).timeIntervalSince(readyDate))
        }
        return usage
    }

    /// Connects and sets the session up. Returns when the service accepted the configuration
    /// (after ``RealtimeEvent/ready``); throws ``CloudVoiceError`` when it could not, and the
    /// session is then closed.
    public func connect(_ configuration: RealtimeSessionConfiguration) async throws {
        guard state == .idle else {
            throw CloudVoiceError("This live voice session was already used.")
        }
        state = .connecting
        let request: URLRequest
        let setup: [String]
        do {
            request = try codec.connectionRequest()
            setup = try codec.setupMessages(for: configuration)
        } catch {
            let failure = CloudVoiceError("Could not prepare the live voice session.")
            finish(failure)
            throw failure
        }
        let transport: any RealtimeTransport
        do {
            transport = try await factory.connect(request)
        } catch {
            let failure = Self.voiceError(error) ?? RealtimeErrors.notConnected
            finish(failure)
            throw failure
        }
        guard state == .connecting else {
            // Closed while the socket opened.
            transport.close()
            throw closeError ?? CancellationError()
        }
        start(transport)
        totals.textCharactersSent += configuration.instructions.count
        for message in setup { outgoing?.yield(message) }
        try await waitUntilReady()
    }

    /// Sends a frame of microphone audio: mono PCM16 at ``inputSampleRate``, ideally 20 to
    /// 40 ms long. Ignored unless the session is ready.
    public func sendAudio(_ pcm16: Data) {
        guard state == .ready, !pcm16.isEmpty else { return }
        totals.inputAudioSeconds += RealtimePCM.duration(
            ofBytes: pcm16.count, sampleRate: inputSampleRate)
        outgoing?.yield(codec.audioMessage(pcm16))
    }

    /// Answers a function call; the model then continues (it voices the result).
    /// `output` is text or a JSON object string, such as ``AskMomoResult/output``.
    public func sendFunctionResult(_ output: String, for call: RealtimeFunctionCall) {
        guard state == .ready else { return }
        do {
            let messages = try codec.functionResultMessages(output, for: call)
            totals.textCharactersSent += output.count
            for message in messages { outgoing?.yield(message) }
        } catch {
            eventContinuation.yield(
                .error(CloudVoiceError("Could not send Momo's answer to the live voice model.")))
        }
    }

    /// Handles a barge-in after the app stopped playback: cancels the response in progress
    /// and, where the service supports it (OpenAI), cuts the model's message down to the
    /// `playedMilliseconds` the user heard, so the model knows what was said. Pass `nil` when
    /// nothing of the current response was played.
    public func interrupt(playedMilliseconds: Int?) {
        guard state == .ready else { return }
        for message in codec.interruptMessages(playedMilliseconds: playedMilliseconds) {
            outgoing?.yield(message)
        }
    }

    /// Ends the session and closes the connection. Emits ``RealtimeEvent/closed(_:)`` with
    /// `nil`.
    public func close() {
        finish(nil)
    }

    // MARK: - Connection

    private func start(_ transport: any RealtimeTransport) {
        self.transport = transport
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        outgoing = continuation
        // One sender keeps messages in order: setup first, then audio and results.
        tasks.append(
            Task { [weak self] in
                for await text in stream {
                    do {
                        try await transport.send(text)
                    } catch {
                        await self?.transportFailed(error)
                        return
                    }
                }
            })
        tasks.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        let message = try await transport.receive()
                        guard let self else { return }
                        await self.received(message)
                    } catch {
                        await self?.transportFailed(error)
                        return
                    }
                }
            })
    }

    private func waitUntilReady() async throws {
        switch state {
        case .ready: return
        case .closed: throw closeError ?? CancellationError()
        case .idle, .connecting: break
        }
        let timeout = readyTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.readyTimedOut()
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
        }
    }

    private func readyTimedOut() {
        guard state == .connecting else { return }
        finish(RealtimeErrors.timedOut)
    }

    private func received(_ message: RealtimeTransportMessage) {
        guard state != .closed, let text = message.text else { return }
        for event in codec.decode(text) {
            handle(event)
        }
    }

    private func handle(_ event: RealtimeEvent) {
        switch event {
        case .ready:
            guard state == .connecting else { return }
            state = .ready
            readyDate = Date()
            readyContinuation?.resume()
            readyContinuation = nil
            eventContinuation.yield(.ready)
        case .error(let error) where state == .connecting:
            // The service refused the configuration.
            finish(error)
        case .assistantAudio(let audio):
            totals.outputAudioSeconds += RealtimePCM.duration(
                ofBytes: audio.count, sampleRate: outputSampleRate)
            eventContinuation.yield(event)
        case .closed(let error):
            finish(error)
        default:
            eventContinuation.yield(event)
        }
    }

    private func transportFailed(_ error: any Error) {
        guard state != .closed else { return }
        finish(Self.voiceError(error))
    }

    private func finish(_ error: CloudVoiceError?) {
        guard state != .closed else { return }
        state = .closed
        closeError = error
        if readyDate != nil { closedDate = Date() }
        outgoing?.finish()
        outgoing = nil
        transport?.close()
        transport = nil
        for task in tasks { task.cancel() }
        tasks = []
        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(throwing: error ?? CancellationError())
        }
        eventContinuation.yield(.closed(error))
        eventContinuation.finish()
    }

    /// A readable error, or `nil` for a clean close.
    static func voiceError(_ error: any Error) -> CloudVoiceError? {
        if error is CancellationError { return nil }
        if let error = error as? CloudVoiceError { return error }
        return CloudVoiceError("The live voice connection failed: \(error.localizedDescription)")
    }
}
