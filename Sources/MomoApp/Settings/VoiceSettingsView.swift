import AVFoundation
import MomoVoice
import SwiftUI

extension DictationEngineChoice {
    var displayName: String {
        switch self {
        case .onDevice: L("Momo's voice models (on this Mac)", comment: "Speech engine")
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
        case .onDevice: L("Momo's voice models", comment: "Voice engine")
        case .openAI: L("OpenAI voices", comment: "Voice engine")
        }
    }
}

/// Voice settings: Momo's voice models, reading replies aloud, voice mode, live conversation,
/// the speech engine and the wake word.
struct VoiceSettingsView: View {
    @Bindable var settings: AppSettings
    var model: AppModel

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    private func hasKey(_ providerID: String) -> Bool {
        !(settings.keys.key(for: providerID) ?? "").isEmpty
    }

    var body: some View {
        Form {
            VoiceModelsSection(
                settings: settings, models: model.voice?.liveModels, voice: model.voice)
            repliesSection
            voiceModeSection
            LiveConversationSection(settings: settings)
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
            if settings.preferences.speechVoice == .openAI {
                Picker(L("Voice"), selection: $settings.preferences.openAIVoice) {
                    ForEach(OpenAISpeechRequest.voices, id: \.self) { voice in
                        Text(verbatim: voice.capitalized).tag(voice)
                    }
                }
                if !hasKey("openai") {
                    missingKey
                }
                Button(L("Test voice")) {
                    model.voice?.speak(L("Hi! I'm Momo. This is how I sound."))
                }
            }
        } header: {
            Text(verbatim: L("Replies"))
        } footer: {
            switch settings.preferences.speechVoice {
            case .onDevice:
                Text(
                    verbatim: L(
                        "Replies to spoken messages are always read aloud, with the voice chosen under Voice models."
                    ))
            case .openAI:
                Text(
                    verbatim: L(
                        "Every reply Momo reads aloud is sent to OpenAI with your API key, and each one is listed in Privacy. If OpenAI can't be reached, Momo uses its own voice models."
                    ))
            }
        }
    }

    // MARK: - Listening

    private var voiceModeSection: some View {
        Section {
            ShortcutRecorderRow(action: .talk, center: model.shortcuts)
            Toggle(L("Hold the shortcut to talk"), isOn: $settings.preferences.pushToTalk)
            Toggle(
                L("Open the chat for spoken requests"),
                isOn: $settings.preferences.opensChatForSpokenRequests)
        } header: {
            Text(verbatim: L("Voice mode"))
        } footer: {
            Text(verbatim: voiceModeFootnote)
        }
    }

    private var voiceModeFootnote: String {
        let shortcut = settings.preferences.shortcuts.talk?.displayString
        switch (settings.preferences.pushToTalk, shortcut) {
        case (true, let shortcut?):
            return String(
                format: L(
                    "Hold %@ while you speak and let go to send. Momo answers in a small caption under the notch; click it to open the chat, or press Esc to cancel."
                ), shortcut)
        case (true, nil):
            return L(
                "Record a shortcut above, then hold it while you speak and let go to send. Momo answers in a small caption under the notch; click it to open the chat, or press Esc to cancel."
            )
        case (false, let shortcut?):
            return String(
                format: L(
                    "Press %@ or say “Hey Momo”, then speak; Momo sends when you pause. It answers in a small caption under the notch; click it to open the chat, or press Esc or the shortcut again to cancel."
                ), shortcut)
        case (false, nil):
            return L(
                "Say “Hey Momo”, then speak; Momo sends when you pause. It answers in a small caption under the notch; click it to open the chat, or press Esc to cancel."
            )
        }
    }

    private var listeningSection: some View {
        Section {
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
            case .onDevice:
                L("Speech is recognised on this Mac with Momo's voice models.")
            case .openAI, .gemini:
                L(
                    "What you say is recorded until you pause, then sent to the service with your API key and listed in Privacy. If it fails, Momo recognises the recording on this Mac with its voice models instead."
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
