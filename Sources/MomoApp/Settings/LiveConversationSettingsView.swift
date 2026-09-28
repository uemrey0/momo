import MomoLiveProtocol
import MomoVoice
import SwiftUI

extension LiveEngineChoice {
    var displayName: String {
        switch self {
        case .onDevice: L("Momo's voice models (on this Mac)", comment: "Live conversation engine")
        case .cloudRealtime: L("Cloud realtime", comment: "Live conversation engine")
        }
    }

    /// The choices offered in Settings: cloud realtime only with an OpenAI or Gemini key
    /// and outside local-only mode, or while it is the current choice.
    static func offered(includingCloud: Bool) -> [LiveEngineChoice] {
        includingCloud ? allCases : [.onDevice]
    }
}

/// Live conversation settings: the switch, the engine and the follow-up window.
struct LiveConversationSection: View {
    @Bindable var settings: AppSettings

    private static let followUpChoices: [Double] = [0, 5, 8, 15]

    var body: some View {
        Section {
            Toggle(L("Live conversation"), isOn: $settings.preferences.liveConversation)
            if settings.preferences.liveConversation {
                if offersCloud {
                    Picker(L("Engine"), selection: $settings.preferences.liveEngine) {
                        ForEach(LiveEngineChoice.offered(includingCloud: true)) { choice in
                            Text(verbatim: choice.displayName).tag(choice)
                        }
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
        if settings.preferences.liveConversation, settings.preferences.liveEngine == .cloudRealtime
        {
            CloudRealtimeSection(settings: settings)
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
            : L(
                "Listening and speaking stay on this Mac, with Momo's voice models. A live conversation always speaks with them, even when replies are read with an OpenAI voice."
            )
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
