import AVFoundation
import Foundation
import Testing

@testable import MomoVoice

/// A sine wave for resampling tests.
func sine(frequency: Double, sampleRate: Int, seconds: Double, amplitude: Float = 0.5) -> [Float] {
    (0..<Int(Double(sampleRate) * seconds)).map {
        amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / Double(sampleRate)))
    }
}

/// Counts upward zero crossings, which is the frequency for a one-second sine.
func upwardCrossings(_ samples: [Float]) -> Int {
    zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
}

@Suite("Realtime audio")
struct RealtimeAudioTests {
    @Test("encodes floats as little-endian PCM16 and back")
    func pcmRoundTrip() {
        let data = RealtimePCM.encode([0, 1, -1, 0.5, 2, .nan])
        #expect(data.count == 12)
        #expect(Array(data[2...3]) == [0xFF, 0x7F])  // 32767
        #expect(Array(data[4...5]) == [0x01, 0x80])  // -32767
        #expect(Array(data[8...9]) == [0xFF, 0x7F])  // clamped
        #expect(Array(data[10...11]) == [0, 0])  // not a number becomes silence
        let samples = RealtimePCM.decode(data)
        #expect(samples.count == 6)
        #expect(abs(samples[3] - 0.5) < 0.0001)
        #expect(RealtimePCM.duration(ofBytes: 48_000, sampleRate: 24_000) == 1)
    }

    @Test(
        "resamples between 48, 24 and 16 kHz keeping the pitch",
        arguments: [
            (48_000, 24_000), (24_000, 16_000), (16_000, 24_000), (48_000, 16_000),
        ])
    func resamples(rates: (Int, Int)) {
        let input = sine(frequency: 440, sampleRate: rates.0, seconds: 1)
        let output = RealtimeResampler.resample(input, from: rates.0, to: rates.1)
        #expect(abs(output.count - rates.1) <= rates.1 / 100)
        #expect(abs(upwardCrossings(output) - 440) <= 2)
        let peak = output.map(abs).max() ?? 0
        #expect(peak > 0.45 && peak < 0.55)
    }

    @Test("resamples a stream in pieces like the whole clip")
    func streamingResample() throws {
        let input = sine(frequency: 300, sampleRate: 48_000, seconds: 1)
        let resampler = try #require(RealtimeResampler(from: 48_000, to: 24_000))
        var output: [Float] = []
        for start in stride(from: 0, to: input.count, by: 960) {
            output += resampler.process(Array(input[start..<min(input.count, start + 960)]))
        }
        output += resampler.finish()
        #expect(abs(output.count - 24_000) <= 240)
        #expect(abs(upwardCrossings(output) - 300) <= 2)
        #expect(RealtimeResampler(from: 24_000, to: 24_000)?.process([0.1, 0.2]) == [0.1, 0.2])
        #expect(RealtimeResampler(from: 0, to: 24_000) == nil)
    }

    @Test("cuts audio into equal PCM16 frames")
    func frames() {
        var framer = RealtimeAudioFramer(sampleRate: 16_000, frameDuration: 0.02)
        #expect(framer.frameLength == 320)
        #expect(framer.append([Float](repeating: 0.1, count: 500)).map(\.count) == [640])
        #expect(framer.append([Float](repeating: 0.1, count: 500)).map(\.count) == [640, 640])
        #expect(framer.flush()?.count == 40 * 2)
        #expect(framer.flush() == nil)
    }

    @Test("turns a 48 kHz stereo microphone buffer into 24 kHz frames")
    func microphone() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2,
                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let wave = sine(frequency: 440, sampleRate: 48_000, seconds: 1)
        for channel in 0..<2 {
            let pointer = try #require(buffer.floatChannelData?[channel])
            for index in 0..<wave.count { pointer[index] = wave[index] }
        }
        let encoder = RealtimeMicrophoneEncoder(outputSampleRate: 24_000, frameDuration: 0.04)
        let frames = encoder.encode(buffer)
        #expect(frames.count >= 23)
        #expect(frames.allSatisfy { $0.count == 960 * 2 })
        let samples = frames.flatMap(RealtimePCM.decode)
        #expect(abs(upwardCrossings(samples) - 440 * samples.count / 24_000) <= 3)
    }

    @Test("waits for a prebuffer, then plays and counts what was heard")
    func playbackPrebuffer() {
        var buffer = RealtimePlaybackBuffer(sampleRate: 1_000, prebufferDuration: 0.05)
        buffer.startResponse()
        buffer.enqueue([Float](repeating: 0.5, count: 30))
        #expect(buffer.read(10) == [Float](repeating: 0, count: 10))
        #expect(!buffer.isPlaying)
        buffer.enqueue([Float](repeating: 0.5, count: 30))
        #expect(buffer.read(20) == [Float](repeating: 0.5, count: 20))
        #expect(buffer.isPlaying)
        #expect(buffer.playedMilliseconds == 20)
        #expect(buffer.bufferedSamples == 40)
    }

    @Test("rebuffers after an underrun but drains the end of a response")
    func playbackUnderrun() {
        var buffer = RealtimePlaybackBuffer(sampleRate: 1_000, prebufferDuration: 0.02)
        buffer.enqueue([Float](repeating: 0.5, count: 25))
        let first = buffer.read(30)
        #expect(first.prefix(25).allSatisfy { $0 == 0.5 } && first.suffix(5).allSatisfy { $0 == 0 })
        #expect(buffer.underruns == 1)
        #expect(!buffer.isPlaying)
        buffer.enqueue([Float](repeating: 0.25, count: 10))
        #expect(buffer.read(5) == [0, 0, 0, 0, 0])  // below the prebuffer again
        buffer.finishResponse()
        #expect(buffer.read(10) == [Float](repeating: 0.25, count: 10))
        #expect(buffer.underruns == 1)
        #expect(buffer.isIdle || buffer.bufferedSamples == 0)
    }

    @Test("a barge-in drops queued audio and reports the heard milliseconds")
    func playbackInterrupt() {
        var buffer = RealtimePlaybackBuffer(sampleRate: 24_000, prebufferDuration: 0)
        buffer.enqueuePCM16(RealtimePCM.encode([Float](repeating: 0.1, count: 24_000)))
        _ = buffer.read(12_000)
        #expect(buffer.interrupt() == 500)
        #expect(buffer.bufferedSamples == 0)
        #expect(buffer.playedSamples == 0)
        #expect(buffer.isIdle)
    }

    @Test("usage adds both directions for the cost estimate")
    func usage() {
        var usage = RealtimeUsage()
        usage.inputAudioSeconds = 12
        usage.outputAudioSeconds = 8
        #expect(usage.billedAudioSeconds == 20)
        #expect(RealtimeVoicePrivacy.notice.contains("leaves your Mac"))
    }
}
