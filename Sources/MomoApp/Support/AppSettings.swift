import Foundation
import MomoBrain
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

    /// The folder CLI brains run in, kept empty so they have nothing to read or change.
    static var cliWorkspace: URL {
        supportDirectory.appendingPathComponent("Workspace", isDirectory: true)
    }

    /// The bundled MCP server, if Momo runs from an app bundle.
    static var mcpServerPath: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/momo-mcp").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
