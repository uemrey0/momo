import Foundation
import Testing

@testable import MomoVoice

/// A microphone and speaker the test controls.
@MainActor
final class FakeRealtimeAudio: RealtimeAudioIO {
    var isPlaying = false
    var outputLevel = 0.5
    var inputLevel = 0.2
    private(set) var rates: (input: Int, output: Int)?
    private(set) var played: [Data] = []
    private(set) var interruptions = 0
    private(set) var isStopped = false
    private var microphone: (@Sendable (Data) -> Void)?
    /// What ``interruptPlayback()`` reports as heard.
    var heardMilliseconds: Int? = 420

    func start(
        inputSampleRate: Int, outputSampleRate: Int,
        microphone: @escaping @Sendable (Data) -> Void
    ) async throws {
        rates = (inputSampleRate, outputSampleRate)
        self.microphone = microphone
    }

    func stop() { isStopped = true }

    func play(_ pcm16: Data) {
        played.append(pcm16)
        isPlaying = true
    }

    func startResponse() {}
    func finishResponse() {}

    func interruptPlayback() -> Int? {
        interruptions += 1
        isPlaying = false
        return heardMilliseconds
    }

    /// Delivers a microphone frame, as the tap would.
    func hear(_ frame: Data) { microphone?(frame) }
}

/// Momo's brain as a script: records requests and answers them.
@MainActor
final class FakeRealtimeBrain: RealtimeBrain {
    private(set) var requests: [String] = []
    private(set) var confirmations: [Bool] = []
    private(set) var cancellations = 0
    var answer = "Done."
    /// Asked before answering, when set.
    var question: String?
    /// Waits until cancelled instead of answering.
    var hangs = false

    func run(
        _ request: String, confirm: @escaping AskMomoCoordinator.Confirm
    ) async throws -> String {
        requests.append(request)
        if hangs {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancellations += 1
                throw error
            }
        }
        if let question {
            let approved = await confirm(question)
            confirmations.append(approved)
            if !approved { return "Okay, I left it." }
        }
        return answer
    }
}

/// Hands out a fresh fake socket per connection, each accepting the configuration.
final class RealtimeTransportPool: RealtimeTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeRealtimeTransport] = []
    /// Connections from this number on fail.
    var failFrom = Int.max

    var transports: [FakeRealtimeTransport] { lock.withLock { made } }

    func connect(_ request: URLRequest) async throws -> any RealtimeTransport {
        let transport = FakeRealtimeTransport()
        let count = lock.withLock {
            made.append(transport)
            return made.count
        }
        if count >= failFrom { throw CloudVoiceError(status: 401, "The API key was rejected.") }
        transport.autoReply { text in
            text.contains("\"session.update\"") ? [OpenAIFixtures.sessionUpdated] : []
        }
        transport.push(OpenAIFixtures.sessionCreated)
        return transport
    }
}

/// Waits for a condition the conversation reaches through its tasks.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
@Suite("Realtime conversation", .timeLimit(.minutes(1)))
struct RealtimeConversationTests {
    let audio = FakeRealtimeAudio()
    let brain = FakeRealtimeBrain()
    let clock = TestClock()
    let pool = RealtimeTransportPool()

    func makeConversation(pushToTalk: Bool = false) -> RealtimeConversation {
        let pool = pool
        return RealtimeConversation(
            settings: .init(
                service: .openAI(apiKey: "sk-secret"),
                session: RealtimeSessionConfiguration(
                    instructions: "Hi", tools: [MomoRealtimeAgent.askMomo]),
                followUpWindow: 8, pushToTalk: pushToTalk),
            audio: audio, brain: brain, clock: clock,
            makeSession: {
                RealtimeVoiceSession(service: $0, transportFactory: pool, readyTimeout: 5)
            })
    }

    func sent(_ type: String, on index: Int = 0) -> [[String: Any]] {
        pool.transports[index].sentObjects.filter { $0["type"] as? String == type }
    }

    static func call(_ arguments: String, id: String = "call_1") -> String {
        let escaped = arguments.replacingOccurrences(of: "\"", with: "\\\"")
        return
            #"{"type":"response.output_item.done","item":{"type":"function_call","name":"ask_momo","call_id":"\#(id)","arguments":"\#(escaped)"}}"#
    }

    @Test("opens the audio at the session's rates, sends the first turn and streams the microphone")
    func starts() async throws {
        let conversation = makeConversation()
        var partials: [String] = []
        conversation.onPartial = { partials.append($0) }
        try await conversation.start(firstTurn: "What's on my calendar?")
        #expect(conversation.state == .listening)
        #expect(audio.rates?.input == 24_000 && audio.rates?.output == 24_000)
        #expect(partials == ["What's on my calendar?"])
        await pool.transports[0].waitForSent(3)
        #expect(sent("conversation.item.create").count == 1)
        audio.hear(Data(repeating: 1, count: 960 * 2))
        #expect(await eventually { !sent("input_audio_buffer.append").isEmpty })
        conversation.end()
        #expect(audio.isStopped)
    }

