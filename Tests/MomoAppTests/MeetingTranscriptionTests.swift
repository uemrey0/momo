import Foundation
import MomoVoice
import Testing

@testable import MomoApp

/// Answers with a fixed transcript, or fails.
private struct FakeTranscription: AudioTranscriptionService {
    var displayName: String
    var error: String?

    func transcribe(_ audio: AudioClip, options: TranscriptionOptions) async throws -> Transcript {
        if let error { throw CloudVoiceError(error) }
        return Transcript(
            text: displayName, segments: [TranscriptSegment(text: displayName, start: 0, end: 1)])
    }
}

@Suite("Meeting transcription")
struct MeetingTranscriptionTests {
    private let clip = AudioClip.wav(samples: [0.1, -0.1], sampleRate: 16_000)

    private func engine(
        cloudFails: Bool = false, fallbackFails: Bool = false, remote: Bool = true
    ) -> MeetingController.TranscriptionEngine {
        let fallback = FakeTranscription(
            displayName: "mac", error: fallbackFails ? "helper crashed" : nil)
        guard remote else {
            return .init(service: fallback, isRemote: false, identifiesSpeakers: false)
        }
        return .init(
            service: FakeTranscription(displayName: "cloud", error: cloudFails ? "timed out" : nil),
            isRemote: true, identifiesSpeakers: true, fallback: fallback)
    }

    private func transcribe(
        _ engine: MeetingController.TranscriptionEngine,
        route: ChunkTranscription.Route = .engine
    ) async -> ChunkTranscription {
        await ChunkTranscription.transcribe(
            clip, engine: engine, options: TranscriptionOptions(wantsSegments: true), route: route)
    }

    @Test("a working cloud service transcribes without a notice")
    func cloudWorks() async {
        let result = await transcribe(engine())
        guard case .transcribed(let transcript) = result else {
            Issue.record("expected the cloud transcript, got \(result)")
            return
        }
        #expect(transcript.text == "cloud")
        #expect(result.notice == nil)
    }

    @Test("a failed cloud request falls back to the Mac and says so")
    func cloudFailsFallbackWorks() async throws {
        let result = await transcribe(engine(cloudFails: true))
        guard case .fellBack(let transcript, let cloudError) = result else {
            Issue.record("expected the fallback transcript, got \(result)")
            return
        }
        #expect(transcript.text == "mac")
        #expect(cloudError?.localizedDescription == "timed out")
        let notice = try #require(result.notice)
        #expect(notice.contains("on this Mac"))
        #expect(notice.contains("timed out"))
    }

    @Test("when the fallback fails too, the chunk is lost and nobody claims it was transcribed")
    func bothFail() async throws {
        let result = await transcribe(engine(cloudFails: true, fallbackFails: true))
        guard case .lost(let error) = result else {
            Issue.record("expected a lost chunk, got \(result)")
            return
        }
        #expect(error.localizedDescription == "helper crashed")
        #expect(result.transcript == nil)
        let notice = try #require(result.notice)
        #expect(!notice.contains("on this Mac"))
        #expect(notice.contains("couldn't be transcribed"))
    }

    @Test("an on-device failure is lost with the service's own error, not a cloud failure")
    func onDeviceFails() async throws {
        let result = await transcribe(engine(fallbackFails: true, remote: false))
        guard case .lost = result else {
            Issue.record("expected a lost chunk, got \(result)")
            return
        }
        let notice = try #require(result.notice)
        #expect(!notice.contains("Cloud"))
        #expect(notice.contains("helper crashed"))
    }

    @Test("a chunk routed to the fallback never reaches the cloud")
    func routedToFallback() async {
        // The cloud would fail; going straight to the Mac must not report that.
        let result = await transcribe(engine(cloudFails: true), route: .fallback)
        guard case .fellBack(let transcript, nil) = result else {
            Issue.record("expected a quiet fallback, got \(result)")
            return
        }
        #expect(transcript.text == "mac")
        #expect(result.notice == nil)
    }

    @Test("after a cloud failure the Mac takes over for the cool-down, then the cloud again")
    func breakerCoolsDown() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var breaker = MeetingCloudBreaker(coolDown: 120)
        let cloud = engine()
        #expect(breaker.route(for: cloud, backlog: 0, now: start) == .engine)

        breaker.record(await transcribe(engine(cloudFails: true)), now: start)
        #expect(
            breaker.route(for: cloud, backlog: 0, now: start.addingTimeInterval(60)) == .fallback)
        #expect(
            breaker.route(for: cloud, backlog: 0, now: start.addingTimeInterval(121)) == .engine)

        breaker.record(await transcribe(cloud), now: start.addingTimeInterval(121))
        #expect(breaker.pausedUntil == nil)
        // A cancelled chunk says nothing about the service.
        breaker.record(.cancelled, now: start)
        #expect(breaker.pausedUntil == nil)
    }

    @Test("a track that fell behind skips the cloud until it catches up")
    func breakerBacklog() {
        let breaker = MeetingCloudBreaker()
        let cloud = engine()
        #expect(
            breaker.route(for: cloud, backlog: MeetingCloudBreaker.catchUpBacklog - 1) == .engine)
        #expect(breaker.route(for: cloud, backlog: MeetingCloudBreaker.catchUpBacklog) == .fallback)
        #expect(MeetingCloudBreaker.catchUpBacklog < MeetingCloudBreaker.maximumBacklog)
    }

    @Test("on-device meetings always use their engine, having no fallback")
    func breakerOnDevice() {
        var breaker = MeetingCloudBreaker()
        breaker.record(.lost(CloudVoiceError("crashed")))
        #expect(breaker.route(for: engine(remote: false), backlog: 100) == .engine)
    }

    @Test("meeting saves wait for the interval since the last save")
    func saveSchedule() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var schedule = MeetingSaveSchedule(interval: 30)
        #expect(schedule.delay(now: start) == 0)
        schedule.saved(at: start)
        #expect(schedule.delay(now: start.addingTimeInterval(10)) == 20)
        #expect(schedule.delay(now: start.addingTimeInterval(30)) == 0)
        #expect(schedule.delay(now: start.addingTimeInterval(90)) == 0)
    }

    @Test("recovers and repairs the audio of an interrupted meeting")
    func recoversAudio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("m1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Written as a crash leaves it: an empty header followed by samples.
        var data = WAVEncoder.encode(samples: [], sampleRate: 16_000)
        data.append(Data(repeating: 0x10, count: 64))
        try data.write(to: folder.appendingPathComponent("system.wav"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        #expect(MeetingAudioRecovery.recover(meetingID: "m1", in: directory) == ["m1/system.wav"])
        let decoded = try #require(
            WAVEncoder.decode(try Data(contentsOf: folder.appendingPathComponent("system.wav"))))
        #expect(decoded.samples.count == 32)
        #expect(MeetingAudioRecovery.recover(meetingID: "missing", in: directory).isEmpty)
    }
}
