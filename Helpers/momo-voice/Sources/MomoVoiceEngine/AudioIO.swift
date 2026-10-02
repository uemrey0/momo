@preconcurrency import AVFoundation
import Foundation
import MomoVoiceCore

/// The microphone and the speaker, in one `AVAudioEngine` with Apple's voice processing.
///
/// Voice processing I/O cancels the engine's own playback from the microphone signal, so
/// Momo does not hear itself. That only works when playback goes through the same engine,
/// which is why speech is rendered to samples and played here. Captured audio is delivered
/// as 16 kHz mono samples.
///
/// A session that only listens opens just the microphone, without voice processing; one that
/// only speaks opens just the speaker, and never touches the input node, so the microphone
/// stays closed and macOS asks for no permission.
///
/// When the audio devices change (AirPods switching to their call profile, a new default
/// microphone), the engine stops itself; it is started again with the new input format, and
/// ``onFailure`` is called when that fails.
///
/// Thread safety: `start`, `stop` and `stopPlayback` are called from one queue at a time;
/// `schedule` may be called from any thread. Audio callbacks never touch actor state. Device
/// changes are handled on their own queue, under `deviceLock`.
final class AudioIO: @unchecked Sendable {
    /// The sample rate captured audio is delivered at.
    static let captureSampleRate = 16_000.0
    /// Frames per scheduled playback buffer: 50 ms, the rate `mouth` levels are reported at.
    static let playbackSliceFrames: AVAudioFrameCount = 2_400

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat: AVAudioFormat
    private let lock = NSLock()
    /// Guards the devices: start, stop and restarts after a device change.
    private let deviceLock = NSLock()
    private let restarts: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "momo-voice.audio.restarts"
        return queue
    }()
    private var configurationObserver: (any NSObjectProtocol)?
    /// Where captured audio goes, kept to tap the microphone again after a device change.
    private var capture: (@Sendable ([Float]) -> Void)?
    private var generation = 0
    private var isRunning = false
    /// Whether the input node is in use, so `stop` knows what to release.
    private var capturesInput = false
    /// Whether the player is attached, so `stop` knows what to release.
    private var playsOutput = false
    /// Scheduled slices that have not played yet.
    private var outstandingSlices = 0
    /// Start callbacks of clips queued behind others, in order.
    private var waitingStarts: [@Sendable () -> Void] = []

    /// Whether echo cancellation is active.
    private(set) var isEchoCancelling = false
    /// Called when the devices can't be opened again after they changed. The audio has
    /// stopped then. Set before starting.
    var onFailure: (@Sendable (any Error) -> Void)?

    init() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            preconditionFailure("48 kHz mono is always a valid format")
        }
        playbackFormat = format
    }

    /// Opens the devices and starts delivering microphone audio to `capture`.
    ///
    /// - Parameters:
    ///   - playsOutput: Whether Momo also speaks, which opens the speaker and turns on echo
    ///     cancellation. Without it only the microphone opens.
    ///   - capture: Receives 16 kHz mono samples on the audio thread.
    func start(playsOutput: Bool = true, capture: @escaping @Sendable ([Float]) -> Void) throws {
        try deviceLock.withLock {
            try startLocked(playsOutput: playsOutput, capture: capture)
        }
        observeConfigurationChanges()
    }

    private func startLocked(
        playsOutput: Bool, capture: @escaping @Sendable ([Float]) -> Void
    ) throws {
        let input: AVAudioInputNode
        if playsOutput {
            // The output side must exist before voice processing is enabled, or the output
            // unit ends up with no channels and the engine fails to start (-10875).
            _ = engine.mainMixerNode
            _ = engine.outputNode
            input = engine.inputNode
            enableVoiceProcessing(on: input)
            attachPlayer()
        } else {
            input = engine.inputNode
        }

        let inputFormat: AVAudioFormat
        do {
            inputFormat = try tapMicrophone(capture)
        } catch {
            detachPlayer()
            throw error
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            capturesInput = false
            detachPlayer()
            throw error
        }
        if playsOutput { player.play() }
        self.capture = capture
        isRunning = true
        Log.info(
            "Audio running: input \(Int(inputFormat.sampleRate)) Hz × \(inputFormat.channelCount), output \(playsOutput ? "on" : "off"), echo cancellation \(isEchoCancelling ? "on" : "off")"
        )
    }

    /// Installs the microphone tap in the input's current format, which follows the device.
    private func tapMicrophone(
        _ capture: @escaping @Sendable ([Float]) -> Void
    ) throws
        -> AVAudioFormat
    {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoiceEngineError.noMicrophone
        }
        let converter = try CaptureConverter(inputFormat: inputFormat, deliver: capture)
        input.installTap(
            onBus: 0, bufferSize: 1_024, format: inputFormat, block: converter.makeTapBlock())
        capturesInput = true
        return inputFormat
    }

    /// Opens only the speaker, for a session that speaks without listening. The input node
    /// is never created, so the microphone stays closed.
    func startOutputOnly() throws {
        try deviceLock.withLock {
            _ = engine.mainMixerNode
            _ = engine.outputNode
            attachPlayer()
            engine.prepare()
            do {
                try engine.start()
            } catch {
                detachPlayer()
                throw error
            }
            player.play()
            isRunning = true
        }
        observeConfigurationChanges()
        Log.info("Audio running: output only")
    }

    private func enableVoiceProcessing(on input: AVAudioInputNode) {
        do {
            // MOMO_VOICE_ECHO_CANCELLATION=0 turns it off, for diagnosing audio problems.
            let wanted = ProcessInfo.processInfo.environment["MOMO_VOICE_ECHO_CANCELLATION"] != "0"
            try input.setVoiceProcessingEnabled(wanted)
            guard wanted else { throw VoiceEngineError.echoCancellationDisabled }
            isEchoCancelling = true
            // Voice processing ducks other apps' audio by default; keep that to a minimum.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: true, duckingLevel: .min)
        } catch {
            isEchoCancelling = false
            Log.error("Voice processing is unavailable, so there is no echo cancellation: \(error)")
        }
    }

    private func attachPlayer() {
        guard !playsOutput else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        playsOutput = true
    }

    private func detachPlayer() {
        guard playsOutput else { return }
        engine.detach(player)
        playsOutput = false
    }

    /// Stops playback and releases the devices.
    func stop() {
        stopObservingConfigurationChanges()
        deviceLock.withLock {
            guard isRunning else { return }
            isRunning = false
            if playsOutput { stopPlayback() }
            release()
        }
    }

    /// Removes the tap and stops the engine, whether or not it is still running.
    private func release() {
        if capturesInput {
            engine.inputNode.removeTap(onBus: 0)
            capturesInput = false
        }
        engine.stop()
        detachPlayer()
        capture = nil
    }

    // MARK: Device changes

    private func observeConfigurationChanges() {
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: restarts
        ) { [weak self] _ in self?.configurationChanged() }
        deviceLock.withLock { configurationObserver = observer }
    }

    private func stopObservingConfigurationChanges() {
        let observer = deviceLock.withLock {
            defer { configurationObserver = nil }
            return configurationObserver
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The audio devices changed and the engine stopped: tap the microphone in its new format
    /// and start again. What was playing is cut short.
    private func configurationChanged() {
        let failure: (any Error)? = deviceLock.withLock {
            guard isRunning else { return nil }
            Log.info("The audio devices changed; restarting the audio")
            // Stopping the player flushes what it had scheduled, so its completions still run
            // and the speaker doesn't wait for audio that will never play.
            if playsOutput { player.stop() }
            if capturesInput {
                engine.inputNode.removeTap(onBus: 0)
                capturesInput = false
            }
            engine.stop()
            do {
                var inputDescription = "none"
                if let capture {
                    let format = try tapMicrophone(capture)
                    inputDescription = "\(Int(format.sampleRate)) Hz × \(format.channelCount)"
                }
                engine.prepare()
                try engine.start()
                if playsOutput { player.play() }
                Log.info("Audio running again: input \(inputDescription)")
                return nil
            } catch {
                isRunning = false
                release()
                return error
            }
        }
        guard let failure else { return }
        stopObservingConfigurationChanges()
        Log.error("The audio could not restart after the devices changed: \(failure)")
        onFailure?(failure)
    }

    /// Stops playback at once and drops scheduled audio. Completion handlers of dropped
    /// audio do not run.
    func stopPlayback() {
        lock.withLock {
            generation += 1
            outstandingSlices = 0
            waitingStarts.removeAll()
        }
        // A player that is detached or whose engine stopped must not be restarted.
        guard playsOutput, engine.isRunning else { return }
        player.stop()
        player.play()
    }

    /// Plays samples after what is already scheduled.
    ///
    /// - Parameters:
    ///   - samples: Mono samples at `sampleRate`.
    ///   - sliceStarted: Called with the level of each 50 ms slice as it starts playing.
    ///   - finished: Called when the last slice was played.
    func schedule(
        _ samples: [Float], sampleRate: Double,
        sliceStarted: @escaping @Sendable (Double) -> Void,
        finished: @escaping @Sendable () -> Void
    ) {
        let expected = lock.withLock { generation }
        guard
            let buffer = Resampler.buffer(from: samples, sampleRate: sampleRate, to: playbackFormat)
        else {
            finished()
            return
        }
        let slices = Self.slices(of: buffer, format: playbackFormat)
        guard !slices.isEmpty else {
            finished()
            return
        }
        let levels = slices.map { slice in
            AudioLevel.normalized(
                rms: AudioLevel.rms(
                    UnsafeBufferPointer(
                        start: slice.floatChannelData?[0], count: Int(slice.frameLength))))
        }
        let isCurrent: @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.lock.withLock { self.generation == expected }
        }
        // The first slice starts when everything scheduled before it has played; each
        // slice's completion then marks the start of the next one.
        let startNow: Bool = lock.withLock {
            guard generation == expected else { return false }
            if outstandingSlices == 0 { return true }
            waitingStarts.append { sliceStarted(levels[0]) }
            return false
        }
        guard isCurrent() else { return }
        if startNow { sliceStarted(levels[0]) }
        lock.withLock { outstandingSlices += slices.count }
        for (index, slice) in slices.enumerated() {
            let isLast = index == slices.count - 1
            let nextLevel = isLast ? nil : levels[index + 1]
            player.scheduleBuffer(slice, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard isCurrent() else { return }
                self?.slicePlayed()
                if let nextLevel {
                    sliceStarted(nextLevel)
                } else {
                    finished()
                    self?.clipFinished()
                }
            }
        }
    }

    private func slicePlayed() {
        lock.withLock { outstandingSlices = max(0, outstandingSlices - 1) }
    }

    /// The last slice of a clip played: the next scheduled clip starts now.
    private func clipFinished() {
        let next: (@Sendable () -> Void)? = lock.withLock {
            waitingStarts.isEmpty ? nil : waitingStarts.removeFirst()
        }
        next?()
    }

    private static func slices(
        of buffer: AVAudioPCMBuffer, format: AVAudioFormat
    ) -> [AVAudioPCMBuffer] {
        guard let source = buffer.floatChannelData?[0] else { return [] }
        var slices: [AVAudioPCMBuffer] = []
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            let count = min(playbackSliceFrames, buffer.frameLength - offset)
            guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
                let target = slice.floatChannelData?[0]
            else { break }
            target.update(from: source.advanced(by: Int(offset)), count: Int(count))
            slice.frameLength = count
            slices.append(slice)
            offset += count
        }
        return slices
    }
}