    @Test("push to talk sends silence while the key is up")
    func pushToTalk() async throws {
        let conversation = makeConversation(pushToTalk: true)
        try await conversation.start()
        let frame = Data(repeating: 7, count: 8)
        audio.hear(frame)
        #expect(await eventually { !sent("input_audio_buffer.append").isEmpty })
        #expect(
            sent("input_audio_buffer.append").last?["audio"] as? String
                == Data(count: 8).base64EncodedString())
        conversation.holdsWindowOpen = true
        audio.hear(frame)
        #expect(await eventually { sent("input_audio_buffer.append").count == 2 })
        #expect(
            sent("input_audio_buffer.append").last?["audio"] as? String
                == frame.base64EncodedString())
        conversation.end()
    }

    @Test("runs ask_momo through the brain and returns its answer")
    func asksMomo() async throws {
        let conversation = makeConversation()
        var working: [Bool] = []
        conversation.onWorkingChange = { working.append($0) }
        try await conversation.start()
        brain.answer = "You have a dentist appointment at nine."
        pool.transports[0].push(Self.call(#"{"request":"What's on my calendar tomorrow?"}"#))
        #expect(await eventually { !sent("conversation.item.create").isEmpty })
        #expect(brain.requests == ["What's on my calendar tomorrow?"])
        let item = try #require(sent("conversation.item.create").first?["item"] as? [String: Any])
        #expect(item["call_id"] as? String == "call_1")
        let output = try #require(RealtimeJSON.object(item["output"] as? String ?? ""))
        #expect(output["status"] as? String == "done")
        #expect(output["answer"] as? String == "You have a dentist appointment at nine.")
        #expect(working == [true, false])
        conversation.end()
    }

    @Test("carries the brain's question through the model and resumes with the answer")
    func confirmation() async throws {
        let conversation = makeConversation()
        try await conversation.start()
        brain.question = "Delete the note Shopping?"
        pool.transports[0].push(Self.call(#"{"request":"Delete the note Shopping"}"#))
        #expect(await eventually { !sent("conversation.item.create").isEmpty })
        let first = try #require(
            RealtimeJSON.object(
                (sent("conversation.item.create")[0]["item"] as? [String: Any])?["output"]
                    as? String ?? ""))
        #expect(first["status"] as? String == "needs_confirmation")
        #expect(conversation.state == .awaitingAnswer)
        let id = try #require(first["confirmation_id"] as? String)
        pool.transports[0].push(
            Self.call(
                #"{"request":"Delete the note Shopping","confirmation_id":"\#(id)","confirmed":true}"#,
                id: "call_2"))
        #expect(await eventually { sent("conversation.item.create").count == 2 })
        #expect(brain.confirmations == [true])
        let second = try #require(
            RealtimeJSON.object(
                (sent("conversation.item.create")[1]["item"] as? [String: Any])?["output"]
                    as? String ?? ""))
        #expect(second["status"] as? String == "done")
        conversation.end()
    }

    @Test("stops playback on barge-in, reports what was heard and drops the rest")
    func bargeIn() async throws {
        let conversation = makeConversation()
        try await conversation.start()
        let transport = pool.transports[0]
        transport.push(OpenAIFixtures.responseCreated)
        transport.push(OpenAIFixtures.audioDelta(Data(count: 4_800), item: "item_7"))
        #expect(await eventually { audio.played.count == 1 })
        clock.advance(by: 0.06)
        #expect(conversation.state == .speaking)
        transport.push(OpenAIFixtures.speechStarted)
        #expect(await eventually { !sent("conversation.item.truncate").isEmpty })
        #expect(audio.interruptions == 1)
        #expect(sent("response.cancel").count == 1)
        #expect(sent("conversation.item.truncate").first?["audio_end_ms"] as? Int == 100)
        // Late audio of the cancelled response is not played.
        transport.push(OpenAIFixtures.audioDelta(Data(count: 480), item: "item_7"))
        transport.push(OpenAIFixtures.responseCancelled)
        transport.push(OpenAIFixtures.audioDelta(Data(count: 480), item: "item_8"))
        #expect(await eventually { audio.played.count == 2 })
        #expect(audio.played.last == Data(count: 480))
        conversation.end()
    }

    @Test("listens for a follow-up after Momo spoke, then ends and logs the session")
    func followUp() async throws {
        let conversation = makeConversation()
        var ended = false
        var usage: (String, RealtimeUsage)?
        conversation.onEnded = { ended = true }
        conversation.onUsage = { usage = ($0, $1) }
        try await conversation.start()
        let transport = pool.transports[0]
        transport.push(OpenAIFixtures.speechStarted)
        transport.push(OpenAIFixtures.transcriptionCompleted)
        transport.push(OpenAIFixtures.transcriptDelta)
        transport.push(OpenAIFixtures.audioDelta(Data(count: 480)))
        transport.push(OpenAIFixtures.responseDone)
        #expect(await eventually { audio.played.count == 1 })
        #expect(await eventually { conversation.state == .speaking })
        clock.advance(by: 20)
        #expect(!ended, "the window doesn't run while Momo talks")
        audio.isPlaying = false
        clock.advance(by: 0.06)
        #expect(conversation.state == .followUp)
        clock.advance(by: 8.1)
        #expect(ended)
        #expect(await eventually { usage != nil })
        #expect(usage?.0 == "OpenAI gpt-realtime-2.1")
        #expect((usage?.1.textCharactersSent ?? 0) > 0)
    }

    @Test("a closing phrase ends the conversation once the goodbye played")
    func closingPhrase() async throws {
        let conversation = makeConversation()
        var ended = false
        conversation.onEnded = { ended = true }
        try await conversation.start()
        let transport = pool.transports[0]
        transport.push(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i","transcript":"Thanks, that's all"}"#
        )
        #expect(await eventually { conversation.state == .closing })
        transport.push(OpenAIFixtures.audioDelta(Data(count: 480)))
        transport.push(OpenAIFixtures.responseDone)
        #expect(await eventually { audio.played.count == 1 })
        clock.advance(by: 0.06)
        #expect(!ended)
        audio.isPlaying = false
        clock.advance(by: 0.06)
        #expect(ended)
    }

    @Test("ending the conversation stops a running request")
    func endStopsRequest() async throws {
        let conversation = makeConversation()
        try await conversation.start()
        brain.hangs = true
        pool.transports[0].push(Self.call(#"{"request":"Find flights"}"#))
        #expect(await eventually { conversation.isWorking })
        conversation.end()
        #expect(await eventually { brain.cancellations == 1 })
    }

    @Test("reconnects once when the service drops a session mid-conversation")
    func reconnects() async throws {
        let conversation = makeConversation()
        var failures: [String] = []
        var usages: [String] = []
        conversation.onFailure = { failures.append($0) }
        conversation.onUsage = { name, _ in usages.append(name) }
        try await conversation.start()
        brain.hangs = true
        pool.transports[0].push(Self.call(#"{"request":"Find flights"}"#))
        #expect(await eventually { conversation.isWorking })
        pool.transports[0].fail(RealtimeErrors.noConnection)
        #expect(await eventually { pool.transports.count == 2 })
        #expect(await eventually { !pool.transports[1].sentMessages.isEmpty })
        #expect(failures.isEmpty)
        #expect(conversation.state != .idle)
        #expect(await eventually { usages.count == 1 })
        conversation.end()
    }

    @Test("ends with a failure when the session drops while idle")
    func dropWhileIdle() async throws {
        let conversation = makeConversation()
        var failures: [String] = []
        var ended = false
        conversation.onFailure = { failures.append($0) }
        conversation.onEnded = { ended = true }
        try await conversation.start()
        pool.transports[0].fail(RealtimeErrors.noConnection)
        #expect(await eventually { ended })
        #expect(failures == [RealtimeErrors.noConnection.message])
        #expect(pool.transports.count == 1)
    }

    @Test("a connection that fails at the start throws and releases the microphone")
    func failsToStart() async throws {
        pool.failFrom = 1
        let conversation = makeConversation()
        await #expect(throws: CloudVoiceError.self) { try await conversation.start() }
        #expect(audio.isStopped)
        #expect(conversation.state == .idle)
    }
}

@Suite("Realtime reconnect policy")
struct RealtimeReconnectPolicyTests {
    @Test("reconnects once, only mid-conversation and not for errors that repeat")
    func decisions() {
        let dropped = RealtimeErrors.noConnection
        #expect(
            RealtimeReconnectPolicy.shouldReconnect(
                after: dropped, isMidConversation: true, reconnects: 0))
        #expect(
            !RealtimeReconnectPolicy.shouldReconnect(
                after: dropped, isMidConversation: false, reconnects: 0))
        #expect(
            !RealtimeReconnectPolicy.shouldReconnect(
                after: dropped, isMidConversation: true, reconnects: 1))
        for status in [401, 403, 404, 429] {
            #expect(
                !RealtimeReconnectPolicy.shouldReconnect(
                    after: CloudVoiceError(status: status, "No."), isMidConversation: true,
                    reconnects: 0))
        }
        #expect(
            RealtimeReconnectPolicy.shouldReconnect(
                after: CloudVoiceError("The live session reached its time limit."),
                isMidConversation: true, reconnects: 0))
    }
}
