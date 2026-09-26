import AVFoundation
import Foundation

/// The microphone and speaker of a cloud realtime conversation.
///
/// ``RealtimeConversation`` streams what the microphone hears to the session and plays the
/// model's speech. ``RealtimeAudioEngine`` is the real one; tests use a fake.
@MainActor
public protocol RealtimeAudioIO: AnyObject {
    /// Whether the model's speech is queued or playing.
    var isPlaying: Bool { get }
    /// The output level, 0...1, for moving Momo's mouth.
    var outputLevel: Double { get }
    /// The echo-cancelled microphone level, 0...1.
    var inputLevel: Double { get }

    /// Opens the microphone and the speaker. `microphone` receives mono PCM16 frames at
    /// `inputSampleRate` on an audio thread; ``play(_:)`` takes PCM16 at `outputSampleRate`.
    /// Throws when the microphone is not allowed or the audio devices can't run.
    func start(
        inputSampleRate: Int, outputSampleRate: Int,
        microphone: @escaping @Sendable (Data) -> Void
    ) async throws
    /// Closes the microphone and the speaker.
    func stop()
    /// Queues speech from the model.
    func play(_ pcm16: Data)
    /// A new response starts; what is played from now on counts for barge-in.
    func startResponse()
    /// The response's audio is complete; the rest plays without waiting for more.
    func finishResponse()
    /// Stops playback at once and drops what is queued. Returns the milliseconds of the
    /// current response the user heard, or `nil` when none of it played.
    func interruptPlayback() -> Int?
}

/// The real ``RealtimeAudioIO``: one `AVAudioEngine` with voice processing on the input node
/// (Apple's echo cancellation) and the model's speech on a source node of the same engine,
/// so the canceller has the reference and Momo doesn't hear itself.
///
/// Microphone buffers go through ``RealtimeMicrophoneEncoder`` on the tap's thread; speech is
/// queued in a lock-protected ``RealtimePlaybackBuffer`` that the source node pulls at the
/// session's output rate. When the audio devices change, the engine is built again.
@MainActor
public final class RealtimeAudioEngine: RealtimeAudioIO {
    private var engine: AVAudioEngine?
    private let playback: RealtimePlaybackHost
    private var microphone: RealtimeMicrophoneHost?
    private var configurationObserver: (any NSObjectProtocol)?
    private var rates: (input: Int, output: Int)?
    private var sink: (@Sendable (Data) -> Void)?

    public init() {
        playback = RealtimePlaybackHost(sampleRate: 24_000)
    }

    public var isPlaying: Bool { playback.isActive }
    public var outputLevel: Double { playback.level }
    public var inputLevel: Double { microphone?.level ?? 0 }

    public func start(
        inputSampleRate: Int, outputSampleRate: Int,
        microphone: @escaping @Sendable (Data) -> Void
    ) async throws {
        stop()
        guard await Self.microphoneAllowed() else { throw DictationError.microphoneDenied }
        rates = (inputSampleRate, outputSampleRate)
        sink = microphone
        try build()
    }

    public func stop() {
        tearDown()
        rates = nil
        sink = nil
    }

    public func play(_ pcm16: Data) {
        playback.enqueue(pcm16)
    }

    public func startResponse() {
        playback.startResponse()
    }

    public func finishResponse() {
        playback.finishResponse()
    }

    public func interruptPlayback() -> Int? {
        playback.interrupt()
    }

    // MARK: - Engine