/// Turns microphone buffers into 16 kHz mono samples. Runs on the audio engine's tap thread.
private final class CaptureConverter: @unchecked Sendable {
    private let monoFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let deliver: @Sendable ([Float]) -> Void

    init(inputFormat: AVAudioFormat, deliver: @escaping @Sendable ([Float]) -> Void) throws {
        guard
            let mono = AVAudioFormat(
                standardFormatWithSampleRate: inputFormat.sampleRate, channels: 1),
            let output = AVAudioFormat(
                standardFormatWithSampleRate: AudioIO.captureSampleRate, channels: 1),
            let converter = AVAudioConverter(from: mono, to: output)
        else { throw VoiceEngineError.noMicrophone }
        self.monoFormat = mono
        self.outputFormat = output
        self.converter = converter
        self.deliver = deliver
    }

    /// The tap block. It is made here, outside any actor, so it carries no actor isolation
    /// that the audio thread would violate.
    func makeTapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in handle(buffer) }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0,
            let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
            let target = mono.floatChannelData?[0]
        else { return }
        // Voice processing puts the processed microphone on the first channel.
        target.update(from: channels[0], count: Int(buffer.frameLength))
        mono.frameLength = buffer.frameLength

        let ratio = outputFormat.sampleRate / monoFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, let samples = output.floatChannelData?[0], output.frameLength > 0 else {
            return
        }
        deliver(Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength))))
    }
}

/// Converts synthesised speech to the playback format.
enum Resampler {
    static func buffer(
        from samples: [Float], sampleRate: Double, to format: AVAudioFormat
    )
        -> AVAudioPCMBuffer?
    {
        guard !samples.isEmpty, sampleRate > 0,
            let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let source = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let sourceData = source.floatChannelData?[0]
        else { return nil }
        sourceData.update(from: samples, count: samples.count)
        source.frameLength = AVAudioFrameCount(samples.count)
        if sampleRate == format.sampleRate { return source }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else { return nil }
        let capacity =
            AVAudioFrameCount(Double(samples.count) * format.sampleRate / sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        return error == nil ? output : nil
    }
}
