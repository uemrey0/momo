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

/// A Kokoro model through speech-swift.
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

/// A Supertonic model through speech-swift.
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
