import MomoLiveProtocol
import MomoVoice
import SwiftUI

extension LiveEngineChoice {
    var displayName: String {
        switch self {
        case .automatic: L("Automatic", comment: "Live conversation engine")
        case .apple: L("Apple (built in)", comment: "Live conversation engine")
        case .openSource: L("Open source on-device", comment: "Live conversation engine")
        case .cloudRealtime: L("Cloud realtime", comment: "Live conversation engine")
        }
    }

    /// The choices offered in Settings: cloud realtime only with an OpenAI or Gemini key
    /// and outside local-only mode, or while it is the current choice.
    static func offered(includingCloud: Bool) -> [LiveEngineChoice] {
        includingCloud ? allCases : [.automatic, .apple, .openSource]
    }
}

/// Live conversation settings: the switch, the engine, the follow-up window and the open
/// source engine's models.
struct LiveConversationSection: View {
    @Bindable var settings: AppSettings
    var models: LiveVoiceModels?

    private static let followUpChoices: [Double] = [0, 5, 8, 15]

    var body: some View {
        Section {
            Toggle(L("Live conversation"), isOn: $settings.preferences.liveConversation)
            if settings.preferences.liveConversation {
                Picker(L("Engine"), selection: $settings.preferences.liveEngine) {
                    ForEach(LiveEngineChoice.offered(includingCloud: offersCloud)) { choice in
                        Text(verbatim: choice.displayName).tag(choice)
                    }
                }
                Picker(
                    L("Listen for a follow-up"),
                    selection: $settings.preferences.liveFollowUpSeconds
                ) {
                    ForEach(Self.followUpChoices, id: \.self) { seconds in
                        Text(verbatim: followUpName(seconds)).tag(seconds)
                    }
                }
            }
        } header: {
            Text(verbatim: L("Live conversation"))
        } footer: {
            Text(verbatim: footnote)
        }
        if settings.preferences.liveConversation {
            switch settings.preferences.liveEngine {
            case .automatic, .openSource: OpenSourceModelsSection(models: models)
            case .cloudRealtime: CloudRealtimeSection(settings: settings)
            case .apple: EmptyView()
            }
        }
    }

    private var offersCloud: Bool {
        settings.preferences.liveEngine == .cloudRealtime
            || CloudRealtimeSetup.isOffered(settings.preferences) {
                !(settings.keys.key(for: $0) ?? "").isEmpty
            }
    }

    private func followUpName(_ seconds: Double) -> String {
        seconds == 0
            ? L("Don't wait", comment: "Follow-up window")
            : String(format: L("%d seconds", comment: "Follow-up window"), Int(seconds))
    }

    private var footnote: String {
        guard settings.preferences.liveConversation else {
            return L(
                "Momo transcribes what you say, sends it when you pause and reads the whole answer aloud once it has arrived."
            )
        }
        let how = L(
            "Momo talks with you like a person: it starts answering while it still thinks, you can interrupt it at any time, and it keeps listening for a follow-up. Say “thanks, that's all” or press Esc to finish."
        )
        let privacy =
            settings.preferences.liveEngine == .cloudRealtime
            ? L(
                "With cloud realtime voice, your microphone audio goes to the chosen service while the conversation is open."
            )
            : settings.preferences.speechVoice == .openAI
                ? L(
                    "Listening stays on this Mac; with an OpenAI voice, each sentence Momo says is sent to OpenAI."
                )
                : L("Listening and speaking stay on this Mac.")
        return how + " " + privacy
    }
}

/// The cloud realtime engine: the service, its model and voice, what it costs and whether
/// audio may leave the Mac.
private struct CloudRealtimeSection: View {
    @Bindable var settings: AppSettings

    private var provider: RealtimeProviderChoice { settings.preferences.realtimeProvider }

    private var hasKey: Bool {
        !(settings.keys.key(for: provider.keyProviderID) ?? "").isEmpty
    }

    private var model: Binding<String> {
        switch provider {
        case .openAI: $settings.preferences.realtimeOpenAIModel
        case .gemini: $settings.preferences.realtimeGeminiModel
        }
    }

    private var voice: Binding<String> {
        switch provider {
        case .openAI: $settings.preferences.realtimeOpenAIVoice
        case .gemini: $settings.preferences.realtimeGeminiVoice
        }
    }

    /// Whether the user agreed that audio goes to the chosen service.
    private var consent: Binding<Bool> {
        Binding {
            !CloudRealtimeSetup.needsConsent(settings.preferences)
        } set: { allowed in
            if allowed {
                CloudRealtimeSetup.grantConsent(&settings.preferences)
            } else {
                settings.preferences.realtimeConsentProvider = ""
            }
        }
    }

