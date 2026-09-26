import AVFoundation
import MomoVoice
import SwiftUI

extension DictationEngineChoice {
    var displayName: String {
        switch self {
        case .automatic: L("Automatic (on this Mac)", comment: "Speech engine")
        case .appleSpeech: L("Apple Speech", comment: "Speech engine")
        case .openAI: L("OpenAI", comment: "Speech engine")
        case .gemini: L("Gemini", comment: "Speech engine")
        }
    }

    /// The brain whose API key the engine uses.
    var keyProviderID: String? {
        switch self {
        case .openAI: "openai"
        case .gemini: "gemini-api"
        default: nil
        }
    }
}

extension SpeechVoiceChoice {
    var displayName: String {
        switch self {
        case .apple: L("Mac voices", comment: "Voice engine")
        case .openAI: L("OpenAI voices", comment: "Voice engine")
        }
    }
}

/// Voice settings: reading replies aloud, the voice, the speech engine and the wake word.
struct VoiceSettingsView: View {
    @Bindable var settings: AppSettings
    var model: AppModel

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    private var voices: [VoiceDescriptor] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return SpeechSynthesizer.voices
            .filter { $0.language.hasPrefix(language) || $0.language.hasPrefix("en") }
            .sorted {
                ($0.language, -$0.quality.rawValue, $0.name) < (
                    $1.language, -$1.quality.rawValue, $1.name
                )
            }
    }

    private func hasKey(_ providerID: String) -> Bool {
        !(settings.keys.key(for: providerID) ?? "").isEmpty
    }

    var body: some View {
        Form {
            repliesSection
            listeningSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Replies

    private var repliesSection: some View {
        Section {
            Toggle(L("Read every reply aloud"), isOn: $settings.preferences.speaksReplies)
            Picker(L("Voices"), selection: $settings.preferences.speechVoice) {
                ForEach(SpeechVoiceChoice.allCases) { choice in
                    Text(verbatim: choice.displayName).tag(choice)
                }
            }
            switch settings.preferences.speechVoice {
            case .apple:
                Picker(L("Voice"), selection: $settings.preferences.voiceIdentifier) {
                    Text(verbatim: L("Automatic (best voice for each language)")).tag("")
                    ForEach(voices) { voice in
                        Text(
                            verbatim:
                                "\(voice.name) · \(voice.language)\(voice.quality > .standard ? " ★" : "")"
                        )
                        .tag(voice.id)
                    }
                }
            case .openAI:
                Picker(L("Voice"), selection: $settings.preferences.openAIVoice) {
                    ForEach(OpenAISpeechRequest.voices, id: \.self) { voice in
                        Text(verbatim: voice.capitalized).tag(voice)
                    }
                }
                if !hasKey("openai") {
                    missingKey
                }
            }
            Button(L("Test voice")) {
                model.voice?.speak(L("Hi! I'm Momo. This is how I sound."))
            }
        } footer: {
            switch settings.preferences.speechVoice {
            case .apple:
                Text(
                    verbatim: L(
                        "Replies to spoken messages are always read aloud. Download better voices in System Settings → Accessibility → Spoken Content."
                    ))
            case .openAI:
                Text(
                    verbatim: L(
                        "OpenAI voices sound more natural, but every reply Momo reads aloud is sent to OpenAI with your API key, and each one is listed in Privacy. If OpenAI can't be reached, Momo uses a Mac voice."
                    ))
            }
        }
    }

    // MARK: - Listening

    private var listeningSection: some View {
        Section {
            LabeledContent(L("Talk to Momo")) {
                Text(verbatim: "⌥ ⇧ Space").font(.system(.body, design: .monospaced))
            }
            Picker(L("Speech recognition"), selection: $settings.preferences.dictationEngine) {
                ForEach(DictationEngineChoice.allCases) { choice in
                    Text(verbatim: choice.displayName).tag(choice)
                }
            }
            if settings.preferences.dictationEngine == .openAI {
                Picker(L("Model"), selection: $settings.preferences.openAITranscriptionModel) {
                    ForEach(OpenAITranscriptionService.Model.dictationModels) { model in
                        Text(verbatim: model.rawValue).tag(model.rawValue)
                    }
                }
            }
            if let provider = settings.preferences.dictationEngine.keyProviderID,
                !hasKey(provider)
            {
                missingKey
            }
            Toggle(L("Listen for “Hey Momo”"), isOn: $settings.preferences.wakeWordEnabled)
                .onChange(of: settings.preferences.wakeWordEnabled) {
                    model.voice?.startWakeWordIfEnabled()
                }
            if let error = model.voice?.errorMessage {
                Text(verbatim: error).foregroundStyle(.red).font(.caption)
            }
        } header: {
            Text(verbatim: L("Speaking to Momo"))
        } footer: {
            Text(verbatim: listeningFootnote)
        }
    }

    private var listeningFootnote: String {
        let wakeWord = L(
            "With “Hey Momo” on, the microphone stays on while Momo listens for its name (always on this Mac), and macOS shows the microphone indicator."
        )
        let engine =
            switch settings.preferences.dictationEngine {
            case .automatic:
                DictationEngineSelector.isSpeechAnalyzerAvailable
                    ? L(
                        "Speech is recognised on this Mac with Apple's newest speech model, downloaded once per language."
                    )
                    : L("Speech is recognised on this Mac.")
            case .appleSpeech:
                L(
                    "Speech is recognised with Apple Speech, on this Mac whenever the language allows it."
                )
            case .openAI, .gemini:
                L(
                    "What you say is recorded until you pause, then sent to the service with your API key and listed in Privacy. If it fails, Momo recognises the recording on this Mac instead."
                )
            }
        return engine + " " + wakeWord
    }

    private var missingKey: some View {
        HStack {
            Text(verbatim: L("This needs an API key, which you can add in AI settings."))
                .font(.caption)
                .foregroundStyle(.orange)
            Spacer()
            Button(L("Open AI Settings")) { model.settingsNavigation.pane = .ai }
                .controlSize(.small)
        }
    }
}
