import MomoLiveProtocol

/// How the helper speaks: a speech synthesis model, one of its voices and a language.
public enum SpeechOutputEngine: Sendable, Hashable {
    /// A Kokoro model with a voice preset (`nil` for the model's default) and one of its
    /// language codes.
    case kokoro(modelID: String, voice: String?, language: String)
    /// A Supertonic model with a voice style (`nil` for the model's default) and one of its
    /// language codes.
    case supertonic(modelID: String, voice: String?, language: String)

    /// The model the engine speaks with, built in or added by the user.
    public var modelID: String {
        switch self {
        case .kokoro(let modelID, _, _), .supertonic(let modelID, _, _): modelID
        }
    }

    /// The requested voice, or `nil` for the model's default.
    public var voice: String? {
        switch self {
        case .kokoro(_, let voice, _), .supertonic(_, let voice, _): voice
        }
    }

    /// The language code passed to the model, e.g. "tr".
    public var language: String {
        switch self {
        case .kokoro(_, _, let language), .supertonic(_, _, let language): language
        }
    }

    /// How the model is built.
    public var architecture: SpeechArchitecture {
        switch self {
        case .kokoro: .kokoro
        case .supertonic: .supertonic
        }
    }

    /// The engine for a model of `architecture`.
    static func make(
        _ architecture: SpeechArchitecture, modelID: String, voice: String?, language: String
    ) -> SpeechOutputEngine {
        switch architecture {
        case .kokoro: .kokoro(modelID: modelID, voice: voice, language: language)
        case .supertonic: .supertonic(modelID: modelID, voice: voice, language: language)
        }
    }
}

/// The models and settings a session uses.
public struct VoicePlan: Sendable, Hashable {
    /// What the session does with the audio devices.
    public var mode: LiveSessionMode
    /// The speech recognition model, or `nil` for a session that only speaks.
    public var speechToTextModel: String?
    /// The session's language tag, e.g. "tr-TR": what the recognizer is told, and what picks
    /// a regional default voice.
    public var recognitionLanguage: String
    /// How replies are spoken, or `nil` for a session that only listens.
    public var output: SpeechOutputEngine?

    /// Every model the plan needs on disk.
    public var requiredModelIDs: [String] {
        var ids: [String] = []
        if let speechToTextModel {
            ids += [ModelCatalog.sileroVAD.id, ModelCatalog.smartTurn.id, speechToTextModel]
        }
        if let output { ids.append(output.modelID) }
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
            "Momo has no voice model that understands \(locale)."
        case .unknownModel(let id):
            "Unknown model \(id)."
        case .modelDoesNotSpeak(let model, let language):
            "The model \(model) does not support the language \(language)."
        }
    }
}

/// Picks models for a session.
///
/// Recognition uses Nemotron for every language it is ready for. Speech uses the model the
/// user picked, or else Kokoro where it has a voice for the language and Supertonic for the
/// other languages it covers. A language no speech model covers cannot be spoken.
public enum ModelSelection {
    /// Kokoro's default voice per language code. Kokoro's other languages sound poor or
    /// have no voice, so they are not listed.
    static let kokoroVoices: [String: String] = [
        "en": "af_heart", "es": "ef_dora", "fr": "ff_siwis", "hi": "hf_alpha", "it": "if_sara",
        "ja": "jf_alpha", "pt": "pf_dora", "zh": "zf_xiaobei",
    ]

    /// Kokoro's voice for British English.
    static let britishKokoroVoice = "bf_emma"

    /// The default Supertonic voice style.
    static let supertonicVoice = "F1"

    /// Conversation languages the helper can serve: the ones its recognizer understands and
    /// a built-in speech model speaks.
    public static var supportedLanguages: [String] {
        ModelCatalog.nemotron.languages.filter(isSpokenByBuiltInModel)
    }

    /// Whether Kokoro or Supertonic speaks the language code.
    static func isSpokenByBuiltInModel(_ language: String) -> Bool {
        kokoroVoices[language] != nil || ModelCatalog.supertonic.languages.contains(language)
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

    /// The default conversation plan for a locale, or `nil` when the helper cannot serve it.
    public static func plan(locale: String) -> VoicePlan? {
        try? plan(for: LiveSessionConfiguration(locale: locale))
    }

    /// The plan for a session, honouring its mode and the models and voice it asks for.
    ///
    /// - Parameters:
    ///   - configuration: The session to plan.
    ///   - catalog: The models to choose from, including the ones the user added.
    public static func plan(
        for configuration: LiveSessionConfiguration, catalog: [VoiceModel] = ModelCatalog.all
    ) throws -> VoicePlan {
        let language = languageCode(of: configuration.locale)
        var speechToTextModel: String?
        if configuration.listens {
            guard ModelCatalog.nemotron.languages.contains(language) else {
                throw ModelSelectionError.unsupportedLanguage(configuration.locale)
            }
            if let requested = configuration.speechToTextModel,
                requested != ModelCatalog.nemotron.id
            {
                throw ModelSelectionError.unknownModel(requested)
            }
            speechToTextModel = ModelCatalog.nemotron.id
        }
        let output =
            configuration.speaks
            ? try outputEngine(for: configuration, language: language, catalog: catalog) : nil
        return VoicePlan(
            mode: configuration.mode, speechToTextModel: speechToTextModel,
            recognitionLanguage: recognitionTag(for: configuration.locale), output: output)
    }

    private static func outputEngine(
        for configuration: LiveSessionConfiguration, language: String, catalog: [VoiceModel]
    ) throws -> SpeechOutputEngine {
        if let id = configuration.textToSpeechModel {
            guard let model = catalog.first(where: { $0.id == id }),
                model.kind == .textToSpeech, let architecture = model.architecture
            else {
                throw ModelSelectionError.unknownModel(id)
            }
            guard model.languages.contains(language) else {
                throw ModelSelectionError.modelDoesNotSpeak(model: id, language: language)
            }
            return .make(
                architecture, modelID: id, voice: configuration.voice, language: language)
        }
        if kokoroVoices[language] != nil {
            return .kokoro(
                modelID: ModelCatalog.kokoro.id, voice: configuration.voice, language: language)
        }
        if ModelCatalog.supertonic.languages.contains(language) {
            return .supertonic(
                modelID: ModelCatalog.supertonic.id, voice: configuration.voice,
                language: language)
        }
        throw ModelSelectionError.unsupportedLanguage(configuration.locale)
    }

    /// The voice a model speaks with when the session names none.
    ///
    /// Kokoro uses its voice for the language (a British one for en-GB) and Supertonic `F1`,
    /// when the model has them; otherwise the first of the model's voices.
    ///
    /// - Parameters:
    ///   - architecture: How the model is built.
    ///   - language: The language code, e.g. "en".
    ///   - locale: The session's locale, e.g. "en-GB".
    ///   - available: The voices the model has.
    /// - Returns: The voice, or `nil` when the model has none.
    public static func defaultVoice(
        architecture: SpeechArchitecture, language: String, locale: String, available: [String]
    ) -> String? {
        let preferred: [String] =
            switch architecture {
            case .kokoro:
                (recognitionTag(for: locale) == "en-GB" ? [britishKokoroVoice] : [])
                    + (kokoroVoices[language].map { [$0] } ?? [])
            case .supertonic:
                [supertonicVoice]
            }
        return preferred.first(where: available.contains) ?? available.sorted().first
    }
}
