import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Which audio a meeting recording comes from.
public enum MeetingTrack: String, Sendable, CaseIterable {
    /// The microphone: the user.
    case microphone
    /// The Mac's audio output: everyone else in the call.
    case system
}

/// A chunk of one track of a meeting recording, ready to transcribe.
public struct MeetingAudioChunk: Sendable, Equatable {
    public var track: MeetingTrack
    public var chunk: AudioChunker.Chunk
}

/// Records a meeting as two separate tracks, so the user and the others are always told
/// apart: the microphone (the user) and the Mac's audio output (everyone else), captured with
/// ScreenCaptureKit without Momo's own sounds.
///
/// Both tracks are converted to 16 kHz mono and cut into chunks by an ``AudioChunker``;
/// chunks arrive in order through ``chunks``. Audio stays in memory unless a
/// folder to keep it in is given, in which case each track is also written to a WAV file.
///
/// System audio needs the Screen Recording permission (``hasSystemAudioPermission``). Without
/// it, create the capture with `capturesSystemAudio: false` to record the microphone only.
///
/// Callbacks run on audio threads; this type is not tied to an actor and its closures are
/// created outside main-actor code.
public final class MeetingAudioCapture: NSObject, @unchecked Sendable {
    /// The rate chunks are delivered at.
    public static let sampleRate = 16_000

    /// Finished chunks of both tracks, in the order they were cut. The stream ends after
    /// ``stop()`` has delivered the last chunk of each track.
    public let chunks: AsyncStream<MeetingAudioChunk>
    /// Called with each track's input level from 0 to 1, about 20 times a second.
    public var onLevel: (@Sendable (MeetingTrack, Double) -> Void)?
    /// Called when system audio capture stops on its own (for example when the permission is
    /// revoked). The microphone keeps recording.
    public var onSystemAudioStopped: (@Sendable (any Error) -> Void)?

    public let capturesSystemAudio: Bool
    private let chunking: AudioChunker.Configuration
    private let audioFolder: URL?
    private let continuation: AsyncStream<MeetingAudioChunk>.Continuation
    private let lock = NSLock()
    private var recorders: [MeetingTrack: TrackRecorder] = [:]
    private let engine = AVAudioEngine()
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "momo.meeting.system-audio")
    private let screenQueue = DispatchQueue(label: "momo.meeting.screen")

    /// - Parameters:
    ///   - capturesSystemAudio: Also record the Mac's audio output (needs Screen Recording).
    ///   - chunking: How chunks are cut. Its sample rate is always ``sampleRate``.
    ///   - audioFolder: Where to keep `microphone.wav` and `system.wav`, or `nil` to keep
    ///     audio in memory only.
    public init(
        capturesSystemAudio: Bool, chunking: AudioChunker.Configuration = .init(),
        audioFolder: URL? = nil
    ) {
        self.capturesSystemAudio = capturesSystemAudio
        var chunking = chunking
        chunking.sampleRate = Self.sampleRate
        self.chunking = chunking
        self.audioFolder = audioFolder
        (chunks, continuation) = AsyncStream.makeStream()
    }

    /// Whether Momo may capture system audio (the Screen Recording permission). Never asks.
    public static var hasSystemAudioPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks for the Screen Recording permission. macOS shows its prompt once; afterwards the
    /// user grants it in System Settings, and it takes effect when Momo restarts.
    @discardableResult
    public static func requestSystemAudioPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Starts recording. Throws when the microphone is not allowed or system audio cannot be
    /// captured; nothing keeps recording after a failure.
    public func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw DictationError.microphoneDenied
        }
        try startMicrophone()
        if capturesSystemAudio {
            do {
                try await startSystemAudio()
            } catch {
                stopMicrophone()
                throw error
            }
        }
    }

    /// Stops recording, delivers the last chunk of each track, ends ``chunks`` and returns
    /// the audio files that were kept, if any.
    @discardableResult
    public func stop() async -> [URL] {
        stopMicrophone()
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        let active = lock.withLock {
            let active = recorders
            recorders = [:]
            return active
        }
        var files: [URL] = []
        for track in MeetingTrack.allCases {
            guard let recorder = active[track] else { continue }
            if let chunk = recorder.finish() {
                continuation.yield(MeetingAudioChunk(track: track, chunk: chunk))
            }
            if let url = recorder.writer?.url { files.append(url) }
        }
        continuation.finish()
        return files
    }

    private func makeRecorder(_ track: MeetingTrack) -> TrackRecorder {
        let writer = audioFolder.flatMap {
            try? WAVFileWriter(
                url: $0.appendingPathComponent("\(track.rawValue).wav"),
                sampleRate: Self.sampleRate)
        }
        let recorder = TrackRecorder(
            chunking: chunking, writer: writer,
            onChunk: { [continuation] chunk in
                continuation.yield(MeetingAudioChunk(track: track, chunk: chunk))
            },
            onLevel: { [weak self] level in self?.onLevel?(track, level) })
        lock.lock()
        recorders[track] = recorder
        lock.unlock()
        return recorder
    }

    // MARK: - Microphone

    private func startMicrophone() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw DictationError.unavailable }
        let recorder = makeRecorder(.microphone)
        input.installTap(
            onBus: 0, bufferSize: 4096, format: format, block: Self.makeTap(recorder: recorder))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func stopMicrophone() {
        guard engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    private nonisolated static func makeTap(recorder: TrackRecorder) -> AVAudioNodeTapBlock {
        { buffer, _ in recorder.append(buffer) }
    }

    // MARK: - System audio

    private func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CloudVoiceError("There is no display to capture system audio from.")
        }
        let filter = SCContentFilter(
            display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        // Video can't be turned off, so ask for as little of it as possible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let recorder = makeRecorder(.system)
        let output = SystemAudioOutput(recorder: recorder) { [weak self] error in
            self?.onSystemAudioStopped?(error)
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: screenQueue)
        try await stream.startCapture()
        output.stream = stream
        self.stream = stream
    }
}

