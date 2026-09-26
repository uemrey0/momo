import Foundation
import Testing

@testable import MomoVoice

@Suite("Meeting audio")
struct MeetingAudioTests {
    /// One second of a loud tone.
    private func loud(_ seconds: Double, rate: Int = 100) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { $0.isMultiple(of: 2) ? 0.5 : -0.5 }
    }

    private func quiet(_ seconds: Double, rate: Int = 100) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    private let configuration = AudioChunker.Configuration(
        sampleRate: 100, minimumDuration: 20, maximumDuration: 30, frameDuration: 0.1)

    @Test("cuts at the quietest moment between the minimum and maximum length")
    func quietCut() throws {
        var chunker = AudioChunker(configuration: configuration)
        // Speech, a pause at 24–25 s, more speech.
        let audio = loud(24) + quiet(1) + loud(20)
        let chunks = chunker.append(audio)
        let first = try #require(chunks.first)
        #expect(chunks.count == 1)
        #expect(first.index == 0)
        #expect(first.start == 0)
        #expect(first.duration > 24 && first.duration < 25)
        let last = chunker.finish()
        let rest = try #require(last)
        #expect(rest.index == 1)
        #expect(abs(rest.start - first.duration) < 0.001)
        #expect(first.samples + rest.samples == audio)
        #expect(chunker.finish() == nil)
    }

    @Test("cuts at the maximum length when there is no pause, keeping every sample")
    func noPause() {
        var chunker = AudioChunker(configuration: configuration)
        var chunks: [AudioChunker.Chunk] = []
        // Fed in small pieces, like an audio tap.
        let audio = loud(95)
        for start in stride(from: 0, to: audio.count, by: 37) {
            chunks += chunker.append(Array(audio[start..<min(audio.count, start + 37)]))
        }
        if let last = chunker.finish() { chunks.append(last) }
        #expect(chunks.map(\.index) == Array(0..<chunks.count))
        #expect(chunks.dropLast().allSatisfy { $0.duration >= 20 && $0.duration <= 30 })
        #expect(chunks.flatMap(\.samples).count == audio.count)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(abs(next.start - (previous.start + previous.duration)) < 0.001)
        }
    }

    @Test("tells silence from sound")
    func sound() {
        #expect(!AudioChunker.hasSound(quiet(10, rate: 16_000), sampleRate: 16_000))
        #expect(
            !AudioChunker.hasSound(
                loud(0.1, rate: 16_000) + quiet(5, rate: 16_000), sampleRate: 16_000))
        #expect(
            AudioChunker.hasSound(
                quiet(2, rate: 16_000) + loud(1, rate: 16_000), sampleRate: 16_000))
    }

    @Test("scopes speaker labels to the chunk and moves segments to its start")
    func chunkSegments() {
        let transcript = Transcript(
            text: "",
            segments: [
                TranscriptSegment(text: "Hi", start: 0, end: 1, speaker: "speaker_1"),
                TranscriptSegment(text: "Hey", start: 1, end: 2, speaker: "speaker_0"),
                TranscriptSegment(text: "So", start: 2, end: 3, speaker: "speaker_1"),
                TranscriptSegment(text: "Me", start: 3, end: 4),
            ])
        let segments = transcript.chunkSegments(index: 2, start: 50)
        #expect(segments.map(\.speaker) == ["3A", "3B", "3A", nil])
        #expect(segments.map(\.start) == [50, 51, 52, 53])
        let lettered = Transcript(
            text: "",
            segments: [
                TranscriptSegment(text: "a", start: 0, end: 1, speaker: "B"),
                TranscriptSegment(text: "b", start: 1, end: 2, speaker: "A"),
            ])
        #expect(lettered.chunkSegments(index: 0, start: 0).map(\.speaker) == ["1B", "1A"])
        #expect(SpeakerLabels.letter(at: 27) == "AB")
    }

    @Test("decodes the WAV it encodes")
    func wavRoundTrip() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let decoded = try #require(
            WAVEncoder.decode(WAVEncoder.encode(samples: samples, sampleRate: 16_000)))
        #expect(decoded.sampleRate == 16_000)
        #expect(zip(decoded.samples, samples).allSatisfy { abs($0 - $1) < 0.001 })
        #expect(WAVEncoder.decode(Data("not audio".utf8)) == nil)
    }

    @Test("writes a long recording to a WAV file piece by piece")
    func fileWriter() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-tests-\(UUID().uuidString)")
            .appendingPathComponent("microphone.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try WAVFileWriter(url: url, sampleRate: 16_000)
        writer.append([0.25, -0.25])
        writer.append([0.5])
        writer.close()
        writer.append([1])
        let decoded = try #require(WAVEncoder.decode(try Data(contentsOf: url)))
        #expect(decoded.samples.count == 3)
        #expect(abs(decoded.samples[2] - 0.5) < 0.001)
    }

    @Test("groups recognised words into sentences and pauses")
    func sentences() {
        let words = ["Hello", "there.", "How", "are", "you", "today?", "Fine"].enumerated().map {
            TranscriptSegment(
                text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.5)
        }
        var paused = words
        paused[6].start = 9
        paused[6].end = 9.5
        let segments = OnDeviceTranscriptionService.sentences(from: paused)
        #expect(segments.map(\.text) == ["Hello there. How are you today?", "Fine"])
        #expect(segments.first?.start == 0)
        #expect(segments.last?.start == 9)
    }
}
