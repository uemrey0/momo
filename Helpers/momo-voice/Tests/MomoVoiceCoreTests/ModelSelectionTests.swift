import MomoLiveProtocol
import Testing

@testable import MomoVoiceCore

@Suite("Model selection")
struct ModelSelectionTests {
    @Test("Turkish uses Nemotron and Supertonic")
    func turkish() throws {
        let plan = try #require(ModelSelection.plan(locale: "tr-TR"))
        #expect(plan.speechToTextModel == ModelCatalog.nemotron.id)
        #expect(plan.recognitionLanguage == "tr-TR")
        #expect(plan.output == .supertonic(voice: "F1", language: "tr"))
        #expect(
            plan.requiredModelIDs == [
                "silero-vad", "smart-turn-v3", "nemotron-streaming-multilingual", "supertonic-3",
            ])
    }

    @Test("English uses Kokoro, with a British voice for en-GB")
    func english() throws {
        #expect(
            ModelSelection.plan(locale: "en-US")?.output
                == .kokoro(voice: "af_heart", language: "en"))
        #expect(
            ModelSelection.plan(locale: "en_GB")?.output
                == .kokoro(voice: "bf_emma", language: "en"))
        #expect(ModelSelection.plan(locale: "en")?.recognitionLanguage == "en-US")
    }

    @Test("languages the recognizer does not know are refused")
    func unsupported() {
        #expect(ModelSelection.plan(locale: "sw-KE") == nil)
        #expect(throws: ModelSelectionError.unsupportedLanguage("zh-CN")) {
            try ModelSelection.plan(for: LiveSessionConfiguration(locale: "zh-CN"))
        }
        #expect(!ModelSelection.supportedLanguages.contains("zh"))
        #expect(ModelSelection.supportedLanguages.contains("tr"))
    }

    @Test("requested models and voices are honoured")
    func requested() throws {
        let apple = try ModelSelection.plan(
            for: LiveSessionConfiguration(
                locale: "tr-TR", textToSpeechModel: ModelSelection.appleSpeechID,
                appleVoiceIdentifier: "com.apple.voice.compact.tr-TR.Yelda"))
        #expect(
            apple.output
                == .apple(voiceIdentifier: "com.apple.voice.compact.tr-TR.Yelda", locale: "tr-TR"))
        #expect(!apple.requiredModelIDs.contains("supertonic-3"))

        let voice = try ModelSelection.plan(
            for: LiveSessionConfiguration(
                locale: "en-US", textToSpeechModel: "supertonic-3", voice: "M2"))
        #expect(voice.output == .supertonic(voice: "M2", language: "en"))

        #expect(throws: ModelSelectionError.modelDoesNotSpeak(model: "kokoro-82m", language: "tr"))
        {
            try ModelSelection.plan(
                for: LiveSessionConfiguration(locale: "tr-TR", textToSpeechModel: "kokoro-82m"))
        }
        #expect(throws: ModelSelectionError.unknownModel("whisper")) {
            try ModelSelection.plan(
                for: LiveSessionConfiguration(locale: "tr-TR", speechToTextModel: "whisper"))
        }
    }

    @Test("every catalog model has a license, a source and files")
    func catalog() {
        #expect(Set(ModelCatalog.all.map(\.id)).count == ModelCatalog.all.count)
        for model in ModelCatalog.all {
            #expect(!model.license.isEmpty)
            #expect(model.repository.contains("/"))
            #expect(!model.files.isEmpty)
            #expect(model.sizeBytes > 0)
        }
        #expect(ModelCatalog.model(id: "kokoro-82m") == ModelCatalog.kokoro)
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