    var body: some View {
        Section {
            Picker(L("Service"), selection: $settings.preferences.realtimeProvider) {
                ForEach(RealtimeProviderChoice.allCases) { choice in
                    Text(verbatim: choice.displayName).tag(choice)
                }
            }
            Picker(L("Model"), selection: model) {
                ForEach(models, id: \.self) { name in
                    Text(verbatim: name).tag(name)
                }
            }
            Picker(L("Voice"), selection: voice) {
                ForEach(provider.voices, id: \.self) { name in
                    Text(verbatim: name.capitalized).tag(name)
                }
            }
            Toggle(L("Allow my microphone audio to leave this Mac"), isOn: consent)
            if settings.preferences.brains.localOnly {
                Text(
                    verbatim: L(
                        "“Keep everything on this Mac” is on, so Momo uses its built-in voice engine instead."
                    )
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if !hasKey {
                Text(
                    verbatim: String(
                        format: L("%@ needs an API key, which you can add in AI settings."),
                        provider.displayName)
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        } header: {
            Text(verbatim: L("Cloud realtime voice"))
        } footer: {
            Text(
                verbatim: RealtimeVoicePrivacy.localizedNotice + " "
                    + L(
                        "The cloud model only talks; Momo's assistant still does the real work. The service bills your key for audio in both directions while a conversation is open, and each session is listed in Privacy."
                    ))
        }
    }

    /// The suggested models, plus a custom one the user set elsewhere.
    private var models: [String] {
        let current = model.wrappedValue
        let suggested = provider.suggestedModels
        return suggested.contains(current) || current.isEmpty ? suggested : suggested + [current]
    }
}

/// The open source engine's models: what they weigh, which languages they speak, and
/// downloading or deleting them. Nothing downloads until the user presses Download.
private struct OpenSourceModelsSection: View {
    var models: LiveVoiceModels?

    var body: some View {
        Section {
            if let models, models.isAvailable {
                content(models)
            } else {
                Text(verbatim: unavailableReason)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(verbatim: L("Open source voice models"))
        } footer: {
            Text(
                verbatim: L(
                    "The open source engine recognises speech, detects when you finish, cancels echo and speaks entirely on this Mac. Its models are downloaded once, only when you press Download. Without them, Momo uses Apple's built-in engine."
                ))
        }
        .task { await models?.refresh() }
    }

    private var unavailableReason: String {
        LiveVoiceHelperClient.isSupportedOnThisMac
            ? L("The open source engine isn't included in this build of Momo.")
            : L("The open source engine needs macOS 15 or later on a Mac with Apple silicon.")
    }

    @ViewBuilder
    private func content(_ models: LiveVoiceModels) -> some View {
        if models.models.isEmpty {
            HStack {
                if models.isLoading {
                    ProgressView().controlSize(.small)
                    Text(verbatim: L("Asking the engine for its models…"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: L("No models listed."))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Try Again")) { Task { await models.refresh() } }
                }
            }
        } else {
            if !models.isReady, models.missingDownloadSize > 0, !models.isDownloading {
                HStack {
                    Text(
                        verbatim: String(
                            format: L("Your language needs %@ of models."),
                            Self.size(models.missingDownloadSize)))
                    Spacer()
                    Button(L("Download All")) { models.downloadRequired() }
                        .buttonStyle(.borderedProminent)
                }
            } else if models.isReady {
                Label(L("Ready for your language"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ForEach(models.models) { model in
                row(model, models: models)
            }
        }
        if let error = models.errorMessage {
            Text(verbatim: error).foregroundStyle(.red).font(.caption)
        }
    }

    private func row(_ model: LiveModelInfo, models: LiveVoiceModels) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: model.name)
                    if model.isRequired {
                        Text(verbatim: L("Needed", comment: "A model the language needs"))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
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
                Button(L("Delete")) { models.delete([model.id]) }
                    .controlSize(.small)
            } else {
                Button(L("Download")) { models.download([model.id]) }
                    .controlSize(.small)
            }
        }
    }

    private func details(_ model: LiveModelInfo) -> String {
        let languages =
            model.languages.isEmpty
            ? L("Many languages")
            : model.languages.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
                .joined(separator: ", ")
        return [kindName(model.kind), Self.size(model.sizeBytes), languages].joined(
            separator: " · ")
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

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