    private func build() throws {
        guard let rates, let sink else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Echo cancellation: the model's voice, played by this engine, is removed from the
        // input.
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min)
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(rates.output), channels: 1,
                interleaved: false)
        else {
            try? input.setVoiceProcessingEnabled(false)
            throw DictationError.unavailable
        }
        playback.reset(sampleRate: rates.output)
        let source = AVAudioSourceNode(
            format: format, renderBlock: Self.makeRenderBlock(playback))
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            try? input.setVoiceProcessingEnabled(false)
            throw DictationError.unavailable
        }
        let microphone = Self.makeMicrophone(sampleRate: rates.input, sink: sink)
        input.installTap(
            onBus: 0, bufferSize: 1024, format: inputFormat,
            block: Self.makeInputTap(microphone))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? input.setVoiceProcessingEnabled(false)
            throw error
        }
        self.engine = engine
        self.microphone = microphone
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil,
            using: Self.makeConfigurationHandler { [weak self] in self?.configurationChanged() })
    }

    private func tearDown() {
        _ = playback.interrupt()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        self.engine = nil
        microphone = nil
    }

    /// The audio devices changed (headphones, a new default microphone): the engine
    /// stopped, so build it again. What was queued to play is dropped.
    private func configurationChanged() {
        guard engine != nil else { return }
        tearDown()
        try? build()
    }

    // Audio callbacks run on audio threads, so they must not inherit main actor isolation.

    private nonisolated static func microphoneAllowed() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private nonisolated static func makeMicrophone(
        sampleRate: Int, sink: @escaping @Sendable (Data) -> Void
    ) -> RealtimeMicrophoneHost {
        RealtimeMicrophoneHost(
            encoder: RealtimeMicrophoneEncoder(outputSampleRate: sampleRate), sink: sink)
    }

    private nonisolated static func makeInputTap(
        _ microphone: RealtimeMicrophoneHost
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in microphone.receive(buffer) }
    }

    private nonisolated static func makeRenderBlock(
        _ playback: RealtimePlaybackHost
    ) -> AVAudioSourceNodeRenderBlock {
        { isSilence, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let count = Int(frameCount)
            var written = 0
            for (index, buffer) in buffers.enumerated() {
                guard let data = buffer.mData else { continue }
                let output = data.assumingMemoryBound(to: Float.self)
                if index == 0 {
                    written = playback.render(into: output, count: count)
                } else if let first = buffers[0].mData {
                    output.update(from: first.assumingMemoryBound(to: Float.self), count: count)
                }
            }
            if written == 0 { isSilence.pointee = true }
            return noErr
        }
    }

    private nonisolated static func makeConfigurationHandler(
        _ handle: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable (Notification) -> Void {
        { _ in Task { @MainActor in handle() } }
    }
}

/// Turns microphone buffers into frames for the session, on the tap's thread.
final class RealtimeMicrophoneHost: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder: RealtimeMicrophoneEncoder
    private let sink: @Sendable (Data) -> Void
    private var _level = 0.0

    init(encoder: RealtimeMicrophoneEncoder, sink: @escaping @Sendable (Data) -> Void) {
        self.encoder = encoder
        self.sink = sink
    }

    var level: Double { lock.withLock { _level } }

    func receive(_ buffer: AVAudioPCMBuffer) {
        // Voice processing can deliver several channels; the first is the processed one.
        guard let mono = LiveInputRouter.mono(buffer), let samples = mono.floatChannelData?[0]
        else { return }
        let level = LevelReporter.level(
            of: UnsafeBufferPointer(start: samples, count: Int(mono.frameLength)))
        let frames = lock.withLock {
            _level = level
            return encoder.encode(mono)
        }
        for frame in frames { sink(frame) }
    }
}

/// A ``RealtimePlaybackBuffer`` shared by the network side and the render callback.
final class RealtimePlaybackHost: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: RealtimePlaybackBuffer
    private var _level = 0.0

    init(sampleRate: Int) {
        buffer = RealtimePlaybackBuffer(sampleRate: sampleRate)
    }

    /// Whether audio is queued or playing.
    var isActive: Bool { lock.withLock { !buffer.isIdle } }

    /// The level of what played last, 0...1.
    var level: Double { lock.withLock { buffer.isIdle ? 0 : _level } }

    func reset(sampleRate: Int) {
        lock.withLock {
            buffer = RealtimePlaybackBuffer(sampleRate: sampleRate)
            _level = 0
        }
    }

    func enqueue(_ pcm16: Data) {
        let samples = RealtimePCM.decode(pcm16)
        lock.withLock { buffer.enqueue(samples) }
    }

    func startResponse() {
        lock.withLock {
            // A response still playing keeps counting, so a barge-in reports what was heard.
            if buffer.isIdle { buffer.startResponse() }
        }
    }

    func finishResponse() {
        lock.withLock { buffer.finishResponse() }
    }

    /// Stops playback; the milliseconds heard, or `nil` when nothing played.
    func interrupt() -> Int? {
        lock.withLock {
            let wasActive = !buffer.isIdle
            let heard = buffer.interrupt()
            _level = 0
            return wasActive && heard > 0 ? heard : nil
        }
    }

    func render(into output: UnsafeMutablePointer<Float>, count: Int) -> Int {
        lock.withLock {
            let written = buffer.render(into: output, count: count)
            if written > 0 {
                _level = LevelReporter.level(of: UnsafeBufferPointer(start: output, count: written))
            }
            return written
        }
    }
}