/// Converts one track's buffers to 16 kHz mono, keeps them in a chunker and hands out
/// finished chunks, on the audio thread.
final class TrackRecorder: @unchecked Sendable {
    let writer: WAVFileWriter?
    private let lock = NSLock()
    private var chunker: AudioChunker
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat?
    private let levels: LevelReporter
    private let onChunk: @Sendable (AudioChunker.Chunk) -> Void

    init(
        chunking: AudioChunker.Configuration, writer: WAVFileWriter?,
        onChunk: @escaping @Sendable (AudioChunker.Chunk) -> Void,
        onLevel: @escaping @Sendable (Double) -> Void
    ) {
        chunker = AudioChunker(configuration: chunking)
        self.writer = writer
        self.onChunk = onChunk
        levels = LevelReporter(onLevel)
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(chunking.sampleRate), channels: 1,
            interleaved: false)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        levels.report(buffer)
        guard let outputFormat, let samples = convert(buffer, to: outputFormat), !samples.isEmpty
        else { return }
        writer?.append(samples)
        lock.lock()
        let chunks = chunker.append(samples)
        lock.unlock()
        for chunk in chunks { onChunk(chunk) }
    }

    /// The remaining audio as a last chunk; closes the audio file.
    func finish() -> AudioChunker.Chunk? {
        lock.lock()
        let last = chunker.finish()
        lock.unlock()
        writer?.close()
        return last
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> [Float]? {
        if buffer.format != inputFormat {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.downmix = true
        }
        guard let converter, let converted = converter.convertBuffer(buffer, to: format),
            let channel = converted.floatChannelData?[0]
        else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }
}

/// Receives ScreenCaptureKit's audio (and ignores its tiny video frames).
private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    private let recorder: TrackRecorder
    private let onStop: @Sendable (any Error) -> Void
    weak var stream: SCStream?

    init(recorder: TrackRecorder, onStop: @escaping @Sendable (any Error) -> Void) {
        self.recorder = recorder
        self.onStop = onStop
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid,
            let buffer = Self.pcmBuffer(from: sampleBuffer)
        else { return }
        recorder.append(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop(error)
    }

    /// Copies an audio sample buffer into a PCM buffer.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
