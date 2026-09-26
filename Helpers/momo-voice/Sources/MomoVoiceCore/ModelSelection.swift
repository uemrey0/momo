import MomoLiveProtocol

/// How the helper speaks.
public enum SpeechOutputEngine: Sendable, Hashable {
    /// Kokoro with a voice preset and one of its language codes.
    case kokoro(voice: String, language: String)
    /// Supertonic with a voice style and one of its language codes.
    case supertonic(voice: String, language: String)
    /// The system's speech synthesizer, rendered into the helper's own audio engine.
    /// `voiceIdentifier` is `nil` for the best installed voice for `locale`.
    case apple(voiceIdentifier: String?, locale: String)

    /// The catalog model the engine needs, or `nil` for Apple speech.
    public var modelID: String? {
        switch self {
        case .kokoro: ModelCatalog.kokoro.id
        case .supertonic: ModelCatalog.supertonic.id
        case .apple: nil
        }
    }
}

/// The models and settings a live session uses.
public struct VoicePlan: Sendable, Hashable {
    /// The speech recognition model.
    public var speechToTextModel: String
    /// The language tag passed to the recognizer, e.g. "tr-TR".
    public var recognitionLanguage: String
    /// How replies are spoken.
    public var output: SpeechOutputEngine

    /// Every downloadable model the plan needs.
    public var requiredModelIDs: [String] {
        var ids = [ModelCatalog.sileroVAD.id, ModelCatalog.smartTurn.id, speechToTextModel]
        if let tts = output.modelID { ids.append(tts) }
        return ids
    }
}

/// Why a session cannot be planned.
public enum ModelSelectionError: Error, Equatable, CustomStringConvertible {
    case unsupportedLanguage(String)
    case unknownModel(String)
    case modelDoesNotSpeak(model: String, language: String)

    public var description: String {
        switch self {
        case .unsupportedLanguage(let locale):
            "No speech recognition model understands \(locale)."
        case .unknownModel(let id):
            "Unknown model \(id)."
        case .modelDoesNotSpeak(let model, let language):
            "The model \(model) does not support the language \(language)."
        }
    }
}

/// Picks models for a conversation language.
///
/// Recognition uses Nemotron for every language it is ready for. Speech uses Kokoro where it
/// has a voice for the language, Supertonic for the other languages it covers, and the
/// system's voices for the rest.
public enum ModelSelection {
    /// The identifier Momo passes as `textToSpeechModel` to ask for the system's voices.
    public static let appleSpeechID = "apple-speech"

    /// Kokoro's default voice per language code. Kokoro's other languages sound poor or
    /// have no voice, so they are not listed.
    static let kokoroVoices: [String: String] = [
        "en": "af_heart", "es": "ef_dora", "fr": "ff_siwis", "hi": "hf_alpha", "it": "if_sara",
        "ja": "jf_alpha", "pt": "pf_dora", "zh": "zf_xiaobei",
    ]

    /// The default Supertonic voice style.
    static let supertonicVoice = "F1"

    /// Conversation languages the helper can serve: the ones its recognizer understands.
    public static var supportedLanguages: [String] {
        ModelCatalog.nemotron.languages
    }

    /// The language code of a locale, e.g. "tr" for "tr-TR" or "zh" for "zh_Hans_CN".
    public static func languageCode(of locale: String) -> String {
        let normalized = locale.replacingOccurrences(of: "_", with: "-")
        let code = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return code.lowercased()
    }

    /// The locale as a BCP 47 tag with a region, e.g. "tr-TR" for "tr" or "tr_TR".
    public static func recognitionTag(for locale: String) -> String {
        let parts = locale.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        let language = languageCode(of: locale)
        if let region = parts.last, parts.count > 1, region.count == 2 {
            return "\(language)-\(region.uppercased())"
        }
        let defaults = [
            "en": "US", "es": "ES", "fr": "FR", "pt": "BR", "ar": "AR", "hi": "IN", "ja": "JP",
            "ko": "KR", "uk": "UA", "vi": "VN",
        ]
        return "\(language)-\(defaults[language] ?? language.uppercased())"
    }

    /// The default plan for a locale, or `nil` when the helper cannot understand it.
    public static func plan(locale: String) -> VoicePlan? {
        try? plan(for: LiveSessionConfiguration(locale: locale))
    }

    /// The plan for a session, honouring the models and voice it asks for.
    public static func plan(for configuration: LiveSessionConfiguration) throws -> VoicePlan {
        let language = languageCode(of: configuration.locale)
        guard ModelCatalog.nemotron.languages.contains(language) else {
            throw ModelSelectionError.unsupportedLanguage(configuration.locale)
        }
        if let requested = configuration.speechToTextModel,
            requested != ModelCatalog.nemotron.id
        {
            throw ModelSelectionError.unknownModel(requested)
        }
        let output = try outputEngine(for: configuration, language: language)
        return VoicePlan(
            speechToTextModel: ModelCatalog.nemotron.id,
            recognitionLanguage: recognitionTag(for: configuration.locale), output: output)
    }

    private static func outputEngine(
        for configuration: LiveSessionConfiguration, language: String
    ) throws -> SpeechOutputEngine {
        let apple = SpeechOutputEngine.apple(
            voiceIdentifier: configuration.appleVoiceIdentifier, locale: configuration.locale)
        switch configuration.textToSpeechModel {
        case appleSpeechID:
            return apple
        case ModelCatalog.kokoro.id:
            guard let voice = kokoroVoices[language] else {
                throw ModelSelectionError.modelDoesNotSpeak(
                    model: ModelCatalog.kokoro.id, language: language)
            }
            return .kokoro(
                voice: configuration.voice ?? kokoroVoice(voice, for: configuration.locale),
                language: language)
        case ModelCatalog.supertonic.id:
            guard ModelCatalog.supertonic.languages.contains(language) else {
                throw ModelSelectionError.modelDoesNotSpeak(
                    model: ModelCatalog.supertonic.id, language: language)
            }
            return .supertonic(voice: configuration.voice ?? supertonicVoice, language: language)
        case .some(let other):
            throw ModelSelectionError.unknownModel(other)
        case nil:
            if let voice = kokoroVoices[language] {
                return .kokoro(
                    voice: configuration.voice ?? kokoroVoice(voice, for: configuration.locale),
                    language: language)
            }
            if ModelCatalog.supertonic.languages.contains(language) {
                return .supertonic(
                    voice: configuration.voice ?? supertonicVoice, language: language)
            }
            return apple
        }
    }

    /// British English gets a British voice.
    private static func kokoroVoice(_ voice: String, for locale: String) -> String {
        recognitionTag(for: locale) == "en-GB" ? "bf_emma" : voice
    }
}
