import Foundation

/// Where a brain runs, which decides privacy handling and eye colour.
public enum BrainKind: String, Codable, Sendable, CaseIterable {
    /// On the Mac: Apple's on-device model, Ollama, LM Studio.
    case local
    /// The user's own plan through an official CLI (Codex, Gemini CLI).
    case subscription
    /// A provider API key.
    case apiKey

    public var isRemote: Bool { self != .local }
}

/// A brain the router can choose.
public struct BrainCandidate: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: BrainKind
    public var isAvailable: Bool
    /// Roughly how much text the brain handles well, in characters.
    public var comfortableLength: Int

    public init(
        id: String, name: String, kind: BrainKind, isAvailable: Bool = true,
        comfortableLength: Int = 100_000
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isAvailable = isAvailable
        self.comfortableLength = comfortableLength
    }
}

/// The user's routing preferences.
public struct RoutingPolicy: Sendable, Equatable {
    /// Never send anything off the Mac.
    public var localOnly: Bool
    /// Ask before each remote request (unless the user already approved this conversation).
    public var askBeforeRemote: Bool
    /// Requests at or above this difficulty (1–5) go to a remote brain when one is available.
    public var difficultyThreshold: Int

    public init(localOnly: Bool = false, askBeforeRemote: Bool = true, difficultyThreshold: Int = 4)
    {
        self.localOnly = localOnly
        self.askBeforeRemote = askBeforeRemote
        self.difficultyThreshold = difficultyThreshold
    }
}

/// Why the router chose a brain. Shown to the user in plain words.
public enum RoutingReason: Sendable, Equatable {
    case userChoice
    case privacyLock
    case simpleRequest(difficulty: Int)
    case difficultRequest(difficulty: Int)
    case tooLongForLocal
    case noLocalBrain
    case onlyOption
}

public enum RoutingDecision: Sendable, Equatable {
    case use(BrainCandidate, reason: RoutingReason, needsConsent: Bool)
    case unavailable(reason: String)
}

/// Picks a brain for each request. See `docs/architecture.md` for the decision order.
public struct BrainRouter: Sendable {
    public var policy: RoutingPolicy

    public init(policy: RoutingPolicy = RoutingPolicy()) {
        self.policy = policy
    }

    /// - Parameters:
    ///   - text: The user's request, including any attached context.
    ///   - candidates: Brains in the user's order of preference.
    ///   - forcedBrainID: A brain the user explicitly picked for this conversation.
    ///   - remoteApproved: The user already approved remote use in this conversation.
    public func route(
        text: String, candidates: [BrainCandidate], forcedBrainID: String? = nil,
        remoteApproved: Bool = false
    ) -> RoutingDecision {
        let available = candidates.filter(\.isAvailable)
        let locals = available.filter { $0.kind == .local }
        let remotes = policy.localOnly ? [] : available.filter { $0.kind.isRemote }

        func consent(for brain: BrainCandidate) -> Bool {
            brain.kind.isRemote && policy.askBeforeRemote && !remoteApproved
        }

        if let forcedBrainID, let forced = available.first(where: { $0.id == forcedBrainID }),
            !(policy.localOnly && forced.kind.isRemote)
        {
            return .use(forced, reason: .userChoice, needsConsent: consent(for: forced))
        }

        if policy.localOnly {
            guard let local = locals.first else {
                return .unavailable(
                    reason: "Local-only mode is on, but no on-device brain is available.")
            }
            return .use(local, reason: .privacyLock, needsConsent: false)
        }

        guard let local = locals.first else {
            guard let remote = remotes.first else {
                return .unavailable(reason: "No brain is set up yet.")
            }
            return .use(remote, reason: .noLocalBrain, needsConsent: consent(for: remote))
        }

        guard let remote = remotes.first else {
            return .use(local, reason: .onlyOption, needsConsent: false)
        }

        if text.count > local.comfortableLength {
            return .use(remote, reason: .tooLongForLocal, needsConsent: consent(for: remote))
        }

        let difficulty = DifficultyEstimator.estimate(text)
        if difficulty >= policy.difficultyThreshold {
            return .use(
                remote, reason: .difficultRequest(difficulty: difficulty),
                needsConsent: consent(for: remote))
        }
        return .use(local, reason: .simpleRequest(difficulty: difficulty), needsConsent: false)
    }
}

/// Estimates how demanding a request is, from 1 (trivial) to 5 (hard), without calling a
/// model. Works across languages by combining length, structure and keywords.
public enum DifficultyEstimator {
    public static func estimate(_ text: String) -> Int {
        let lower = text.lowercased()
        if lower.count < 160, simplePatterns.contains(where: { lower.contains($0) }) {
            return 1
        }

        var score = 1
        switch text.count {
        case ..<120: break
        case ..<600: score += 1
        case ..<2_500: score += 2
        default: score += 3
        }
        if text.contains("```") || text.contains("func ") || text.contains("def ") {
            score += 2
        }
        let heavy = heavyKeywords.filter { lower.contains($0) }.count
        score += min(2, heavy)
        if text.filter({ $0 == "?" }).count > 2 { score += 1 }
        return min(5, max(1, score))
    }

    /// Everyday assistant requests the on-device brain handles well.
    static let simplePatterns = [
        "remind", "hatırlat", "add a task", "add task", "görev ekle", "to-do", "yapılacak",
        "note that", "not al", "not ekle", "what time", "saat kaç", "hello", "merhaba", "hi ",
        "selam", "thanks", "teşekkür", "remember that", "hatırla ki", "unutma", "habit",
        "alışkanlık", "timer", "zamanlayıcı", "my tasks", "görevlerim", "complete", "tamamla",
    ]

    /// Words that signal analysis, long-form writing or expert work.
    static let heavyKeywords = [
        "analyze", "analyse", "analiz", "incele", "compare", "karşılaştır", "in detail", "detaylı",
        "essay", "makale", "report", "rapor", "strategy", "strateji", "contract", "sözleşme",
        "debug", "refactor", "algorithm", "algoritma", "prove", "kanıtla", "research", "araştır",
        "translate", "çevir", "summarize this", "özetle", "step by step", "adım adım",
        "business plan", "iş planı", "legal", "hukuk", "medical", "tıbbi",
    ]
}
