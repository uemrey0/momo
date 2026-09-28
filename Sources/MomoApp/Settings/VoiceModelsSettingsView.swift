import AppKit
import MomoLiveProtocol
import MomoVoice
import SwiftUI

/// Momo's voice models: whether they are ready for the Mac's language, the model and voice
/// Momo speaks with, the models Momo suggests (downloaded only when the user asks), and
/// models and voices the user adds from files.
struct VoiceModelsSection: View {
    @Bindable var settings: AppSettings
    var models: LiveVoiceModels?
    /// Loads the models after the choice changed, and tests the voice.
    var voice: VoiceController?

    @State private var importMessage: String?
    @State private var importFailed = false

    /// The language the user speaks to Momo, e.g. "tr".
    private var language: String {
        VoiceController.voiceLocale(settings.preferences.voiceLanguage).language.languageCode?
            .identifier ?? "en"
    }

    /// The languages the voice models understand, by code.
    private func languages(_ models: LiveVoiceModels) -> [String] {
        let known =
            models.languages.isEmpty
            ? [
                "ar", "de", "en", "es", "fr", "hi", "it", "ja", "ko", "nl", "pt", "ru", "tr", "uk",
                "vi",
            ]
            : models.languages
        return known.sorted { languageName($0) < languageName($1) }
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private var macLanguageName: String {
        languageName(Locale.current.language.languageCode?.identifier ?? "en")
    }

    /// Which language the user speaks; changing it loads the models for it.
    private var languageChoice: Binding<String> {
        Binding {
            settings.preferences.voiceLanguage
        } set: { code in
            guard code != settings.preferences.voiceLanguage else { return }
            settings.preferences.voiceLanguage = code
            settings.preferences.voiceModel = ""
            settings.preferences.voiceName = ""
            Task { await voice?.prepareVoiceModels() }
        }
    }

    var body: some View {
        Section {
            if let models, models.isAvailable {
                Picker(L("You speak"), selection: languageChoice) {
                    Text(verbatim: String(format: L("The Mac's language (%@)"), macLanguageName))
                        .tag("")
                    ForEach(languages(models), id: \.self) { code in
                        Text(verbatim: languageName(code)).tag(code)
                    }
                }
                status(models)
                if !models.models.isEmpty {
                    choice(models)
                }
            } else {
                Text(verbatim: unavailableReason)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(verbatim: L("Voice models"))
        } footer: {
            Text(
                verbatim: L(
                    "Momo listens, recognises speech, knows when you finish and speaks entirely on this Mac with these models. Without them, voice mode stays off. Models are downloaded once, only when you press Download."
                ))
        }
        .task { await models?.refresh() }
        if let models, models.isAvailable, !models.models.isEmpty {
            library(models)
        }
    }

    private var unavailableReason: String {
        LiveVoiceHelperClient.isSupportedOnThisMac
            ? L("Momo's voice engine isn't included in this build of Momo.")
            : L("Momo's voice models need macOS 15 or later on a Mac with Apple silicon.")
    }

    // MARK: - Status

    @ViewBuilder
    private func status(_ models: LiveVoiceModels) -> some View {
        if models.models.isEmpty {
            HStack {
                if models.isLoading {
                    ProgressView().controlSize(.small)
                    Text(verbatim: L("Asking the voice engine for its models…"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: L("No models listed."))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Try Again")) { Task { await models.refresh() } }
                }
            }
        } else if !models.isReady {
            HStack {
                Text(
                    verbatim: models.isDownloading
                        ? L("Downloading your language's models…")
                        : String(
                            format: L("Your language needs %@ of models."),
                            Self.size(models.missingDownloadSize)))
                Spacer()
                if !models.isDownloading {
                    Button(L("Download All")) { models.downloadRequired() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if models.status == .preparing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: L("Getting the models ready for their first use…"))
                    .foregroundStyle(.secondary)
            }
        } else {
            Label(L("Ready for your language"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        if let error = models.errorMessage {
            Text(verbatim: error).foregroundStyle(.red).font(.caption)
        }
    }

    // MARK: - Model and voice

    private func choice(_ models: LiveVoiceModels) -> some View {
        let speaking = models.speechModels(speaking: language)
        let current =
            speaking.first { $0.id == settings.preferences.voiceModel }
            ?? models.speakingModel
        return Group {
            Picker(L("Speaks with"), selection: modelChoice) {
                Text(verbatim: L("Automatic (best for your language)")).tag("")
                ForEach(speaking) { model in
                    Text(verbatim: model.name).tag(model.id)
                }
                // A chosen model that was deleted or doesn't speak the language stays visible.
                if !settings.preferences.voiceModel.isEmpty,
                    !speaking.contains(where: { $0.id == settings.preferences.voiceModel })
                {
                    Text(verbatim: L("Not available")).tag(settings.preferences.voiceModel)
                }
            }
            if let current, !current.voices.isEmpty {
                Picker(L("Voice"), selection: $settings.preferences.voiceName) {
                    Text(verbatim: L("Default")).tag("")
                    ForEach(current.voices, id: \.self) { name in
                        Text(verbatim: Self.voiceName(name, custom: current.customVoices))
                            .tag(name)
                    }
                }
                HStack {
                    Button(L("Test Voice")) {
                        voice?.speak(
                            L("Hi! I'm Momo. This is how I sound."), withVoiceModels: true)
                    }
                    .disabled(!models.isReady)
                    Button(L("Add Voice File…")) { addVoice(to: current, models: models) }
                        .disabled(models.isImporting)
                    if current.customVoices.contains(settings.preferences.voiceName) {
                        Button(L("Delete Voice")) {
                            models.deleteVoice(settings.preferences.voiceName, of: current.id)
                            settings.preferences.voiceName = ""
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var modelChoice: Binding<String> {
        Binding {
            settings.preferences.voiceModel
        } set: { id in
            guard id != settings.preferences.voiceModel else { return }
            settings.preferences.voiceModel = id
            settings.preferences.voiceName = ""
            Task { await voice?.prepareVoiceModels() }
        }
    }

    // MARK: - Library

    private func library(_ models: LiveVoiceModels) -> some View {
        Section {
            ForEach(models.models) { model in
                row(model, models: models)
            }
            HStack {
                Button(L("Add Model Folder…")) { addModel(models) }
                    .disabled(models.isImporting)
                if models.isImporting {
                    ProgressView().controlSize(.small)
                }
            }
            if let importMessage {
                Text(verbatim: importMessage)
                    .font(.caption)
                    .foregroundStyle(importFailed ? .red : .secondary)
            }
        } header: {
            Text(verbatim: L("Suggested and added models"))
        } footer: {
            Text(
                verbatim: L(
                    "You can add a speech model of your own: a folder with a Kokoro or Supertonic Core ML conversion, or a voice style file (.json) for the model Momo speaks with. Momo copies what you add."
                ))
        }
    }

    private func row(_ model: LiveModelInfo, models: LiveVoiceModels) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: model.name)
                    if model.isCustom {
                        badge(L("Added by you", comment: "A voice model the user added"))
                    } else if model.isRequired {
                        badge(L("Needed", comment: "A model the language needs"))
                    }
                }
                Text(verbatim: details(model))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = models.progress[model.id] {
                ProgressView(value: progress)
                    .frame(width: 90)
                Text(verbatim: progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if model.isDownloaded {
                Button(L("Delete")) {
                    if model.id == settings.preferences.voiceModel {
                        settings.preferences.voiceModel = ""
                        settings.preferences.voiceName = ""
                    }
                    models.delete([model.id])
                }
                .controlSize(.small)
            } else {
                Button(L("Download")) { models.download([model.id]) }
                    .controlSize(.small)
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    private func details(_ model: LiveModelInfo) -> String {
        let languages =
            model.languages.isEmpty
            ? L("Many languages")
            : model.languages.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
                .joined(separator: ", ")
        var parts = [kindName(model.kind), Self.size(model.sizeBytes), languages]
        if model.kind == .textToSpeech, !model.voices.isEmpty {
            parts.insert(
                String(format: L("%d voices", comment: "Voices of a model"), model.voices.count),
                at: 2)
        }
        return parts.joined(separator: " · ")
    }

    private func kindName(_ kind: LiveModelKind) -> String {
        switch kind {
        case .speechToText: L("Speech recognition", comment: "Model kind")
        case .textToSpeech: L("Voice", comment: "Model kind")
        case .voiceActivity: L("Voice activity", comment: "Model kind")
        case .turnDetection: L("Turn detection", comment: "Model kind")
        case .echoCancellation: L("Echo cancellation", comment: "Model kind")
        }
    }

    // MARK: - Adding

    private func addModel(_ models: LiveVoiceModels) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Add Model")
        panel.message = L("Choose a folder with a Kokoro or Supertonic Core ML conversion.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            switch await models.importModel(from: url) {
            case .success(let id):
                importFailed = false
                let name = models.models.first { $0.id == id }?.name ?? url.lastPathComponent
                importMessage = String(format: L("Added %@."), name)
            case .failure(let error):
                importFailed = true
                importMessage = error.message
            }
        }
    }

    private func addVoice(to model: LiveModelInfo, models: LiveVoiceModels) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = L("Add Voice")
        panel.message = String(format: L("Choose a voice style file for %@."), model.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            switch await models.importVoice(from: url, into: model.id) {
            case .success(let voice):
                importFailed = false
                importMessage = String(format: L("Added the voice %@."), voice)
                if settings.preferences.voiceModel.isEmpty {
                    settings.preferences.voiceModel = model.id
                }
                settings.preferences.voiceName = voice
                Task { await self.voice?.prepareVoiceModels() }
            case .failure(let error):
                importFailed = true
                importMessage = error.message
            }
        }
    }

    // MARK: - Names

    /// A voice's name for people: Kokoro's "af_heart" reads "Heart (American, female)",
    /// Supertonic's "F1" reads "Female 1"; voices the user added keep their file name.
    static func voiceName(_ id: String, custom: [String]) -> String {
        if custom.contains(id) { return id }
        let parts = id.split(separator: "_", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].count == 2 {
            let accent: String? =
                switch parts[0].first {
                case "a": L("American", comment: "Voice accent")
                case "b": L("British", comment: "Voice accent")
                case "e": L("Spanish", comment: "Voice accent")
                case "f": L("French", comment: "Voice accent")
                case "h": L("Hindi", comment: "Voice accent")
                case "i": L("Italian", comment: "Voice accent")
                case "j": L("Japanese", comment: "Voice accent")
                case "p": L("Brazilian", comment: "Voice accent")
                case "z": L("Chinese", comment: "Voice accent")
                default: nil
                }
            let gender =
                parts[0].last == "f"
                ? L("female", comment: "Voice gender") : L("male", comment: "Voice gender")
            let name = parts[1].capitalized
            if let accent { return "\(name) (\(accent), \(gender))" }
            return "\(name) (\(gender))"
        }
        if let first = id.first, "FM".contains(first), let number = Int(id.dropFirst()) {
            let format =
                first == "F"
                ? L("Female %d", comment: "Supertonic voice")
                : L("Male %d", comment: "Supertonic voice")
            return String(format: format, number)
        }
        return id
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
