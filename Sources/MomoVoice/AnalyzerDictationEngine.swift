import AVFoundation
import Foundation
import Speech

/// Dictation with Apple's `SpeechAnalyzer` and its `SpeechTranscriber` module (macOS 26 and
/// later): on the device, faster and more accurate than Apple Speech, with volatile (live)
/// results that are replaced by final ones.
///
/// The speech model for a language is an Apple asset. When it is missing, ``start(locale:)``
/// downloads it through `AssetInventory` (reporting progress through ``onPreparing``) before
/// listening. Languages the module does not support make `start` throw
/// ``DictationError/unsupportedLanguage(_:)``, so the caller can fall back to Apple Speech.
@available(macOS 26, *)
@MainActor
public final class AnalyzerDictationEngine: DictationEngine {
    public var onPartial: ((String) -> Void)?
    public var onFinal: ((String) -> Void)?
    public var onLevel: ((Double) -> Void)?
    public var isContinuous = false
    /// Called while the language's speech model downloads, with progress from 0 to 1.
    public var onPreparing: ((Double) -> Void)?
    /// How long a pause ends the utterance.
    public var silenceTimeout: Duration = .seconds(1.4)

    public private(set) var isListening = false

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var silenceTimer: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""
    private var isStopping = false

    public init() {}

    /// Whether the transcriber can run on this Mac at all.
    public nonisolated static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    private var transcript: String {
        (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func start(locale: Locale) async throws {
        stop(deliver: false)
        try await SpeechRecognizer.requestPermissions()
        guard Self.isAvailable else { throw DictationError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw DictationError.unsupportedLanguage(locale.identifier)
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults],
            attributeOptions: [])
        try await Self.installAssets(for: transcriber, progress: onPreparing)

        let modules: [any SpeechModule] = [transcriber]
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        else { throw DictationError.unavailable }
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: format)
        self.analyzer = analyzer

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        let micInput = audioEngine.inputNode
        let micFormat = micInput.outputFormat(forBus: 0)
        guard
            let converter = AnalyzerFeed(
                from: micFormat, to: format, continuation: continuation,
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.onLevel?(level) }
                })
        else { throw DictationError.unavailable }
        micInput.installTap(
            onBus: 0, bufferSize: 1024, format: micFormat, block: Self.makeTap(feed: converter))
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            micInput.removeTap(onBus: 0)
            continuation.finish()
            input = nil
            self.analyzer = nil
            throw error
        }

        finalized = ""
        volatile = ""
        isStopping = false
        isListening = true
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handle(
                        text: String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {}
            self?.resultsEnded()
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            stop(deliver: false)
            throw error
        }
    }

    /// Downloads the language's speech model if it is not installed yet.
    private static func installAssets(
        for transcriber: SpeechTranscriber, progress: ((Double) -> Void)?
    ) async throws {
        guard
            let request = try await AssetInventory.assetInstallationRequest(supporting: [
                transcriber
            ])
        else { return }
        let report = ProgressRelay(progress)
        let observation = request.progress.observe(\.fractionCompleted) { value, _ in
            report.send(value.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    private nonisolated static func makeTap(feed: AnalyzerFeed) -> AVAudioNodeTapBlock {
        { buffer, _ in feed.append(buffer) }
    }

    public func stop(deliver: Bool) {
        silenceTimer?.cancel()
        silenceTimer = nil
        guard isListening, !isStopping else { return }
        isStopping = true
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        input?.finish()
        input = nil
        onLevel?(0)
        let analyzer = analyzer
        self.analyzer = nil
        guard deliver else {
            finish(deliver: false)
            Task { await analyzer?.cancelAndFinishNow() }
            return
        }
        // Let the analyzer turn volatile results into final ones, but never wait long.
        Task { [weak self] in
            let timeout = Task {
                try? await Task.sleep(for: .seconds(2))
                await analyzer?.cancelAndFinishNow()
            }
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            timeout.cancel()
            _ = await self?.results?.value
            self?.finish(deliver: true)
        }
    }

    private func handle(text: String, isFinal: Bool) {
        guard isListening else { return }
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
        let transcript = transcript
        guard !transcript.isEmpty else { return }
        onPartial?(transcript)
        if !isContinuous, !isStopping { restartSilenceTimer() }
    }

    private func resultsEnded() {
        // The analyzer stopped on its own (for example an error): deliver what we have.
        if isListening, !isStopping { stop(deliver: true) }
    }

    private func finish(deliver: Bool) {
        guard isListening else { return }
        isListening = false
        isStopping = false
        results?.cancel()
        results = nil
        if deliver { onFinal?(transcript) }
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

/// Forwards download progress to the main actor.
private final class ProgressRelay: Sendable {
    private let callback: @MainActor @Sendable (Double) -> Void

    @MainActor
    init(_ callback: ((Double) -> Void)?) {
        nonisolated(unsafe) let callback = callback
        self.callback = { callback?($0) }
    }

    func send(_ fraction: Double) {
        Task { @MainActor [callback] in callback(fraction) }
    }
}

/// Converts microphone buffers to the analyzer's format and passes them on, on the audio
/// thread.
@available(macOS 26, *)
private final class AnalyzerFeed: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let levels: LevelReporter

    init?(
        from input: AVAudioFormat, to format: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onLevel: @escaping @Sendable (Double) -> Void
    ) {
        guard input.sampleRate > 0 else { return nil }
        self.format = format
        self.continuation = continuation
        self.levels = LevelReporter(onLevel)
        if input == format {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: input, to: format) else { return nil }
            converter.primeMethod = .none
            self.converter = converter
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        levels.report(buffer)
        guard let converter else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        guard let output = converter.convertBuffer(buffer, to: format) else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }
}
