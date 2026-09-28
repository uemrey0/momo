@preconcurrency import AVFoundation
import Foundation
import MomoLiveProtocol
import MomoVoiceCore
@preconcurrency import NemotronStreamingASR
@preconcurrency import SpeechVAD

/// Reads a recording as 16 kHz mono samples.
enum RecordingReader {
    /// Frames read from the file at a time, so a long recording is never held twice.
    private static let chunkFrames: AVAudioFrameCount = 32_768

    /// The recording at `url`, mixed down to mono and resampled to 16 kHz.
    ///
    /// - Throws: ``VoiceEngineError/unreadableRecording(_:)`` when it cannot be read.
    static func samples(of url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw VoiceEngineError.unreadableRecording(error.localizedDescription)
        }
        let inputFormat = file.processingFormat
        guard
            let outputFormat = AVAudioFormat(
                standardFormatWithSampleRate: RecordingTranscriber.sampleRate, channels: 1),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw VoiceEngineError.unreadableRecording("its audio format is not supported")
        }
        converter.downmix = true
        let source = FileSource(file: file, format: inputFormat, chunkFrames: chunkFrames)
        let ratio = RecordingTranscriber.sampleRate / inputFormat.sampleRate
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * ratio) + 1_024)
        let outputFrames = AVAudioFrameCount(Double(chunkFrames) * ratio) + 1_024
        while true {
            guard
                let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrames)
            else {
                throw VoiceEngineError.unreadableRecording("out of memory")
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                source.next(inputStatus)
            }
            if let failure = source.error ?? error {
                throw VoiceEngineError.unreadableRecording(failure.localizedDescription)
            }
            if output.frameLength > 0, let data = output.floatChannelData?[0] {
                samples += UnsafeBufferPointer(start: data, count: Int(output.frameLength))
            }
            if status == .endOfStream || status == .error { break }
        }
        return samples
    }

    /// Hands the converter one chunk of the file at a time.
    private final class FileSource: @unchecked Sendable {
        private let file: AVAudioFile
        private let format: AVAudioFormat
        private let chunkFrames: AVAudioFrameCount
        private var isFinished = false
        private(set) var error: (any Error)?

        init(file: AVAudioFile, format: AVAudioFormat, chunkFrames: AVAudioFrameCount) {
            self.file = file
            self.format = format
            self.chunkFrames = chunkFrames
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            // Reading at the end of the file fails without an error, so never try it.
            let remaining = max(0, file.length - file.framePosition)
            let frames = AVAudioFrameCount(min(Int64(chunkFrames), remaining))
            guard !isFinished, frames > 0,
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
            else {
                isFinished = true
                status.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: buffer, frameCount: frames)
            } catch {
                self.error = error
                buffer.frameLength = 0
            }
            guard buffer.frameLength > 0 else {
                isFinished = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
    }
}

/// Transcribes a whole recording into timed segments.
///
/// Silero VAD finds the speech; stretches with pauses under 0.6 s between them are joined,
/// and each stretch goes through a fresh streaming Nemotron session the way ``Listener``
/// transcribes a turn: primed with a second of silence, fed the speech, flushed with a
/// moment of silence and finalised.
///
/// Nemotron sometimes drops the first word of a session, depending on where the speech
/// falls within its 320 ms chunks. Each stretch is therefore transcribed three times,
/// shifted by a third of a chunk each time, and the longest text is kept. Recognition runs
/// at about a tenth of real time on an M1, so this stays well within budget for recordings.
final class RecordingTranscriber {
    static let sampleRate = 16_000.0
    /// Silence fed to a new recognition session before speech.
    private static let primingSeconds = 1.0
    /// Silence fed after speech, so the recognizer's look-ahead releases the last word.
    private static let flushingSeconds = 0.32
    /// Audio kept around each stretch, so its first and last sounds are not cut. Where the
    /// recording starts too soon for it, silence stands in.
    private static let paddingSeconds = 0.1
    /// How far each attempt at a stretch is shifted against the recognizer's chunks.
    private static let shifts = [0.0, 0.107, 0.213]

    private let vad: SileroVADModel
    private let recognizer: NemotronStreamingASRModel
    private let language: String

    /// - Parameters:
    ///   - vad: A VAD instance of its own; finding speech resets its state.
    ///   - recognizer: The shared recognizer; each stretch gets its own session.
    ///   - recognitionLanguage: The language tag, e.g. "tr-TR".
    init(vad: SileroVADModel, recognizer: NemotronStreamingASRModel, recognitionLanguage: String) {
        self.vad = vad
        self.recognizer = recognizer
        self.language = recognitionLanguage
    }

    /// The timed text of 16 kHz mono `audio`. Stretches without words are left out.
    func transcribe(_ audio: [Float]) async throws -> [LiveTranscriptSegment] {
        let found = vad.detectSpeech(
            audio: audio, sampleRate: Int(Self.sampleRate),
            config: VADConfig(
                onset: 0.5, offset: 0.35, minSpeechDuration: 0.25, minSilenceDuration: 0.3,
                windowDuration: 0.032, stepRatio: 1))
        let stretches = SpeechStretches.merge(
            found.map { SpeechStretch(start: Double($0.startTime), end: Double($0.endTime)) })
        var segments: [LiveTranscriptSegment] = []
        for stretch in stretches {
            try Task.checkCancellation()
            let from = max(0, Int((stretch.start - Self.paddingSeconds) * Self.sampleRate))
            let to = min(audio.count, Int((stretch.end + Self.paddingSeconds) * Self.sampleRate))
            guard to > from else { continue }
            let wanted = Int((stretch.start - Self.paddingSeconds) * Self.sampleRate)
            let lead = [Float](repeating: 0, count: max(0, from - wanted))
            let speech = lead + audio[from..<to]
            let text =
                try Self.shifts.map { try transcribeStretch(silence($0) + speech) }
                .max { $0.count < $1.count } ?? ""
            if !text.isEmpty {
                segments.append(
                    LiveTranscriptSegment(
                        text: text, start: stretch.start,
                        end: min(stretch.end, Double(audio.count) / Self.sampleRate)))
            }
            // Long recordings have many stretches; let other work run between them.
            await Task.yield()
        }
        return segments
    }

    private func transcribeStretch(_ samples: [Float]) throws -> String {
        let session = try recognizer.createSession(language: language)
        _ = try session.pushAudio(silence(Self.primingSeconds))
        var lastPartial = ""
        for partial in try session.pushAudio(samples)
            + session.pushAudio(
                silence(Self.flushingSeconds))
        {
            lastPartial = partial.text
        }
        let text = try session.finalize().last?.text ?? lastPartial
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Self.sampleRate))
    }
}
