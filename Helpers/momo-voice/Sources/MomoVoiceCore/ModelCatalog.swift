import MomoLiveProtocol

/// The network design of a speech synthesis model, which decides how the helper loads it and
/// what its voice files look like.
public enum SpeechArchitecture: String, Codable, Sendable, Hashable, CaseIterable {
    /// Kokoro 82M: an end-to-end Core ML model with voice embeddings in `voices/`.
    case kokoro
    /// Supertonic: four Core ML graphs with voice styles in `voice_styles/`.
    case supertonic

    /// The built-in model with this architecture, whose languages a model the user adds
    /// shares.
    public var builtInModel: VoiceModel {
        switch self {
        case .kokoro: ModelCatalog.kokoro
        case .supertonic: ModelCatalog.supertonic
        }
    }

    /// A readable name, e.g. "Kokoro".
    public var displayName: String {
        switch self {
        case .kokoro: "Kokoro"
        case .supertonic: "Supertonic"
        }
    }
}

/// A model the helper can download and run, or one the user added from a folder.
public struct VoiceModel: Sendable, Hashable, Identifiable {
    /// The stable identifier used in the protocol, e.g. "nemotron-streaming-multilingual".
    public var id: String
    public var kind: LiveModelKind
    /// A readable name.
    public var name: String
    /// Language codes the model handles, e.g. ["en", "tr"]. Empty means "many".
    public var languages: [String]
    /// The download size in bytes.
    public var sizeBytes: Int64
    /// The license of the model weights (SPDX identifier where one exists).
    public var license: String
    /// The Hugging Face repository the weights come from.
    public var repository: String
    /// The files to fetch from the repository, as glob patterns relative to its root.
    public var files: [String]
    /// How a speech synthesis model is built; `nil` for the other kinds.
    public var architecture: SpeechArchitecture?
    /// Whether the user added the model from a folder. Such a model cannot be downloaded.
    public var isCustom: Bool

    public init(
        id: String, kind: LiveModelKind, name: String, languages: [String], sizeBytes: Int64,
        license: String, repository: String, files: [String],
        architecture: SpeechArchitecture? = nil, isCustom: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.languages = languages
        self.sizeBytes = sizeBytes
        self.license = license
        self.repository = repository
        self.files = files
        self.architecture = architecture
        self.isCustom = isCustom
    }

    /// The protocol description of the model.
    ///
    /// - Parameters:
    ///   - voices: The voices of a downloaded speech synthesis model.
    ///   - customVoices: The ones among `voices` the user added.
    public func info(
        isDownloaded: Bool, isRequired: Bool, voices: [String] = [], customVoices: [String] = []
    ) -> LiveModelInfo {
        LiveModelInfo(
            id: id, kind: kind, name: name, languages: languages, sizeBytes: sizeBytes,
            isDownloaded: isDownloaded, isRequired: isRequired, isCustom: isCustom,
            voices: voices, customVoices: customVoices)
    }
}

/// The models the helper uses. All come from the official speech-swift conversions on
/// Hugging Face and are only downloaded when Momo sends `downloadModels`.
public enum ModelCatalog {
    /// Silero VAD v6.2.1 (Core ML), voice activity detection.
    public static let sileroVAD = VoiceModel(
        id: "silero-vad", kind: .voiceActivity, name: "Silero VAD", languages: [],
        sizeBytes: 1_300_000, license: "MIT", repository: "aufklarer/Silero-VAD-v6.2.1-CoreML",
        files: ["config.json", "silero_vad.mlmodelc/**"])

    /// Pipecat Smart Turn v3.2 (Core ML), which hears from the voice whether a turn is over.
    public static let smartTurn = VoiceModel(
        id: "smart-turn-v3", kind: .turnDetection, name: "Smart Turn v3.2",
        languages: [
            "ar", "bn", "da", "de", "en", "es", "fi", "fr", "hi", "id", "it", "ja", "ko", "mr",
            "nl", "no", "pl", "pt", "ru", "tr", "uk", "vi", "zh",
        ],
        sizeBytes: 17_000_000, license: "BSD-2-Clause",
        repository: "aufklarer/Smart-Turn-v3.2-CoreML",
        files: ["config.json", "smart_turn.mlmodelc/**"])

    /// NVIDIA Nemotron 3.5 ASR Streaming 0.6B (Core ML INT8), streaming speech recognition.
    ///
    /// The languages are the model card's "transcription-ready" tier; the other language slots
    /// need fine-tuning to be usable.
    public static let nemotron = VoiceModel(
        id: "nemotron-streaming-multilingual", kind: .speechToText, name: "Nemotron 3.5 Streaming",
        languages: [
            "ar", "de", "en", "es", "fr", "hi", "it", "ja", "ko", "nl", "pt", "ru", "tr", "uk",
            "vi",
        ],
        sizeBytes: 642_000_000, license: "OpenMDW-1.1",
        repository: "aufklarer/Nemotron-3.5-ASR-Streaming-0.6B-CoreML-INT8",
        files: [
            "config.json", "vocab.json", "tokenizer.model", "languages.json",
            "encoder.mlmodelc/**", "decoder.mlmodelc/**", "joint.mlmodelc/**",
        ])

    /// Kokoro 82M (Core ML), speech synthesis.
    public static let kokoro = VoiceModel(
        id: "kokoro-82m", kind: .textToSpeech, name: "Kokoro",
        languages: ["en", "es", "fr", "hi", "it", "ja", "pt", "zh"],
        sizeBytes: 333_000_000, license: "Apache-2.0", repository: "aufklarer/Kokoro-82M-CoreML",
        files: [
            "config.json", "kokoro_5s.mlmodelc/**", "G2PEncoder.mlmodelc/**",
            "G2PDecoder.mlmodelc/**", "vocab_index.json", "g2p_vocab.json", "us_gold.json",
            "us_silver.json", "voices/*.json",
        ],
        architecture: .kokoro)

    /// Supertone Supertonic 3 (Core ML), multilingual speech synthesis without phonemizer.
    public static let supertonic = VoiceModel(
        id: "supertonic-3", kind: .textToSpeech, name: "Supertonic 3",
        languages: [
            "ar", "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hi", "hr", "hu",
            "id", "it", "ja", "ko", "lt", "lv", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv",
            "tr", "uk", "vi",
        ],
        sizeBytes: 400_000_000, license: "OpenRAIL-M",
        repository: "aufklarer/Supertonic-3-CoreML",
        files: [
            "config.json", "tts.json", "unicode_indexer.json", "voice_styles/*.json",
            "DurationPredictor.mlpackage/**", "TextEncoder.mlpackage/**",
            "VectorEstimator.mlpackage/**", "Vocoder.mlpackage/**",
        ],
        architecture: .supertonic)

    /// Every model, in the order they are listed.
    public static let all: [VoiceModel] = [nemotron, kokoro, supertonic, sileroVAD, smartTurn]

    /// The built-in model with `id`, if the catalog has one.
    public static func model(id: String) -> VoiceModel? {
        all.first { $0.id == id }
    }
}
