import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Transcribes recorded clips on the Mac, so chunks of a long recording can go through the
/// same ``AudioTranscriptionService`` interface as the cloud services without leaving it.
///
/// Uses Apple's `SpeechAnalyzer` with the `SpeechTranscriber` module on macOS 26 and later
/// (downloading the language's model once), and Apple Speech (`SFSpeechRecognizer`, on the
/// device whenever the language allows it) otherwise or when the analyzer cannot run. The
/// audio is passed in memory and never written to a file. Speakers are not told apart.
public struct OnDeviceTranscriptionService: AudioTranscriptionService {
    /// The spoken language.
    public let locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    public var displayName: String { "On-device speech recognition" }

    public func transcribe(
        _ audio: AudioClip, options: TranscriptionOptions
    ) async throws -> Transcript {
        guard let (samples, sampleRate) = WAVEncoder.decode(audio.data) else {
            throw CloudVoiceError("On-device transcription needs 16-bit WAV audio.")
        }
        guard let buffer = Self.buffer(samples, sampleRate: sampleRate) else {
            throw DictationError.unavailable
        }
        if #available(macOS 26, *), SpeechTranscriber.isAvailable,
            let transcript = try? await Self.analyze(buffer, locale: locale)
        {
            return transcript
        }
        return try await Self.recognize(buffer, locale: locale)
    }

    /// Mono samples as a buffer.
    static func buffer(_ samples: [Float], sampleRate: Int) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1,
                interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    // MARK: - SpeechAnalyzer

    @available(macOS 26, *)
    private static func analyze(
        _ buffer: AVAudioPCMBuffer, locale: Locale
    ) async throws
        -> Transcript
    {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw DictationError.unsupportedLanguage(locale.identifier)
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [],
            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [
            transcriber
        ]) {
            try await request.downloadAndInstall()
        }
        let modules: [any SpeechModule] = [transcriber]
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        else { throw DictationError.unavailable }
        let input: AVAudioPCMBuffer
        if buffer.format == format {
            input = buffer
        } else {
            guard let converter = AVAudioConverter(from: buffer.format, to: format),
                let converted = converter.convertBuffer(buffer, to: format)
            else { throw DictationError.unavailable }
            input = converted
        }

        let analyzer = SpeechAnalyzer(modules: modules)
        let collector = Task { () throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let range = result.range
                segments.append(
                    TranscriptSegment(
                        text: text, start: max(0, range.start.seconds),
                        end: max(0, range.end.seconds)))
            }
            return segments
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: input))
        continuation.finish()
        do {
            try await analyzer.start(inputSequence: stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        let segments = try await collector.value
        return Transcript(
            text: segments.map(\.text).joined(separator: " "), segments: segments,
            language: supported.language.languageCode?.identifier)
    }

    // MARK: - Apple Speech

    private static func recognize(
        _ buffer: AVAudioPCMBuffer, locale: Locale
    ) async throws
        -> Transcript
    {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw DictationError.speechRecognitionDenied
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            throw DictationError.unsupportedLanguage(locale.identifier)
        }
        guard recognizer.isAvailable else { throw DictationError.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.append(buffer)
        request.endAudio()
        let box = TranscriptContinuation()
        let language = recognizer.locale.language.languageCode?.identifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.set(continuation)
                box.task = recognizer.recognitionTask(
                    with: request, resultHandler: makeResultHandler(box: box, language: language))
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Runs on the recognizer's thread, so it must not inherit any actor isolation.
    private nonisolated static func makeResultHandler(
        box: TranscriptContinuation, language: String?
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            if let result, result.isFinal {
                let words = result.bestTranscription.segments.map {
                    TranscriptSegment(
                        text: $0.substring, start: $0.timestamp,
                        end: $0.timestamp + $0.duration)
                }
                let text = result.bestTranscription.formattedString
                box.resume(
                    with: .success(
                        Transcript(text: text, segments: sentences(from: words), language: language)
                    ))
            } else if let error {
                // "No speech detected" is an empty transcript, not a failure.
                let code = (error as NSError).code
                if code == 1110 || code == 203 {
                    box.resume(with: .success(Transcript(text: "", segments: [])))
                } else {
                    box.resume(with: .failure(error))
                }
            }
        }
    }

    /// Groups timed words into segments, starting a new one after a pause of `pause` seconds
    /// or at the end of a sentence once a segment has a few words.
    static func sentences(
        from words: [TranscriptSegment], pause: TimeInterval = 0.8
    ) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [TranscriptSegment] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(
                TranscriptSegment(
                    text: current.map(\.text).joined(separator: " "), start: first.start,
                    end: last.end))
            current = []
        }
        for word in words where !word.text.isEmpty {
            if let last = current.last, word.start - last.end > pause { flush() }
            current.append(word)
            if current.count >= 4, let mark = word.text.last, ".?!…".contains(mark) { flush() }
        }
        flush()
        return segments
    }
}

/// Resumes a transcription exactly once, from whichever thread finishes first.
private final class TranscriptContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Transcript, any Error>?
    var task: SFSpeechRecognitionTask?

    func set(_ continuation: CheckedContinuation<Transcript, any Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: Result<Transcript, any Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        task?.cancel()
        resume(with: .failure(CancellationError()))
    }
}
