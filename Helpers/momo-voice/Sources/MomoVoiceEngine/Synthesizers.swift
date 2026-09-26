@preconcurrency import AVFoundation
import Foundation
@preconcurrency import KokoroTTS
import MomoVoiceCore
@preconcurrency import SupertonicTTS

/// Rendered speech.
struct SynthesizedSpeech: Sendable {
    var samples: [Float]
    var sampleRate: Double
}

/// Turns one piece of text into speech. Called from one queue at a time.
protocol SpeechSynthesizing: AnyObject, Sendable {
    func synthesize(_ text: String) throws -> SynthesizedSpeech
}

/// Kokoro 82M through speech-swift.
final class KokoroSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    /// Kokoro reads at most 128 phonemes at once, roughly this many characters.
    static let maximumPieceLength = 110

    private let model: KokoroTTSModel
    private let voice: String
    private let language: String

    init(model: KokoroTTSModel, voice: String, language: String) throws {
        guard model.availableVoices.contains(voice) else {
            throw VoiceEngineError.unknownVoice(voice)
        }
        self.model = model
        self.voice = voice
        self.language = language
    }

    func synthesize(_ text: String) throws -> SynthesizedSpeech {
        let samples = try model.synthesize(text: text, voice: voice, language: language)
        return SynthesizedSpeech(
            samples: samples, sampleRate: Double(KokoroTTSModel.outputSampleRate))
    }
}

/// Supertonic 3 through speech-swift.
final class SupertonicSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    static let sampleRate = 44_100.0

    private let model: SupertonicTTSModel
    private let voice: String
    private let language: String

    init(model: SupertonicTTSModel, voice: String, language: String) throws {
        guard model.availableVoices.contains(voice) else {
            throw VoiceEngineError.unknownVoice(voice)
        }
        self.model = model
        self.voice = voice
        self.language = language
    }

    func synthesize(_ text: String) throws -> SynthesizedSpeech {
        var options = SupertonicOptions.default
        // A fixed seed keeps the voice the same from sentence to sentence.
        options.seed = 0x4D6F_6D6F
        let samples = try model.synthesize(
            text: text, voice: voice, language: language, options: options)
        return SynthesizedSpeech(samples: samples, sampleRate: Self.sampleRate)
    }
}

/// The system's voices, rendered to samples so they play through the helper's own audio
/// engine and echo cancellation still works.
final class AppleSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    init(voiceIdentifier: String?, locale: String) {
        voice = Self.voice(identifier: voiceIdentifier, locale: locale)
        Log.info("System voice: \(voice?.identifier ?? "default")")
    }

    /// The requested voice, or the best installed one for the locale: premium over enhanced
    /// over default quality, never a novelty voice.
    static func voice(identifier: String?, locale: String) -> AVSpeechSynthesisVoice? {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        let tag = locale.replacingOccurrences(of: "_", with: "-").lowercased()
        let language = ModelSelection.languageCode(of: locale)
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
                && ModelSelection.languageCode(of: $0.language) == language
        }
        return candidates.max { lhs, rhs in
            let lhsExact = lhs.language.lowercased() == tag
            let rhsExact = rhs.language.lowercased() == tag
            if lhsExact != rhsExact { return !lhsExact }
            return lhs.quality.rawValue < rhs.quality.rawValue
        } ?? AVSpeechSynthesisVoice(language: locale)
    }

    func synthesize(_ text: String) throws -> SynthesizedSpeech {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let collector = BufferCollector()
        synthesizer.write(utterance) { buffer in collector.add(buffer) }
        guard collector.done.wait(timeout: .now() + 30) == .success else {
            synthesizer.stopSpeaking(at: .immediate)
            throw VoiceEngineError.synthesisTimedOut
        }
        return collector.result
    }
}

/// Gathers the buffers `AVSpeechSynthesizer.write` delivers; an empty buffer ends them.
private final class BufferCollector: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate = 22_050.0

    var result: SynthesizedSpeech {
        lock.withLock { SynthesizedSpeech(samples: samples, sampleRate: sampleRate) }
    }

    func add(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
            done.signal()
            return
        }
        let count = Int(pcm.frameLength)
        var chunk: [Float] = []
        if let floats = pcm.floatChannelData?[0] {
            chunk = Array(UnsafeBufferPointer(start: floats, count: count))
        } else if let integers = pcm.int16ChannelData?[0] {
            chunk = UnsafeBufferPointer(start: integers, count: count).map { Float($0) / 32_768 }
        } else if let integers = pcm.int32ChannelData?[0] {
            chunk = UnsafeBufferPointer(start: integers, count: count).map {
                Float($0) / 2_147_483_648
            }
        }
        lock.withLock {
            sampleRate = pcm.format.sampleRate
            samples += chunk
        }
    }
}
