import MomoBrain
import SwiftUI

/// A way for Momo to think, as the user sees it in Settings. One option can cover several
/// providers; Gemini, for example, works with a free key or with the Gemini CLI.
enum BrainOption: String, CaseIterable, Identifiable {
    case appleIntelligence, ollama, lmStudio, chatGPT, gemini, claude, openAI, openRouter

    var id: String { rawValue }

    /// The groups the AI page shows, in order.
    enum Group: CaseIterable {
        case onThisMac, yourPlan, apiKey

        var title: String {
            switch self {
            case .onThisMac: L("Free, on this Mac")
            case .yourPlan: L("Use an account you already have")
            case .apiKey: L("Pay as you go with an API key")
            }
        }

        var footer: String {
            switch self {
            case .onThisMac:
                L("Private and free. Nothing you say leaves your Mac.")
            case .yourPlan:
                L("Momo borrows the plan you already have. It asks before sending anything.")
            case .apiKey:
                L("You pay the provider for what you use. Keys stay in your Keychain.")
            }
        }

        var options: [BrainOption] {
            BrainOption.allCases.filter { $0.group == self }
        }
    }

    var group: Group {
        switch self {
        case .appleIntelligence, .ollama, .lmStudio: .onThisMac
        case .chatGPT, .gemini: .yourPlan
        case .claude, .openAI, .openRouter: .apiKey
        }
    }

    /// The providers behind this option.
    var providerIDs: [String] {
        switch self {
        case .appleIntelligence: [AppleIntelligence.providerID]
        case .ollama: ["ollama"]
        case .lmStudio: ["lmstudio"]
        case .chatGPT: ["codex"]
        case .gemini: ["gemini-api", "gemini-cli"]
        case .claude: ["anthropic"]
        case .openAI: ["openai"]
        case .openRouter: ["openrouter"]
        }
    }

    var title: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .chatGPT: "ChatGPT"
        case .gemini: "Google Gemini"
        case .claude: "Claude"
        case .openAI: L("OpenAI API")
        case .openRouter: "OpenRouter"
        }
    }

    var subtitle: String {
        switch self {
        case .appleIntelligence: L("Built into macOS. Nothing to install.")
        case .ollama: L("Free app that runs open models on your Mac.")
        case .lmStudio: L("Free app to download and run models.")
        case .chatGPT: L("Sign in with your ChatGPT account.")
        case .gemini: L("A free key from your Google account.")
        case .claude: L("Anthropic's models, with an API key.")
        case .openAI: L("GPT models, with an API key.")
        case .openRouter: L("Hundreds of models with one key.")
        }
    }

    var systemImage: String {
        switch self {
        case .appleIntelligence: "apple.logo"
        case .ollama: "desktopcomputer"
        case .lmStudio: "cpu"
        case .chatGPT: "bubble.left.and.text.bubble.right.fill"
        case .gemini: "sparkle"
        case .claude: "asterisk"
        case .openAI: "circle.hexagongrid.fill"
        case .openRouter: "arrow.triangle.branch"
        }
    }

    var tint: Color {
        switch self {
        case .appleIntelligence: Color(red: 0.62, green: 0.4, blue: 0.95)
        case .ollama: Color(red: 0.3, green: 0.32, blue: 0.36)
        case .lmStudio: Color(red: 0.36, green: 0.42, blue: 0.95)
        case .chatGPT: Color(red: 0.06, green: 0.64, blue: 0.5)
        case .gemini: Color(red: 0.26, green: 0.52, blue: 0.96)
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .openAI: Color(red: 0.2, green: 0.2, blue: 0.22)
        case .openRouter: Color(red: 0.4, green: 0.36, blue: 0.9)
        }
    }

    /// The API key provider this option uses, if it is set up with a key.
    var keyProviderID: String? {
        switch self {
        case .gemini: "gemini-api"
        case .claude: "anthropic"
        case .openAI: "openai"
        case .openRouter: "openrouter"
        default: nil
        }
    }

    /// Where the user creates an API key.
    var keyPage: URL? {
        switch self {
        case .gemini: URL(literal: "https://aistudio.google.com/apikey")
        case .claude: URL(literal: "https://console.anthropic.com/settings/keys")
        case .openAI: URL(literal: "https://platform.openai.com/api-keys")
        case .openRouter: URL(literal: "https://openrouter.ai/keys")
        default: nil
        }
    }

    /// Short directions for the key page.
    var keyDirections: String {
        switch self {
        case .gemini:
            L("Sign in with Google and choose “Create API key”. It's free for everyday use.")
        case .claude: L("Sign in, choose “Create Key” and give it a name like “Momo”.")
        case .openAI: L("Sign in, choose “Create new secret key” and name it “Momo”.")
        case .openRouter: L("Sign in, choose “Create Key” and name it “Momo”.")
        default: ""
        }
    }
}

extension AppModel {
    /// The status of every provider behind `option`.
    func statuses(for option: BrainOption) -> [ProviderStatus] {
        assistant.providerStatuses.filter { option.providerIDs.contains($0.id) }
    }

    /// Whether any provider behind `option` is ready to answer.
    func isConnected(_ option: BrainOption) -> Bool {
        statuses(for: option).contains { $0.availability.isReady }
    }

    /// Turns a provider on and checks the brains again.
    func enableBrain(_ providerID: String) {
        settings.preferences.brains.disabled.remove(providerID)
        Task { await assistant.refreshProviders() }
    }

    /// Stops using `option`: removes its key or turns its providers off.
    func disconnect(_ option: BrainOption) {
        if let keyID = option.keyProviderID {
            settings.keys.setKey("", for: keyID)
        }
        for id in option.providerIDs where id != option.keyProviderID {
            settings.preferences.brains.disabled.insert(id)
        }
        Task { await assistant.refreshProviders() }
    }
}
