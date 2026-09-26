import AVFoundation
import Foundation

/// Converts between float samples and the 16-bit PCM the realtime voice services speak.
///
/// Realtime services exchange raw mono 16-bit little-endian PCM: OpenAI at 24 kHz in both
/// directions, Gemini at 16 kHz in and 24 kHz out.
public enum RealtimePCM {
    /// Bytes per sample of 16-bit PCM.
    public static let bytesPerSample = 2

    /// Encodes mono samples from -1 to 1 as 16-bit little-endian PCM, clamping louder ones.
    public static func encode(_ samples: [Float]) -> Data {
        var bytes = [UInt8](repeating: 0, count: samples.count * bytesPerSample)
        for (index, sample) in samples.enumerated() {
            let clamped = max(-1, min(1, sample.isFinite ? sample : 0))
            let value = UInt16(bitPattern: Int16((clamped * Float(Int16.max)).rounded()))
            bytes[index * 2] = UInt8(value & 0xFF)
            bytes[index * 2 + 1] = UInt8(value >> 8)
        }
        return Data(bytes)
    }

    /// Decodes 16-bit little-endian PCM into samples from -1 to 1. A trailing odd byte is
    /// ignored.
    public static func decode(_ data: Data) -> [Float] {
        WAVEncoder.samples(fromPCM16: data)
    }

    /// How long `byteCount` bytes of mono 16-bit PCM last at `sampleRate`.
    public static func duration(ofBytes byteCount: Int, sampleRate: Int) -> TimeInterval {
        Double(byteCount / bytesPerSample) / Double(max(1, sampleRate))
    }
}

/// Resamples mono audio with `AVAudioConverter`.
///
/// One resampler handles one continuous stream: it keeps the converter's filter state between
/// calls to ``process(_:)``, so consecutive chunks join without clicks. The converter holds
/// back a few milliseconds while it waits for more input; ``finish()`` returns them. Use one
/// instance from one thread at a time.
public final class RealtimeResampler {
    public let inputSampleRate: Int
    public let outputSampleRate: Int
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    /// Returns `nil` when either rate is not positive or Core Audio cannot convert them.
    public init?(from inputSampleRate: Int, to outputSampleRate: Int) {
        guard inputSampleRate > 0, outputSampleRate > 0,
            let inputFormat = Self.monoFormat(inputSampleRate),
            let outputFormat = Self.monoFormat(outputSampleRate)
        else { return nil }
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        if inputSampleRate == outputSampleRate {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                return nil
            }
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            self.converter = converter
        }
    }

    /// Resamples the next piece of the stream.
    public func process(_ samples: [Float]) -> [Float] {
        guard let converter else { return samples }
        guard !samples.isEmpty, let buffer = Self.buffer(samples, format: inputFormat) else {
            return []
        }
        return converter.convertBuffer(buffer, to: outputFormat).map(Self.samples) ?? []
    }

    /// Ends the stream and returns the samples the converter still held.
    public func finish() -> [Float] {
        guard let converter else { return [] }
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)
        else { return [] }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        converter.reset()
        guard status != .error, error == nil else { return [] }
        return Self.samples(output)
    }

    /// Resamples a whole clip at once.
    public static func resample(
        _ samples: [Float], from inputRate: Int, to outputRate: Int
    )
        -> [Float]
    {
        guard let resampler = RealtimeResampler(from: inputRate, to: outputRate) else {
            return []
        }
        return resampler.process(samples) + resampler.finish()
    }

    static func monoFormat(_ sampleRate: Int) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1,
            interleaved: false)
    }

    static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        return buffer
    }

    static func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

/// Cuts a stream of samples into PCM16 frames of equal length, ready to send.
///
/// Realtime services work best with frames of 20 to 40 ms: small enough for low latency,
/// large enough not to flood the socket with messages.
public struct RealtimeAudioFramer: Sendable {
    public let sampleRate: Int
    /// Samples per frame.
    public let frameLength: Int
    private var pending: [Float] = []

    public init(sampleRate: Int, frameDuration: TimeInterval = 0.04) {
        self.sampleRate = sampleRate
        frameLength = max(1, Int((Double(sampleRate) * frameDuration).rounded()))
    }

    /// Adds samples and returns every complete frame as PCM16.
    public mutating func append(_ samples: [Float]) -> [Data] {
        pending.append(contentsOf: samples)
        var frames: [Data] = []
        var start = 0
        while pending.count - start >= frameLength {
            frames.append(RealtimePCM.encode(Array(pending[start..<(start + frameLength)])))
            start += frameLength
        }
        pending.removeFirst(start)
        return frames
    }

    /// Returns the samples of an unfinished frame, or `nil` when there are none.
    public mutating func flush() -> Data? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return RealtimePCM.encode(pending)
    }
}

/// Turns microphone buffers in any format into PCM16 frames at a service's input rate.
///
/// Create it outside main-actor code and call it from the input tap: it mixes channels down,
/// resamples with `AVAudioConverter` and frames the result with ``RealtimeAudioFramer``.
public final class RealtimeMicrophoneEncoder {
    public let outputSampleRate: Int
    private var framer: RealtimeAudioFramer
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let outputFormat: AVAudioFormat?

    public init(outputSampleRate: Int, frameDuration: TimeInterval = 0.04) {
        self.outputSampleRate = outputSampleRate
        framer = RealtimeAudioFramer(sampleRate: outputSampleRate, frameDuration: frameDuration)
        outputFormat = RealtimeResampler.monoFormat(outputSampleRate)
    }

