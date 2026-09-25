import AVFoundation
import MomoVoice
import SwiftUI

/// Voice settings: reading replies aloud, the voice, and the wake word.
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

    var body: some View {
        Form {
            Section {
                Toggle(L("Read every reply aloud"), isOn: $settings.preferences.speaksReplies)
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
                Button(L("Test voice")) {
                    model.voice?.speak(L("Hi! I'm Momo. This is how I sound."))
                }
            } footer: {
                Text(
                    verbatim: L(
                        "Replies to spoken messages are always read aloud. Download better voices in System Settings → Accessibility → Spoken Content."
                    ))
            }
            Section {
                LabeledContent(L("Talk to Momo")) {
                    Text(verbatim: "⌥ ⇧ Space").font(.system(.body, design: .monospaced))
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
                Text(
                    verbatim: L(
                        "Speech is recognised on this Mac. With “Hey Momo” on, the microphone stays on while Momo listens for its name, and macOS shows the microphone indicator."
                    ))
            }
        }
        .formStyle(.grouped)
    }
}
