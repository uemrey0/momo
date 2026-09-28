import Foundation
import MomoVoice
import Testing

@testable import MomoApp

@Suite("Cloud realtime setup")
struct CloudRealtimeSetupTests {
    static let keys = ["openai": "sk-test", "gemini-api": "AIza-test"]

    func key(_ keys: [String: String]) -> (String) -> String? { { keys[$0] } }

    @Test("builds the chosen provider's service with its key, model and voice")
    func service() {
        var preferences = Preferences()
        #expect(
            CloudRealtimeSetup.service(preferences, key: key(Self.keys))
                == .openAI(apiKey: "sk-test", model: "gpt-realtime-2.1"))
        preferences.realtimeProvider = .gemini
        preferences.realtimeGeminiModel = "gemini-2.5-flash-native-audio-preview-12-2025"
        #expect(
            CloudRealtimeSetup.service(preferences, key: key(Self.keys))
                == .gemini(
                    apiKey: "AIza-test", model: "gemini-2.5-flash-native-audio-preview-12-2025"))
        preferences.realtimeGeminiModel = "  "
        #expect(CloudRealtimeSetup.model(preferences) == GeminiLive.defaultModel)
        #expect(CloudRealtimeSetup.service(preferences, key: key(["openai": "sk"])) == nil)
    }

    @Test("never runs or is offered in local-only mode, and needs a key")
    func localOnly() {
        var preferences = Preferences()
        #expect(CloudRealtimeSetup.isOffered(preferences) { $0 == "gemini-api" })
        #expect(!CloudRealtimeSetup.isOffered(preferences) { _ in false })
        #expect(
            CloudRealtimeSetup.unavailableReason(preferences, key: key([:]), recentFailure: false)
                == .missingKey)
        preferences.brains.localOnly = true
        #expect(!CloudRealtimeSetup.isOffered(preferences) { _ in true })
        #expect(CloudRealtimeSetup.service(preferences, key: key(Self.keys)) == nil)
        #expect(
            CloudRealtimeSetup.unavailableReason(
                preferences, key: key(Self.keys), recentFailure: false) == .localOnly)
    }

    @Test("Settings lists the cloud engine only when it is offered")
    func offeredChoices() {
        #expect(!LiveEngineChoice.offered(includingCloud: false).contains(.cloudRealtime))
        #expect(LiveEngineChoice.offered(includingCloud: true).last == .cloudRealtime)
    }

    @Test("asks for consent the first time and whenever the provider changes")
    func consent() {
        var preferences = Preferences()
        #expect(CloudRealtimeSetup.needsConsent(preferences))
        CloudRealtimeSetup.grantConsent(&preferences)
        #expect(!CloudRealtimeSetup.needsConsent(preferences))
        preferences.realtimeProvider = .gemini
        #expect(CloudRealtimeSetup.needsConsent(preferences))
        CloudRealtimeSetup.grantConsent(&preferences)
        preferences.realtimeProvider = .openAI
        #expect(CloudRealtimeSetup.needsConsent(preferences))
    }

    @Test("the voice models run by default; a recent cloud failure falls back to them once")
    func engineSelection() {
        var preferences = Preferences()
        let keys = key(Self.keys)
        #expect(
            CloudRealtimeSetup.selectEngine(
                preferences, helper: .ready, key: keys, recentFailure: false
            ).kind == .onDevice)
        #expect(
            CloudRealtimeSetup.selectEngine(
                preferences, helper: .modelsMissing, key: keys, recentFailure: false
            ).kind == nil)
        preferences.liveEngine = .cloudRealtime
        #expect(
            CloudRealtimeSetup.selectEngine(
                preferences, helper: .ready, key: keys, recentFailure: false)
                == .init(kind: .cloudRealtime))
        #expect(
            CloudRealtimeSetup.selectEngine(
                preferences, helper: .ready, key: keys, recentFailure: true)
                == .init(kind: .onDevice, isFallback: true))
        #expect(
            CloudRealtimeSetup.selectEngine(
                preferences, helper: .ready, key: key([:]), recentFailure: false)
                == .init(kind: .onDevice, isFallback: true))
    }

    @Test("sets the session up with Momo's instructions, the voice, the language and ask_momo")
    func sessionConfiguration() {
        var preferences = Preferences()
        preferences.realtimeOpenAIVoice = "not-a-voice"
        let configuration = CloudRealtimeSetup.sessionConfiguration(
            preferences, locale: Locale(identifier: "tr_TR"))
        #expect(configuration.language == "tr-TR")
        #expect(configuration.voice == OpenAIRealtime.defaultVoice)
        #expect(configuration.tools == [MomoRealtimeAgent.askMomo])
        #expect(configuration.instructions.contains("ask_momo"))
        #expect(configuration.instructions.contains(Personality.cheerful.instruction))
    }

    @Test("keeps realtime choices when preferences are decoded")
    func codable() throws {
        var preferences = Preferences()
        preferences.realtimeProvider = .gemini
        preferences.realtimeGeminiVoice = "Puck"
        preferences.realtimeConsentProvider = "gemini"
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded.realtimeProvider == .gemini)
        #expect(decoded.realtimeGeminiVoice == "Puck")
        #expect(!CloudRealtimeSetup.needsConsent(decoded))
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(old.realtimeProvider == .openAI && old.realtimeConsentProvider.isEmpty)
    }
}
