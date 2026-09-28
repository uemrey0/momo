import Foundation
import MomoVoice

/// The cloud realtime services a live conversation can use.
enum RealtimeProviderChoice: String, Codable, CaseIterable, Identifiable {
    case openAI
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI Realtime"
        case .gemini: "Gemini Live"
        }
    }

    /// The brain whose API key the service uses.
    var keyProviderID: String {
        switch self {
        case .openAI: "openai"
        case .gemini: "gemini-api"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: OpenAIRealtime.defaultModel
        case .gemini: GeminiLive.defaultModel
        }
    }

    /// The models Settings offers, best first.
    var suggestedModels: [String] {
        switch self {
        case .openAI: OpenAIRealtime.suggestedModels
        case .gemini: GeminiLive.suggestedModels
        }
    }

    var voices: [String] {
        switch self {
        case .openAI: OpenAIRealtime.voices
        case .gemini: GeminiLive.voices
        }
    }

    var defaultVoice: String {
        switch self {
        case .openAI: OpenAIRealtime.defaultVoice
        case .gemini: GeminiLive.defaultVoice
        }
    }
}

/// Turns the user's settings and keys into a cloud realtime session, and decides when one
/// may run: only with a key, never in local-only mode, and only after the user agreed that
/// audio leaves the Mac for that provider.
enum CloudRealtimeSetup {
    /// The key ids of the services, in the order Settings suggests them.
    static let keyProviderIDs = RealtimeProviderChoice.allCases.map(\.keyProviderID)

    /// Whether Settings offers the cloud realtime engine: a key for either service exists
    /// and nothing must leave the Mac.
    static func isOffered(_ preferences: Preferences, hasKey: (String) -> Bool) -> Bool {
        !preferences.brains.localOnly && keyProviderIDs.contains(where: hasKey)
    }

    /// The service for the chosen provider with its key, model and voice, or `nil` when it
    /// can't run (no key, or local-only mode).
    static func service(
        _ preferences: Preferences, key: (String) -> String?
    ) -> RealtimeVoiceService? {
        guard !preferences.brains.localOnly else { return nil }
        let provider = preferences.realtimeProvider
        guard let apiKey = key(provider.keyProviderID), !apiKey.isEmpty else { return nil }
        let model = model(preferences)
        switch provider {
        case .openAI: return .openAI(apiKey: apiKey, model: model)
        case .gemini: return .gemini(apiKey: apiKey, model: model)
        }
    }

    /// The chosen model, or the provider's default when none is set.
    static func model(_ preferences: Preferences) -> String {
        let model =
            switch preferences.realtimeProvider {
            case .openAI: preferences.realtimeOpenAIModel
            case .gemini: preferences.realtimeGeminiModel
            }
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? preferences.realtimeProvider.defaultModel : trimmed
    }

    /// The chosen voice, or the provider's default when it isn't one of its voices.
    static func voice(_ preferences: Preferences) -> String {
        let provider = preferences.realtimeProvider
        let voice =
            switch provider {
            case .openAI: preferences.realtimeOpenAIVoice
            case .gemini: preferences.realtimeGeminiVoice
            }
        return provider.voices.contains(voice) ? voice : provider.defaultVoice
    }

    /// Why the cloud realtime engine can't run now.
    enum Unavailable: Equatable {
        /// "Keep everything on this Mac" is on.
        case localOnly
        /// The chosen provider has no API key.
        case missingKey
        /// The last cloud session failed, so this conversation runs on the Mac.
        case recentFailure
    }

    /// Why the cloud realtime engine can't run, or `nil` when it can.
    static func unavailableReason(
        _ preferences: Preferences, key: (String) -> String?, recentFailure: Bool
    ) -> Unavailable? {
        if preferences.brains.localOnly { return .localOnly }
        if service(preferences, key: key) == nil { return .missingKey }
        return recentFailure ? .recentFailure : nil
    }

    /// The live engine that runs for the user's choice. The cloud engine runs only when the
    /// user chose it and it can run; otherwise Momo's voice models do, when they are ready.
    static func selectEngine(
        _ preferences: Preferences, helper: LiveHelperStatus, key: (String) -> String?,
        recentFailure: Bool
    ) -> LiveEngineSelector.Selection {
        LiveEngineSelector.select(
            preferences.liveEngine, helper: helper,
            cloudRealtimeReady: unavailableReason(
                preferences, key: key, recentFailure: recentFailure) == nil)
    }

    /// Whether the user must agree before audio goes to the chosen provider: the first time,
    /// and again whenever the provider changes.
    static func needsConsent(_ preferences: Preferences) -> Bool {
        preferences.realtimeConsentProvider != preferences.realtimeProvider.rawValue
    }

    /// Records that the user agreed to stream audio to the chosen provider.
    static func grantConsent(_ preferences: inout Preferences) {
        preferences.realtimeConsentProvider = preferences.realtimeProvider.rawValue
    }

    /// How the session is set up: Momo's live instructions with the user's personality, the
    /// chosen voice, the conversation language and the `ask_momo` tool.
    static func sessionConfiguration(
        _ preferences: Preferences, locale: Locale = .current
    ) -> RealtimeSessionConfiguration {
        let language = locale.identifier(.bcp47)
        return RealtimeSessionConfiguration(
            instructions: MomoRealtimeAgent.instructions(
                .init(
                    language: language,
                    additionalInstructions: preferences.personality.instruction)),
            voice: voice(preferences), language: language, tools: [MomoRealtimeAgent.askMomo])
    }
}

extension RealtimeVoicePrivacy {
    /// ``notice`` in the user's language, for the consent prompt in the bubble and Settings.
    static var localizedNotice: String {
        L(
            "Live voice with a cloud model streams your microphone audio to the provider while the conversation is open, and sends Momo's answers there to be spoken. The audio leaves your Mac and uses your own API key."
        )
    }
}
