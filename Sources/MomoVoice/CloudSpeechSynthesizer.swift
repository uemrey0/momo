import AVFoundation
import Foundation

/// Which voice reads replies aloud.
public enum SpeechVoiceChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The system's voices, on the Mac.
    case apple
    /// OpenAI text to speech with the user's key. Replies are sent to OpenAI.
    case openAI

    public var id: String { rawValue }
}

/// Builds requests for OpenAI's `/v1/audio/speech` endpoint.
public struct OpenAISpeechRequest: Sendable {
    /// The voices Momo offers.
    public static let voices = [
        "coral", "alloy", "ash", "ballad", "echo", "fable", "nova", "onyx", "sage", "shimmer",
        "verse",
    ]
    public static let defaultVoice = "coral"
    public static let defaultModel = "gpt-4o-mini-tts"
    /// Samples per second of the `pcm` format: 16-bit, mono, little-endian.
    public static let sampleRate = 24_000

    public var apiKey: String
    public var model: String
    public var voice: String
    /// How to speak (only `gpt-4o-mini-tts` follows instructions).
    public var instructions: String?
    public var baseURL: URL

    public init(
        apiKey: String, model: String = Self.defaultModel, voice: String = Self.defaultVoice,
        instructions: String? = nil,
        baseURL: URL = URL(string: "https://api.openai.com/v1") ?? URL(fileURLWithPath: "/")
    ) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.baseURL = baseURL
    }

    /// A request that streams `text` as raw PCM, so playback can start before it all arrives.
    public func urlRequest(for text: String) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model, "voice": voice, "input": text, "response_format": "pcm",
        ]
        if let instructions, model.hasPrefix("gpt-4o") {
            body["instructions"] = instructions
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("audio/speech"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

/// Reads text aloud with an OpenAI voice, streaming the audio so Momo starts talking quickly.
///
/// Same callbacks as ``SpeechSynthesizer``, except the mouth follows ``onLevel`` (the output
/// level) instead of words. When the request fails before any audio plays, ``onError`` is
/// called instead of ``onStart``/``onFinish``, so the caller can fall back to a system voice.
@MainActor
public final class CloudSpeechSynthesizer {
    /// Called when audio starts playing.
    public var onStart: (() -> Void)?
    /// Output level from 0 to 1, about 20 times a second.
    public var onLevel: ((Double) -> Void)?
    /// Called when speech finishes or is stopped, after ``onStart``.
    public var onFinish: (() -> Void)?
    /// Called when nothing could be played.
    public var onError: ((any Error) -> Void)?

    public var request: OpenAISpeechRequest
    public private(set) var isSpeaking = false

    private let session: URLSession
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat?
    private var streaming: Task<Void, Never>?
    private var pendingBuffers = 0
    private var streamEnded = false
    private var generation = 0

    public init(request: OpenAISpeechRequest, session: URLSession = .shared) {
        self.request = request
        self.session = session
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(OpenAISpeechRequest.sampleRate),
            channels: 1, interleaved: false)
        engine.attach(player)
        if let format {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
    }

    /// Speaks Markdown text.
    public func speak(_ markdown: String) {
        stop()
        let text = SpeechText.plain(fromMarkdown: markdown)
        guard !text.isEmpty else { return }
        generation += 1
        let current = generation
        let session = session
        let urlRequest: URLRequest
        do {
            urlRequest = try request.urlRequest(for: text)
        } catch {
            onError?(error)
            return
        }
        streamEnded = false
        pendingBuffers = 0
        streaming = Task { [weak self] in
            do {
                let (bytes, response) = try await session.bytes(for: urlRequest)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    var body = Data()
                    for try await byte in bytes {
                        body.append(byte)
                        if body.count > 16_000 { break }
                    }
                    throw CloudVoiceError.http(status: status, body: body)
                }
                // Schedule about a tenth of a second at a time.
                let chunkBytes = OpenAISpeechRequest.sampleRate / 10 * 2
                var chunk = Data()
                chunk.reserveCapacity(chunkBytes)
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= chunkBytes {
                        guard let self, self.generation == current else { return }
                        try self.schedule(chunk)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                guard let self, self.generation == current else { return }
                if chunk.count >= 2 { try self.schedule(chunk) }
                self.streamDidEnd()
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    public func stop() {
        generation += 1
        streaming?.cancel()
        streaming = nil
        player.stop()
        if engine.isRunning {
            engine.mainMixerNode.removeTap(onBus: 0)
            engine.stop()
        }
        pendingBuffers = 0
        if isSpeaking {
            isSpeaking = false
            onLevel?(0)
            onFinish?()
        }
    }

    private func schedule(_ data: Data) throws {
        guard let format else { throw CloudVoiceError("Audio output is not available.") }
        let samples = WAVEncoder.samples(fromPCM16: data)
        guard !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        if !engine.isRunning {
            let levels = LevelReporter { [weak self] level in
                Task { @MainActor in self?.reportLevel(level) }
            }
            engine.mainMixerNode.installTap(
                onBus: 0, bufferSize: 1024, format: nil, block: Self.makeTap(levels: levels))
            engine.prepare()
            try engine.start()
        }
        pendingBuffers += 1
        let current = generation
        player.scheduleBuffer(
            buffer, completionCallbackType: .dataPlayedBack,
            completionHandler: Self.makeCompletion { [weak self] in
                Task { @MainActor in self?.bufferFinished(generation: current) }
            })
        if !player.isPlaying {
            player.play()
            if !isSpeaking {
                isSpeaking = true
                onStart?()
            }
        }
    }

    // Audio callbacks run on the audio thread, so they must not inherit main actor isolation.

    private nonisolated static func makeTap(levels: LevelReporter) -> AVAudioNodeTapBlock {
        { buffer, _ in levels.report(buffer) }
    }

    private nonisolated static func makeCompletion(
        _ done: @escaping @Sendable () -> Void
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in done() }
    }

    private func reportLevel(_ level: Double) {
        guard isSpeaking else { return }
        onLevel?(level)
    }

    private func bufferFinished(generation: Int) {
        guard generation == self.generation else { return }
        pendingBuffers = max(0, pendingBuffers - 1)
        finishIfDone()
    }

    private func streamDidEnd() {
        streamEnded = true
        streaming = nil
        if !isSpeaking {
            // The service sent no audio at all.
            fail(CloudVoiceError("The voice service sent no audio."))
            return
        }
        finishIfDone()
    }

    private func finishIfDone() {
        guard streamEnded, pendingBuffers == 0, isSpeaking else { return }
        stop()
    }

    private func fail(_ error: any Error) {
        let wasSpeaking = isSpeaking
        stop()
        if !wasSpeaking { onError?(error) }
    }
}
