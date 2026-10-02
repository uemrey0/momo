import AVFoundation
import Foundation
import Testing

@testable import MomoVoice

/// Stands in for `AVAudioEngine`: records what the tap does to it.
private final class FakeTapEngine: MicrophoneTapEngine, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _format: AVAudioFormat
    private var _failsToStart = false
    private(set) var tappedRates: [Double] = []
    private(set) var isTapped = false
    private(set) var isRunning = false
    private(set) var starts = 0

    init(sampleRate: Double) {
        _format = Self.format(sampleRate)
    }

    static func format(_ sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    /// A different microphone: its format, and whether the engine will start with it.
    func switchDevice(sampleRate: Double, failsToStart: Bool = false) {
        lock.withLock {
            _format = Self.format(sampleRate)
            _failsToStart = failsToStart
            // The engine stops itself when the configuration changes.
            isRunning = false
        }
    }

    var microphoneFormat: AVAudioFormat { lock.withLock { _format } }

    func installMicrophoneTap(
        bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock
    ) {
        lock.withLock {
            precondition(!isTapped, "AVAudioEngine traps on a second tap on the same bus")
            isTapped = true
            tappedRates.append(format.sampleRate)
        }
    }

    func removeMicrophoneTap() {
        lock.withLock { isTapped = false }
    }

    func startEngine() throws {
        try lock.withLock {
            if _failsToStart { throw Failure() }
            isRunning = true
            starts += 1
        }
    }

    func stopEngine() {
        lock.withLock { isRunning = false }
    }
}

/// Collects the errors a tap reports.
private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [any Error] = []

    var count: Int { lock.withLock { errors.count } }

    func append(_ error: any Error) {
        lock.withLock { errors.append(error) }
    }
}

@Suite("Microphone tap")
struct MicrophoneTapTests {
    private let center = NotificationCenter()

    private func makeTap(_ engine: FakeTapEngine, failures: Failures) -> MicrophoneTap {
        MicrophoneTap(
            engine: engine, bufferSize: 1024, notificationCenter: center, block: { _, _ in },
            onFailure: { failures.append($0) })
    }

    private func changeConfiguration(of engine: FakeTapEngine, tap: MicrophoneTap) {
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        tap.restarts.waitUntilAllOperationsAreFinished()
    }

    @Test("taps the new format and starts again when the device changes")
    func restartsAfterDeviceChange() throws {
        let engine = FakeTapEngine(sampleRate: 48_000)
        let failures = Failures()
        let tap = makeTap(engine, failures: failures)
        try tap.start()
        #expect(engine.isRunning)

        engine.switchDevice(sampleRate: 24_000)
        changeConfiguration(of: engine, tap: tap)
        #expect(engine.tappedRates == [48_000, 24_000])
        #expect(engine.isTapped)
        #expect(engine.isRunning)
        #expect(engine.starts == 2)
        #expect(failures.count == 0)
    }

    @Test("reports a restart that fails and leaves the microphone off")
    func reportsFailedRestart() throws {
        let engine = FakeTapEngine(sampleRate: 48_000)
        let failures = Failures()
        let tap = makeTap(engine, failures: failures)
        try tap.start()

        engine.switchDevice(sampleRate: 16_000, failsToStart: true)
        changeConfiguration(of: engine, tap: tap)
        #expect(failures.count == 1)
        #expect(!engine.isTapped)
        #expect(!engine.isRunning)

        // Later changes are ignored; the owner decides what happens next.
        engine.switchDevice(sampleRate: 48_000)
        changeConfiguration(of: engine, tap: tap)
        #expect(failures.count == 1)
        #expect(!engine.isTapped)
        tap.stop()
    }

    @Test("reports a device without a usable format")
    func reportsMissingMicrophone() throws {
        let engine = FakeTapEngine(sampleRate: 48_000)
        let failures = Failures()
        let tap = makeTap(engine, failures: failures)
        try tap.start()

        engine.switchDevice(sampleRate: 0)
        changeConfiguration(of: engine, tap: tap)
        #expect(failures.count == 1)
        #expect(!engine.isTapped)
    }

    @Test("removes the tap on stop even when the engine already stopped itself")
    func stopRemovesTap() throws {
        let engine = FakeTapEngine(sampleRate: 48_000)
        let failures = Failures()
        let tap = makeTap(engine, failures: failures)
        try tap.start()
        engine.switchDevice(sampleRate: 48_000)
        #expect(!engine.isRunning)

        tap.stop()
        #expect(!engine.isTapped)
        // A change after stopping doesn't open the microphone again.
        changeConfiguration(of: engine, tap: tap)
        #expect(!engine.isTapped)
        #expect(engine.starts == 1)
        #expect(failures.count == 0)
    }

    @Test("ignores other engines' changes")
    func ignoresOtherEngines() throws {
        let engine = FakeTapEngine(sampleRate: 48_000)
        let other = FakeTapEngine(sampleRate: 48_000)
        let tap = makeTap(engine, failures: Failures())
        try tap.start()
        changeConfiguration(of: other, tap: tap)
        #expect(engine.starts == 1)
        tap.stop()
    }

    @Test("doesn't start without a microphone, and removes the tap when the engine fails")
    func startFailures() {
        let silent = FakeTapEngine(sampleRate: 0)
        #expect(throws: DictationError.unavailable) {
            try makeTap(silent, failures: Failures()).start()
        }
        #expect(silent.tappedRates.isEmpty)

        let broken = FakeTapEngine(sampleRate: 48_000)
        broken.switchDevice(sampleRate: 48_000, failsToStart: true)
        #expect(throws: FakeTapEngine.Failure.self) {
            try makeTap(broken, failures: Failures()).start()
        }
        #expect(!broken.isTapped)
    }

    @Test("dictation keeps recording at the same rate when the microphone's format changes")
    func recorderFollowsFormat() throws {
        let made = PCMRecorder(sampleRate: 16_000, onLevel: { _ in })
        let recorder = try #require(made)
        recorder.append(try buffer(seconds: 1, sampleRate: 48_000))
        recorder.append(try buffer(seconds: 1, sampleRate: 24_000))
        let samples = recorder.takeSamples()
        // Two seconds at 16 kHz, give or take the converters' latency.
        #expect(abs(samples.count - 32_000) < 1_000)
    }

    private func buffer(seconds: Double, sampleRate: Double) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: FakeTapEngine.format(sampleRate), frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = sin(Float(index) * 2 * .pi * 440 / Float(sampleRate)) * 0.5
        }
        return buffer
    }
}
