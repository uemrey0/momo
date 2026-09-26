import Foundation
import MomoBrain
import MomoVoice
import Observation

/// Momo's personality, which adds one line to the system prompt.
enum Personality: String, Codable, CaseIterable, Identifiable {
    case cheerful
    case calm
    case witty
    case professional

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cheerful: L("Cheerful", comment: "Personality name")
        case .calm: L("Calm", comment: "Personality name")
        case .witty: L("Witty", comment: "Personality name")
        case .professional: L("Professional", comment: "Personality name")
        }
    }

    /// The instruction given to the model.
    var instruction: String {
        switch self {
        case .cheerful: "Upbeat and encouraging, with the occasional light joke."
        case .calm: "Soft-spoken, patient and reassuring."
        case .witty: "Clever and dry, with playful one-liners, but never mean."
        case .professional: "Focused and efficient. No jokes, no filler."
        }
    }
}

/// Everything the user can change, stored as one JSON document in `UserDefaults`.
struct Preferences: Codable, Equatable {
    var brains = BrainSettings()
    var personality = Personality.cheerful
    var speaksReplies = false
    var sleepDelayMinutes = 2.0
    var hasCompletedOnboarding = false
    var characterID = "classic"
    var reactsToCalendar = true
    var reactsToMusic = true
    var reactsToBattery = true
    var reactsToLateNight = true
    var wakeWordEnabled = false
    var voiceIdentifier = ""
    /// The speech recognition engine for dictation.
    var dictationEngine = DictationEngineChoice.automatic
    /// The OpenAI model used when ``dictationEngine`` is OpenAI.
    var openAITranscriptionModel = OpenAITranscriptionService.defaultModel.rawValue
    /// Which voice reads replies aloud.
    var speechVoice = SpeechVoiceChoice.apple
    /// The OpenAI voice used when ``speechVoice`` is OpenAI.
    var openAIVoice = OpenAISpeechRequest.defaultVoice
    /// Hold the shortcut to talk and let go to send, instead of pressing it once.
    var pushToTalk = false
    /// Open the chat panel for spoken requests instead of answering in the caption bubble.
    var opensChatForSpokenRequests = false
    var mcpServers: [MCPServerConfiguration] = []
    var checksForUpdates = true
    var hidesFromScreenCapture = true
    /// Offer to take notes when a meeting seems to start.
    var offersMeetingNotes = true
    /// Keep meeting audio as WAV files in the meetings folder; off keeps it in memory only.
    var keepsMeetingAudio = false
    /// The language meetings are usually held in, as an ISO 639-1 code; empty follows the
    /// system language.
    var meetingLanguage = ""

    init() {}

    init(from decoder: any Decoder) throws {
        let defaults = Preferences()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        brains = value(.brains, defaults.brains)
        personality = value(.personality, defaults.personality)
        speaksReplies = value(.speaksReplies, defaults.speaksReplies)
        sleepDelayMinutes = value(.sleepDelayMinutes, defaults.sleepDelayMinutes)
        hasCompletedOnboarding = value(.hasCompletedOnboarding, defaults.hasCompletedOnboarding)
        characterID = value(.characterID, defaults.characterID)
        reactsToCalendar = value(.reactsToCalendar, defaults.reactsToCalendar)
        reactsToMusic = value(.reactsToMusic, defaults.reactsToMusic)
        reactsToBattery = value(.reactsToBattery, defaults.reactsToBattery)
        reactsToLateNight = value(.reactsToLateNight, defaults.reactsToLateNight)
        wakeWordEnabled = value(.wakeWordEnabled, defaults.wakeWordEnabled)
        voiceIdentifier = value(.voiceIdentifier, defaults.voiceIdentifier)
        dictationEngine = value(.dictationEngine, defaults.dictationEngine)
        openAITranscriptionModel = value(
            .openAITranscriptionModel, defaults.openAITranscriptionModel)
        speechVoice = value(.speechVoice, defaults.speechVoice)
        openAIVoice = value(.openAIVoice, defaults.openAIVoice)
        pushToTalk = value(.pushToTalk, defaults.pushToTalk)
        opensChatForSpokenRequests = value(
            .opensChatForSpokenRequests, defaults.opensChatForSpokenRequests)
        mcpServers = value(.mcpServers, defaults.mcpServers)
        checksForUpdates = value(.checksForUpdates, defaults.checksForUpdates)
        hidesFromScreenCapture = value(.hidesFromScreenCapture, defaults.hidesFromScreenCapture)
        offersMeetingNotes = value(.offersMeetingNotes, defaults.offersMeetingNotes)
        keepsMeetingAudio = value(.keepsMeetingAudio, defaults.keepsMeetingAudio)
        meetingLanguage = value(.meetingLanguage, defaults.meetingLanguage)
    }
}

/// The app's settings, persisted automatically.
@MainActor
@Observable
final class AppSettings {
    var preferences: Preferences {
        didSet { save() }
    }

    @ObservationIgnored let keys = KeychainStore()
    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "preferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
            let stored = try? JSONDecoder().decode(Preferences.self, from: data)
        {
            preferences = stored
        } else {
            preferences = Preferences()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// `~/Library/Application Support/Momo`
    static var supportDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("Momo", isDirectory: true)
    }

    /// Where meeting audio is kept when the user asks for it, one folder per meeting.
    static var meetingsDirectory: URL {
        supportDirectory.appendingPathComponent("Meetings", isDirectory: true)
    }

    /// The folder CLI brains run in, kept empty so they have nothing to read or change.
    static var cliWorkspace: URL {
        supportDirectory.appendingPathComponent("Workspace", isDirectory: true)
    }

    /// The bundled MCP server, if Momo runs from an app bundle.
    static var mcpServerPath: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/momo-mcp").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The `momo-mcp` that CLI brains launch to reach the app's tool bridge: the bundled one,
    /// or in a development build the one built next to the app's executable.
    static var bridgeRelayPath: String? {
        if let bundled = mcpServerPath { return bundled }
        guard
            let sibling = Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("momo-mcp").path
        else { return nil }
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : nil
    }
}