    /// Converts one tap buffer and returns the frames it completes.
    public func encode(_ buffer: AVAudioPCMBuffer) -> [Data] {
        guard let outputFormat, buffer.frameLength > 0 else { return [] }
        if converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converterInput = buffer.format
        }
        guard let converted = converter?.convertBuffer(buffer, to: outputFormat) else {
            return []
        }
        return framer.append(RealtimeResampler.samples(converted))
    }

    /// Returns what is left of the last frame, when the microphone stops.
    public func flush() -> Data? {
        framer.flush()
    }
}

/// A queue for the model's speech that tolerates network jitter.
///
/// Audio arrives in bursts; playback pulls at a steady rate. The buffer waits for
/// ``prebufferDuration`` of audio before it starts, and again after running dry in the middle
/// of a response (an underrun), so short gaps in the network don't become stutters. Once the
/// response's last chunk arrived (``finishResponse()``), it plays what is left without waiting.
///
/// It counts the samples actually played, which is what a barge-in must report: OpenAI
/// truncates the assistant's message to what the user heard (``interrupt()``).
///
/// This is a value type with no locking. The app hosts the audio engine and wraps it in a lock
/// shared by the network side (``enqueue(_:)``) and the render callback (``render(into:count:)``).
public struct RealtimePlaybackBuffer: Sendable {
    public let sampleRate: Int
    /// How much audio to collect before playback starts or resumes.
    public let prebufferDuration: TimeInterval
    private var queue: [Float] = []
    private var readIndex = 0
    private var responseFinished = false
    /// Whether samples are flowing (not waiting to fill up).
    public private(set) var isPlaying = false
    /// Samples of the current response that were played.
    public private(set) var playedSamples = 0
    /// How often playback ran dry before the response ended.
    public private(set) var underruns = 0

    public init(sampleRate: Int, prebufferDuration: TimeInterval = 0.08) {
        self.sampleRate = sampleRate
        self.prebufferDuration = prebufferDuration
    }

    /// Samples waiting to be played.
    public var bufferedSamples: Int { queue.count - readIndex }

    /// Seconds of audio waiting to be played.
    public var bufferedDuration: TimeInterval {
        Double(bufferedSamples) / Double(max(1, sampleRate))
    }

    /// Milliseconds of the current response that were played.
    public var playedMilliseconds: Int { playedSamples * 1000 / max(1, sampleRate) }

    /// Whether nothing is queued or playing.
    public var isIdle: Bool { bufferedSamples == 0 && !isPlaying }

    /// Adds samples from -1 to 1.
    public mutating func enqueue(_ samples: [Float]) {
        queue.append(contentsOf: samples)
    }

    /// Adds a chunk of 16-bit PCM, as the services send it.
    public mutating func enqueuePCM16(_ data: Data) {
        enqueue(RealtimePCM.decode(data))
    }

    /// Marks that the response's audio is complete, so the rest plays without prebuffering.
    public mutating func finishResponse() {
        responseFinished = true
    }

    /// Starts counting a new response: resets ``playedSamples`` and the end marker.
    public mutating func startResponse() {
        playedSamples = 0
        responseFinished = false
    }

    /// Stops at once for a barge-in: drops queued audio and returns the milliseconds of the
    /// response the user heard.
    @discardableResult
    public mutating func interrupt() -> Int {
        let heard = playedMilliseconds
        queue.removeAll(keepingCapacity: true)
        readIndex = 0
        isPlaying = false
        responseFinished = false
        playedSamples = 0
        return heard
    }

    /// Fills `count` samples at `output` for the audio engine, with silence where no audio is
    /// ready. Returns how many real samples were written.
    @discardableResult
    public mutating func render(into output: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let prebuffer = Int(prebufferDuration * Double(sampleRate))
        if !isPlaying {
            if bufferedSamples > 0, bufferedSamples >= prebuffer || responseFinished {
                isPlaying = true
            } else {
                output.update(repeating: 0, count: count)
                return 0
            }
        }
        let available = min(count, bufferedSamples)
        queue.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                output.update(from: base + readIndex, count: available)
            }
        }
        if available < count {
            (output + available).update(repeating: 0, count: count - available)
            isPlaying = false
            if !responseFinished { underruns += 1 }
        }
        readIndex += available
        playedSamples += available
        compact()
        return available
    }

    /// Returns the next `count` samples, padded with silence.
    public mutating func read(_ count: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: max(0, count))
        samples.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { _ = render(into: base, count: buffer.count) }
        }
        return samples
    }

    private mutating func compact() {
        if readIndex == queue.count {
            queue.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex > 48_000, readIndex * 2 > queue.count {
            queue.removeFirst(readIndex)
            readIndex = 0
        }
    }
}

/// How much audio and text a realtime session exchanged, for the privacy log and cost
/// estimates.
public struct RealtimeUsage: Sendable, Equatable {
    /// Seconds of microphone audio sent to the service. This audio left the Mac.
    public var inputAudioSeconds: Double = 0
    /// Seconds of speech the service sent back.
    public var outputAudioSeconds: Double = 0
    /// Characters of text sent: the instructions and every function result (Momo's answers).
    public var textCharactersSent = 0
    /// Seconds from ready to closed, or to now while the session runs.
    public var sessionSeconds: Double = 0

    public init() {}

    /// Billed audio in seconds, a rough cost estimate: both directions, since the services
    /// charge for input and output audio.
    public var billedAudioSeconds: Double { inputAudioSeconds + outputAudioSeconds }
}

/// What the user must be told before a cloud realtime session starts.
public enum RealtimeVoicePrivacy {
    /// English text for the consent prompt; the app shows a localized version.
    public static let notice =
        "Live voice with a cloud model streams your microphone audio to the provider while "
        + "the conversation is open, and sends Momo's answers there to be spoken. The audio "
        + "leaves your Mac and uses your own API key."
}
