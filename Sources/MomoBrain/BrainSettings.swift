import Foundation
import MomoKit

/// Which brains the user set up, in what order, and how requests are routed.
public struct BrainSettings: Codable, Sendable, Equatable {
    /// Provider IDs in order of preference. Local brains are tried before remote ones by the
    /// router; this order decides among brains of the same kind.
    public var order: [String]
    /// Provider IDs the user turned off.
    public var disabled: Set<String>

    public var ollamaURL: String
    public var ollamaModel: String
    public var lmStudioURL: String
    public var lmStudioModel: String
    public var codexModel: String
    public var geminiCLIModel: String
    public var anthropicModel: String
    public var openAIModel: String
    public var geminiModel: String
    public var openRouterModel: String

    public var localOnly: Bool
    public var askBeforeRemote: Bool
    public var difficultyThreshold: Int
    public var masksPersonalData: Bool

    public init() {
        order = BrainCatalog.allIDs
        disabled = []
        ollamaURL = "http://localhost:11434/v1"
        ollamaModel = ""
        lmStudioURL = "http://localhost:1234/v1"
        lmStudioModel = ""
        codexModel = ""
        geminiCLIModel = ""
        anthropicModel = AnthropicProvider.defaultModel
        openAIModel = "gpt-5"
        geminiModel = "gemini-2.5-flash"
        openRouterModel = "openrouter/auto"
        localOnly = false
        askBeforeRemote = true
        difficultyThreshold = 4
        masksPersonalData = true
    }

    public init(from decoder: any Decoder) throws {
        // Decode leniently so settings survive new fields in later versions.
        let defaults = BrainSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        order = value(.order, defaults.order)
        for id in BrainCatalog.allIDs where !order.contains(id) { order.append(id) }
        disabled = value(.disabled, defaults.disabled)
        ollamaURL = value(.ollamaURL, defaults.ollamaURL)
        ollamaModel = value(.ollamaModel, defaults.ollamaModel)
        lmStudioURL = value(.lmStudioURL, defaults.lmStudioURL)
        lmStudioModel = value(.lmStudioModel, defaults.lmStudioModel)
        codexModel = value(.codexModel, defaults.codexModel)
        geminiCLIModel = value(.geminiCLIModel, defaults.geminiCLIModel)
        anthropicModel = value(.anthropicModel, defaults.anthropicModel)
        openAIModel = value(.openAIModel, defaults.openAIModel)
        geminiModel = value(.geminiModel, defaults.geminiModel)
        openRouterModel = value(.openRouterModel, defaults.openRouterModel)
        localOnly = value(.localOnly, defaults.localOnly)
        askBeforeRemote = value(.askBeforeRemote, defaults.askBeforeRemote)
        difficultyThreshold = value(.difficultyThreshold, defaults.difficultyThreshold)
        masksPersonalData = value(.masksPersonalData, defaults.masksPersonalData)
    }

    public var policy: RoutingPolicy {
        RoutingPolicy(
            localOnly: localOnly, askBeforeRemote: askBeforeRemote,
            difficultyThreshold: difficultyThreshold)
    }
}

/// Where API keys come from. The app stores them in the Keychain.
public protocol APIKeyStore: Sendable {
    func key(for providerID: String) -> String?
}

/// The brains Momo knows about and how to build them.
public enum BrainCatalog {
    public static let allIDs = [
        AppleIntelligence.providerID, "ollama", "lmstudio", "codex", "gemini-cli", "anthropic",
        "openai", "gemini-api", "openrouter",
    ]

    /// Provider IDs that need an API key.
    public static let keyedIDs: Set<String> = ["anthropic", "openai", "gemini-api", "openrouter"]

    /// Builds the enabled providers in the user's order.
    public static func providers(
        settings: BrainSettings, keys: any APIKeyStore, mcpServerPath: String?,
        workingDirectory: URL, session: URLSession = .shared
    ) -> [any ChatProvider] {
        settings.order.filter { !settings.disabled.contains($0) }.compactMap { id in
            provider(
                id: id, settings: settings, keys: keys, mcpServerPath: mcpServerPath,
                workingDirectory: workingDirectory, session: session)
        }
    }

    static func provider(
        id: String, settings: BrainSettings, keys: any APIKeyStore, mcpServerPath: String?,
        workingDirectory: URL, session: URLSession
    ) -> (any ChatProvider)? {
        func key() -> String? {
            guard let key = keys.key(for: id), !key.isEmpty else { return nil }
            return key
        }
        switch id {
        case AppleIntelligence.providerID:
            return AppleIntelligence.makeProvider()
        case "ollama":
            guard !settings.ollamaModel.isEmpty else { return nil }
            return OpenAICompatibleProvider.ollama(
                model: settings.ollamaModel, baseURL: URL(string: settings.ollamaURL),
                session: session)
        case "lmstudio":
            guard !settings.lmStudioModel.isEmpty else { return nil }
            return OpenAICompatibleProvider.lmStudio(
                model: settings.lmStudioModel, baseURL: URL(string: settings.lmStudioURL),
                session: session)
        case "codex":
            return CodexProvider(
                model: settings.codexModel, mcpServerPath: mcpServerPath,
                workingDirectory: workingDirectory)
        case "gemini-cli":
            return GeminiCLIProvider(
                model: settings.geminiCLIModel, workingDirectory: workingDirectory)
        case "anthropic":
            return key().map {
                AnthropicProvider(apiKey: $0, model: settings.anthropicModel, session: session)
            }
        case "openai":
            return key().map {
                OpenAICompatibleProvider.openAI(
                    apiKey: $0, model: settings.openAIModel, session: session)
            }
        case "gemini-api":
            return key().map {
                OpenAICompatibleProvider.gemini(
                    apiKey: $0, model: settings.geminiModel, session: session)
            }
        case "openrouter":
            return key().map {
                OpenAICompatibleProvider.openRouter(
                    apiKey: $0, model: settings.openRouterModel, session: session)
            }
        default:
            return nil
        }
    }
}
