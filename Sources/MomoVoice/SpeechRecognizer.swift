import AVFoundation
import Foundation
import Speech

/// Why dictation could not start.
public enum DictationError: LocalizedError, Equatable {
    case microphoneDenied
    case speechRecognitionDenied
    case unsupportedLanguage(String)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Momo needs microphone access. Allow it in System Settings → Privacy & Security → Microphone."
        case .speechRecognitionDenied:
            "Momo needs speech recognition access. Allow it in System Settings → Privacy & Security → Speech Recognition."
        case .unsupportedLanguage(let language):
            "Speech recognition does not support \(language) on this Mac."
        case .unavailable:
            "Speech recognition is not available right now."
        }
    }
}

/// Turns speech into text, on the device whenever the language allows it.
///
/// Call ``start(locale:)``; partial transcripts arrive through ``onPartial``, and the final
/// one through ``onFinal`` after the user pauses or ``stop()`` is called.
@MainActor
public final class SpeechRecognizer {
    public var onPartial: ((String) -> Void)?
    public var onFinal: ((String) -> Void)?
    /// Input level from 0 to 1, about 20 times a second.
    public var onLevel: ((Double) -> Void)?
    /// How long a pause ends the utterance.
    public var silenceTimeout: Duration = .seconds(1.6)
    /// Keep listening through pauses (used by the wake word listener).
    public var isContinuous = false

    public private(set) var isListening = false
    private var transcript = ""
    private let audioEngine = AVAudioEngine()
    private var feed: AudioFeed?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?

    public init() {}

    /// Asks for microphone and speech recognition permission if needed.
    public nonisolated static func requestPermissions() async throws {
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphone else { throw DictationError.microphoneDenied }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw DictationError.speechRecognitionDenied }
    }

    /// Starts listening in `locale`'s language.
    public func start(locale: Locale = .current) async throws {
        stop(deliver: false)
        try await Self.requestPermissions()
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            throw DictationError.unsupportedLanguage(locale.identifier)
        }
        guard recognizer.isAvailable else { throw DictationError.unavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        let feed = AudioFeed(request: request)
        self.feed = feed

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        let levels = LevelReporter { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        input.installTap(
            onBus: 0, bufferSize: 1024, format: format,
            block: Self.makeTap(feed: feed, levels: levels))
        audioEngine.prepare()
        try audioEngine.start()
        transcript = ""
        isListening = true

        task = recognizer.recognitionTask(
            with: request,
            resultHandler: Self.makeResultHandler { [weak self] text, isFinal, failed in
                Task { @MainActor in
                    self?.handle(text: text, isFinal: isFinal, failed: failed)
                }
            })
    }

    // These callbacks run on audio and recognition threads, so they must not inherit the
    // main actor isolation of this class.

    private nonisolated static func makeTap(
        feed: AudioFeed, levels: LevelReporter
    )
        -> AVAudioNodeTapBlock
    {
        { buffer, _ in
            feed.append(buffer)
            levels.report(buffer)
        }
    }

    private nonisolated static func makeResultHandler(
        _ handle: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            handle(
                result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    /// Stops listening. With `deliver`, the transcript so far is sent to ``onFinal``.
    public func stop(deliver: Bool = true) {
        guard isListening || task != nil else { return }
        silenceTimer?.cancel()
        silenceTimer = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        feed?.request.endAudio()
        task?.cancel()
        task = nil
        feed = nil
        let wasListening = isListening
        isListening = false
        onLevel?(0)
        if deliver, wasListening {
            onFinal?(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        guard isListening else { return }
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            onPartial?(text)
            if !isContinuous { restartSilenceTimer() }
        }
        if isFinal || failed {
            stop(deliver: true)
        }
    }

    private func restartSilenceTimer() {
        silenceTimer?.cancel()
        let timeout = silenceTimeout
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.stop(deliver: true)
        }
    }
}

/// Passes audio buffers from the audio thread to the recognition request, which is safe to
/// append to from any thread.
private final class AudioFeed: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }
}

/// Measures the input level and reports it at most every 50 ms.
private final class LevelReporter: @unchecked Sendable {
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
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        // Map roughly -50 dB…-10 dB to 0…1.
        let decibels = 20 * log10(max(rms, 0.000_01))
        callback(Double(min(1, max(0, (decibels + 50) / 40))))
    }
}
