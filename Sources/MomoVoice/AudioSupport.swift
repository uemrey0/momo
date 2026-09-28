import AVFoundation
import Foundation

// Audio pieces shared by the engines that run in Momo's own process: cloud dictation, cloud
// voices, cloud realtime sessions and meeting capture. Momo's on-device voice models run in
// the `momo-voice` helper.

/// Why dictation could not start.
public enum DictationError: LocalizedError, Equatable {
    case microphoneDenied
    case unsupportedLanguage(String)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Momo needs microphone access. Allow it in System Settings → Privacy & Security → Microphone."
        case .unsupportedLanguage(let language):
            "Momo's voice models don't understand \(language) yet."
        case .unavailable:
            "Speech recognition is not available right now."
        }
    }
}

/// Why the live session's audio couldn't start.
public enum LiveAudioError: LocalizedError, Equatable {
    /// No microphone is connected, or it delivers no audio.
    case noMicrophone
    /// The audio engine refused to start, with its OSStatus code.
    case engineFailed(code: Int)

    public var errorDescription: String? {
        switch self {
        case .noMicrophone: "No microphone is available."
        case .engineFailed(let code): "The audio devices couldn't be opened (error \(code))."
        }
    }
}

extension OpenAISpeechRequest {
    /// The name shown in the privacy log.
    public var displayName: String { "OpenAI \(model) (\(voice))" }
}

/// Passes microphone audio from the audio thread to the current recognition session, as
/// mono buffers, keeping the last moment for barge-in.
final class LiveInputRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var target: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollFrames: AVAudioFrameCount = 0
    /// How much audio is kept for barge-in, in seconds.
    private let prerollSeconds = 0.5
    private var _levels: LevelReporter?

    var levels: LevelReporter? {
        get { lock.withLock { _levels } }
        set { lock.withLock { _levels = newValue } }
    }

    /// Sends audio to `target` from now on; with `withPreroll`, the kept audio first.
    func setTarget(_ target: (@Sendable (AVAudioPCMBuffer) -> Void)?, withPreroll: Bool) {
        lock.withLock {
            self.target = target
            if withPreroll, let target {
                for buffer in preroll { target(buffer) }
            }
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        guard let mono = Self.mono(buffer) else { return }
        lock.withLock {
            _levels?.report(mono)
            preroll.append(mono)
            prerollFrames += mono.frameLength
            let limit = AVAudioFrameCount(mono.format.sampleRate * prerollSeconds)
            while prerollFrames > limit, let first = preroll.first {
                prerollFrames -= first.frameLength
                preroll.removeFirst()
            }
            target?(mono)
        }
    }

    /// The first channel of `buffer` as a new mono float buffer. Voice processing can deliver
    /// several channels, and the tap's buffer is reused after the tap returns.
    static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, let source = buffer.floatChannelData?[0],
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                channels: 1, interleaved: false),
            let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
            let destination = copy.floatChannelData?[0]
        else { return nil }
        copy.frameLength = buffer.frameLength
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        for frame in 0..<Int(buffer.frameLength) {
            destination[frame] = source[frame * stride]
        }
        return copy
    }
}

/// Measures the input level and reports it at most every 50 ms.
final class LevelReporter: @unchecked Sendable {
    private let callback: @Sendable (Double) -> Void
    private var last = Date.distantPast
    private let lock = NSLock()

    init(_ callback: @escaping @Sendable (Double) -> Void) {
        self.callback = callback
    }

    func report(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(last) > 0.05 else {
            lock.unlock()
            return
        }
        last = now
        lock.unlock()
        callback(
            Self.level(of: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
    }

    /// The level of `samples` from 0 to 1, mapping roughly -50 dB…-10 dB.
    static func level(of samples: UnsafeBufferPointer<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = sqrt(sum / Float(samples.count))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return Double(min(1, max(0, (decibels + 50) / 40)))
    }
}
