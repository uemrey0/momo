import AVFoundation
import Foundation

/// The parts of `AVAudioEngine` a ``MicrophoneTap`` uses, so tests can stand in for it.
protocol MicrophoneTapEngine: AnyObject {
    /// The microphone's format right now; it changes with the input device.
    var microphoneFormat: AVAudioFormat { get }
    func installMicrophoneTap(
        bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock)
    func removeMicrophoneTap()
    /// Prepares and starts the engine.
    func startEngine() throws
    func stopEngine()
}

extension AVAudioEngine: MicrophoneTapEngine {
    var microphoneFormat: AVAudioFormat { inputNode.outputFormat(forBus: 0) }

    func installMicrophoneTap(
        bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock
    ) {
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
    }

    func removeMicrophoneTap() {
        inputNode.removeTap(onBus: 0)
    }

    func startEngine() throws {
        prepare()
        try start()
    }

    func stopEngine() {
        stop()
    }
}

/// A tap on an engine's microphone that survives audio device changes.
///
/// When the input device changes (AirPods switching to their call profile, a new default
/// microphone), the engine posts `AVAudioEngineConfigurationChange` and stops. The tap is
/// then installed again in the new format and the engine restarted, so the same `block` keeps
/// receiving audio. When the restart fails, `onFailure` is called and the tap stays off.
///
/// `block` must cope with buffers changing format after a restart. Thread safety: every
/// method may be called from any thread; restarts run one at a time on ``restarts``, never
/// inside the thread that posted the notification.
final class MicrophoneTap: @unchecked Sendable {
    /// Where restarts run, one at a time.
    let restarts: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "momo.microphone-tap.restarts"
        return queue
    }()
    private let engine: any MicrophoneTapEngine
    private let bufferSize: AVAudioFrameCount
    private let block: AVAudioNodeTapBlock
    private let onFailure: @Sendable (any Error) -> Void
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var observer: (any NSObjectProtocol)?
    private var isActive = false

    init(
        engine: any MicrophoneTapEngine, bufferSize: AVAudioFrameCount,
        notificationCenter: NotificationCenter = .default,
        block: @escaping AVAudioNodeTapBlock,
        onFailure: @escaping @Sendable (any Error) -> Void
    ) {
        self.engine = engine
        self.bufferSize = bufferSize
        self.notificationCenter = notificationCenter
        self.block = block
        self.onFailure = onFailure
    }

    /// Installs the tap and starts the engine. Throws when there is no usable microphone or
    /// the engine can't start; the tap is removed again then.
    func start() throws {
        try lock.withLock {
            try run()
            isActive = true
            observer = notificationCenter.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: restarts
            ) { [weak self] _ in self?.configurationChanged() }
        }
    }

    /// Stops the engine and removes the tap, whether or not the engine is still running.
    func stop() {
        let observer = lock.withLock {
            isActive = false
            engine.stopEngine()
            engine.removeMicrophoneTap()
            return takeObserver()
        }
        if let observer { notificationCenter.removeObserver(observer) }
    }

    private func run() throws {
        let format = engine.microphoneFormat
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationError.unavailable
        }
        engine.installMicrophoneTap(bufferSize: bufferSize, format: format, block: block)
        do {
            try engine.startEngine()
        } catch {
            engine.removeMicrophoneTap()
            throw error
        }
    }

    /// The audio devices changed and the engine stopped: tap the new microphone format and
    /// start again.
    private func configurationChanged() {
        let failure: (error: any Error, observer: (any NSObjectProtocol)?)? = lock.withLock {
            guard isActive else { return nil }
            engine.stopEngine()
            engine.removeMicrophoneTap()
            do {
                try run()
                return nil
            } catch {
                isActive = false
                return (error, takeObserver())
            }
        }
        guard let failure else { return }
        if let observer = failure.observer { notificationCenter.removeObserver(observer) }
        onFailure(failure.error)
    }

    private func takeObserver() -> (any NSObjectProtocol)? {
        defer { observer = nil }
        return observer
    }
}
