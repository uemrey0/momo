import AVFoundation
import Foundation

/// Dictation through a cloud transcription service with the user's own key.
///
/// Records from the microphone, ends the utterance with a ``VoiceActivityDetector`` (about a
/// second of quiet after speech, or the maximum length), encodes the audio as WAV and sends
/// it to an ``AudioTranscriptionService``. Nothing is transcribed live, so ``onPartial`` only
/// fires once, with the result.
///
/// When the request fails, the recording is transcribed on this Mac with the `fallback`
/// service (Momo's voice models) instead, and ``onCloudFailure`` reports why, so the user's
/// words are never lost.
@MainActor
public final class CloudDictationEngine: DictationEngine {
    public var onPartial: ((String) -> Void)?
    public var onFinal: ((String) -> Void)?
    public var onLevel: ((Double) -> Void)?
    public var isContinuous = false
    /// Called when recording ends and the audio is being transcribed.
    public var onTranscribing: (() -> Void)?
    /// Called just before audio is uploaded, with the service name and the audio length in
    /// seconds, for the privacy log.
    public var onUpload: ((String, TimeInterval) -> Void)?
    /// Called when the cloud request failed and the on-device fallback was used.
    public var onCloudFailure: ((any Error) -> Void)?

    public private(set) var isListening = false
    /// The recording format sent to the service: 16 kHz mono is plenty for speech and keeps
    /// uploads small (about 32 KB a second).
    public static let sampleRate = 16_000

    private let service: any AudioTranscriptionService
    private let fallback: (any AudioTranscriptionService)?
    private var detector: VoiceActivityDetector
    private let audioEngine = AVAudioEngine()
    private var recorder: PCMRecorder?
    private var locale = Locale.current
    private var startDate = Date()
    private var transcription: Task<Void, Never>?

    /// - Parameters:
    ///   - service: Where the audio goes.
    ///   - fallback: Transcribes the recording on this Mac when `service` fails.
    ///   - detector: How utterances end. Its `endsOnSilence` follows ``isContinuous``.
    public init(
        service: any AudioTranscriptionService,
        fallback: (any AudioTranscriptionService)? = nil,
        detector: VoiceActivityDetector = VoiceActivityDetector()
    ) {
        self.service = service
        self.fallback = fallback
        self.detector = detector
    }

    public func start(locale: Locale) async throws {
        stop(deliver: false)
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphone else { throw DictationError.microphoneDenied }
        self.locale = locale

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
            let recorder = PCMRecorder(
                inputFormat: format, sampleRate: Double(Self.sampleRate),
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.heard(level: level) }
                })
        else { throw DictationError.unavailable }
        self.recorder = recorder
        input.installTap(
            onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(recorder: recorder))
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.recorder = nil
            throw error
        }
        detector.reset()
        detector.endsOnSilence = !isContinuous
        startDate = Date()
        isListening = true
    }

    private nonisolated static func makeTap(recorder: PCMRecorder) -> AVAudioNodeTapBlock {
        { buffer, _ in recorder.append(buffer) }
    }

    public func stop(deliver: Bool) {
        if !deliver {
            transcription?.cancel()
            transcription = nil
        }
        guard isListening else { return }
        isListening = false
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        onLevel?(0)
        let samples = recorder?.takeSamples() ?? []
        recorder = nil
        guard deliver else { return }
        guard detector.hasSpeech || isContinuous, !samples.isEmpty else {
            onFinal?("")
            return
        }
        transcribe(samples)
    }

    private func heard(level: Double) {
        guard isListening else { return }
        onLevel?(level)
        switch detector.process(level: level, at: Date().timeIntervalSince(startDate)) {
        case .endOfUtterance, .maximumDurationReached:
            stop(deliver: true)
        case .noSpeech:
            stop(deliver: false)
            onFinal?("")
        case .none, .speechStarted:
            break
        }
    }

    private func transcribe(_ samples: [Float]) {
        onTranscribing?()
        let clip = AudioClip.wav(samples: samples, sampleRate: Self.sampleRate)
        let options = TranscriptionOptions(language: locale.language.languageCode?.identifier)
        let service = service
        let fallback = fallback
        onUpload?(service.displayName, clip.duration ?? 0)
        transcription = Task { [weak self] in
            do {
                let transcript = try await service.transcribe(clip, options: options)
                guard !Task.isCancelled else { return }
                self?.deliver(transcript.text)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self?.onCloudFailure?(error)
                let text = (try? await fallback?.transcribe(clip, options: options))?.text ?? ""
                guard !Task.isCancelled else { return }
                self?.deliver(text)
            }
        }
    }

    private func deliver(_ text: String) {
        transcription = nil
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onPartial?(text) }
        onFinal?(text)
    }
}

/// Converts microphone buffers to mono Float samples at a fixed rate and keeps them, on the
/// audio thread.
final class PCMRecorder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let levels: LevelReporter
    private let lock = NSLock()
    private var samples: [Float] = []

    init?(
        inputFormat: AVAudioFormat, sampleRate: Double,
        onLevel: @escaping @Sendable (Double) -> Void
    ) {
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        self.converter = converter
        self.outputFormat = outputFormat
        self.levels = LevelReporter(onLevel)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        levels.report(buffer)
        guard let converted = converter.convertBuffer(buffer, to: outputFormat),
            let channel = converted.floatChannelData?[0]
        else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    /// Returns the recorded samples and forgets them.
    func takeSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples = []
        return result
    }
}
