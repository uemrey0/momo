import MomoLiveProtocol
import Testing

@testable import MomoVoiceCore

@Suite("Model selection")
struct ModelSelectionTests {
    /// A Kokoro model the user added.
    static let customKokoro = VoiceModel(
        id: "custom-my-kokoro-a1b2c3", kind: .textToSpeech, name: "My Kokoro",
        languages: ModelCatalog.kokoro.languages, sizeBytes: 1, license: "", repository: "",
        files: [], architecture: .kokoro, isCustom: true)

    @Test("Turkish uses Nemotron and Supertonic")
    func turkish() throws {
        let plan = try #require(ModelSelection.plan(locale: "tr-TR"))
        #expect(plan.mode == .conversation)
        #expect(plan.speechToTextModel == ModelCatalog.nemotron.id)
        #expect(plan.recognitionLanguage == "tr-TR")
        #expect(plan.output == .supertonic(modelID: "supertonic-3", voice: nil, language: "tr"))
        #expect(
            plan.requiredModelIDs == [
                "silero-vad", "smart-turn-v3", "nemotron-streaming-multilingual", "supertonic-3",
            ])
    }

    @Test("English uses Kokoro and keeps the region for the voice")
    func english() throws {
        #expect(
            ModelSelection.plan(locale: "en-US")?.output
                == .kokoro(modelID: "kokoro-82m", voice: nil, language: "en"))
        #expect(ModelSelection.plan(locale: "en_GB")?.recognitionLanguage == "en-GB")
        #expect(ModelSelection.plan(locale: "en")?.recognitionLanguage == "en-US")
    }

    @Test("languages the recognizer does not know are refused for listening")
    func unsupported() {
        #expect(ModelSelection.plan(locale: "sw-KE") == nil)
        #expect(throws: ModelSelectionError.unsupportedLanguage("zh-CN")) {
            try ModelSelection.plan(for: LiveSessionConfiguration(locale: "zh-CN"))
        }
        #expect(throws: ModelSelectionError.unsupportedLanguage("zh-CN")) {
            try ModelSelection.plan(for: LiveSessionConfiguration(locale: "zh-CN", mode: .listen))
        }
        #expect(!ModelSelection.supportedLanguages.contains("zh"))
        #expect(ModelSelection.supportedLanguages.contains("tr"))
        #expect(ModelSelection.supportedLanguages == ModelCatalog.nemotron.languages)
        #expect(ModelSelectionError.unsupportedLanguage("xx").description.contains("understands"))
    }

    @Test("a listening session needs no speech model")
    func listen() throws {
        let plan = try ModelSelection.plan(
            for: LiveSessionConfiguration(locale: "tr-TR", mode: .listen))
        #expect(plan.output == nil)
        #expect(plan.speechToTextModel == ModelCatalog.nemotron.id)
        #expect(
            plan.requiredModelIDs == [
                "silero-vad", "smart-turn-v3", "nemotron-streaming-multilingual",
            ])
        // The speech model is not even looked at.
        let ignored = try ModelSelection.plan(
            for: LiveSessionConfiguration(
                locale: "tr-TR", textToSpeechModel: "nowhere", mode: .listen))
        #expect(ignored.output == nil)
    }

    @Test("a speaking session needs only its speech model, in any language it speaks")
    func speak() throws {
        let plan = try ModelSelection.plan(
            for: LiveSessionConfiguration(locale: "tr-TR", mode: .speak))
        #expect(plan.speechToTextModel == nil)
        #expect(plan.requiredModelIDs == ["supertonic-3"])

        // Nemotron does not understand Chinese or Bulgarian, but they can be read aloud.
        let chinese = try ModelSelection.plan(
            for: LiveSessionConfiguration(locale: "zh-CN", mode: .speak))
        #expect(chinese.output == .kokoro(modelID: "kokoro-82m", voice: nil, language: "zh"))
        let bulgarian = try ModelSelection.plan(
            for: LiveSessionConfiguration(locale: "bg-BG", mode: .speak))
        #expect(bulgarian.requiredModelIDs == ["supertonic-3"])

        #expect(throws: ModelSelectionError.unsupportedLanguage("sw-KE")) {
            try ModelSelection.plan(for: LiveSessionConfiguration(locale: "sw-KE", mode: .speak))
        }
    }

    @Test("requested models and voices are honoured")
    func requested() throws {
        let voice = try ModelSelection.plan(
            for: LiveSessionConfiguration(
                locale: "en-US", textToSpeechModel: "supertonic-3", voice: "M2"))
        #expect(voice.output == .supertonic(modelID: "supertonic-3", voice: "M2", language: "en"))

        #expect(throws: ModelSelectionError.modelDoesNotSpeak(model: "kokoro-82m", language: "tr"))
        {
            try ModelSelection.plan(
                for: LiveSessionConfiguration(locale: "tr-TR", textToSpeechModel: "kokoro-82m"))
        }
        #expect(throws: ModelSelectionError.unknownModel("whisper")) {
            try ModelSelection.plan(
                for: LiveSessionConfiguration(locale: "tr-TR", speechToTextModel: "whisper"))
        }
        #expect(throws: ModelSelectionError.unknownModel("apple-speech")) {
            try ModelSelection.plan(
                for: LiveSessionConfiguration(locale: "tr-TR", textToSpeechModel: "apple-speech"))
        }
        // A model that does not speak cannot be the speech model.
        #expect(throws: ModelSelectionError.unknownModel("silero-vad")) {
            try ModelSelection.plan(
                for: LiveSessionConfiguration(locale: "en-US", textToSpeechModel: "silero-vad"))
        }
    }

    @Test("models the user added can be chosen when the catalog has them")
    func customModels() throws {
        let catalog = ModelCatalog.all + [Self.customKokoro]
        let configuration = LiveSessionConfiguration(
            locale: "fr-FR", textToSpeechModel: Self.customKokoro.id, voice: "my_voice")
        let plan = try ModelSelection.plan(for: configuration, catalog: catalog)
        #expect(
            plan.output
                == .kokoro(modelID: Self.customKokoro.id, voice: "my_voice", language: "fr"))
        #expect(plan.requiredModelIDs.last == Self.customKokoro.id)

        #expect(throws: ModelSelectionError.unknownModel(Self.customKokoro.id)) {
            try ModelSelection.plan(for: configuration)
        }
        #expect(
            throws: ModelSelectionError.modelDoesNotSpeak(
                model: Self.customKokoro.id, language: "tr")
        ) {
            try ModelSelection.plan(
                for: LiveSessionConfiguration(
                    locale: "tr-TR", textToSpeechModel: Self.customKokoro.id),
                catalog: catalog)
        }
    }

    @Test("default voices follow the language and what the model has")
    func defaultVoices() {
        let kokoroVoices = ["af_heart", "bf_emma", "ff_siwis", "zz_last"]
        #expect(
            ModelSelection.defaultVoice(
                architecture: .kokoro, language: "en", locale: "en-US", available: kokoroVoices)
                == "af_heart")
        #expect(
            ModelSelection.defaultVoice(
                architecture: .kokoro, language: "en", locale: "en_GB", available: kokoroVoices)
                == "bf_emma")
        #expect(
            ModelSelection.defaultVoice(
                architecture: .kokoro, language: "fr", locale: "fr-FR", available: kokoroVoices)
                == "ff_siwis")
        // A custom model without the usual voices falls back to its first voice.
        #expect(
            ModelSelection.defaultVoice(
                architecture: .kokoro, language: "en", locale: "en-GB",
                available: ["zeta", "alpha"]) == "alpha")
        #expect(
            ModelSelection.defaultVoice(
                architecture: .supertonic, language: "tr", locale: "tr-TR",
                available: ["M1", "F2", "F1"]) == "F1")
        #expect(
            ModelSelection.defaultVoice(
                architecture: .supertonic, language: "tr", locale: "tr-TR",
                available: ["M1", "F2"]) == "F2")
        #expect(
            ModelSelection.defaultVoice(
                architecture: .supertonic, language: "tr", locale: "tr-TR", available: [])
                == nil)
    }

    @Test("every catalog model has a license, a source and files")
    func catalog() {
        #expect(Set(ModelCatalog.all.map(\.id)).count == ModelCatalog.all.count)
        for model in ModelCatalog.all {
            #expect(!model.license.isEmpty)
            #expect(model.repository.contains("/"))
            #expect(!model.files.isEmpty)
            #expect(model.sizeBytes > 0)
            #expect(!model.isCustom)
            #expect((model.architecture != nil) == (model.kind == .textToSpeech))
        }
        #expect(ModelCatalog.model(id: "kokoro-82m") == ModelCatalog.kokoro)
        #expect(SpeechArchitecture.supertonic.builtInModel == ModelCatalog.supertonic)
    }

    @Test("model descriptions carry voices and whether the user added them")
    func info() {
        let info = Self.customKokoro.info(
            isDownloaded: true, isRequired: false, voices: ["a", "b"], customVoices: ["b"])
        #expect(info.isCustom)
        #expect(info.voices == ["a", "b"])
        #expect(info.customVoices == ["b"])
        #expect(!ModelCatalog.nemotron.info(isDownloaded: false, isRequired: true).isCustom)
    }

    @Test("language codes and tags are normalised")
    func tags() {
        #expect(ModelSelection.languageCode(of: "zh_Hans_CN") == "zh")
        #expect(ModelSelection.languageCode(of: "TR") == "tr")
        #expect(ModelSelection.recognitionTag(for: "tr") == "tr-TR")
        #expect(ModelSelection.recognitionTag(for: "pt_pt") == "pt-PT")
        #expect(ModelSelection.recognitionTag(for: "pt") == "pt-BR")
    }
}
