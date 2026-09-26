import Foundation
import MomoBrain
import MomoKit

/// Something that went wrong in the chat, said plainly, with the ways to fix it.
struct ChatIssue: Equatable {
    enum Kind: Equatable {
        /// No brain is set up or none can answer right now.
        case noBrain
        /// The brain needs the user to sign in again.
        case signIn
        /// A brain or tool isn't installed or connected.
        case setup
        /// The Mac is offline or a server can't be reached.
        case network
        /// The provider's limit or quota was reached.
        case rateLimit
        /// A macOS permission is missing.
        case permission(MacPermission)
        case other
    }

    /// A way to fix the issue, shown as a button.
    enum Action: Equatable, Hashable {
        case retry
        case openAISettings
        case setUpAI
        /// Asks for the permission, or opens its page in System Settings.
        case allow(MacPermission)
    }

    var kind: Kind
    var title: String
    var message: String
    /// The original error text, for the curious and for reporting problems.
    var details: String?
    var actions: [Action]

    var systemImage: String {
        switch kind {
        case .noBrain, .setup: "sparkles"
        case .signIn: "person.crop.circle.badge.exclamationmark"
        case .network: "wifi.exclamationmark"
        case .rateLimit: "hourglass"
        case .permission: "lock.fill"
        case .other: "exclamationmark.triangle.fill"
        }
    }
}

extension ChatIssue {
    /// Explains `error` and offers the actions that fix it.
    init(error: any Error) {
        self.init(message: error.localizedDescription, isNetwork: error is URLError)
    }

    init(message raw: String, isNetwork: Bool = false) {
        let text = raw.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if isNetwork || has("offline", "internet", "network", "could not connect", "timed out") {
            self.init(
                kind: .network, title: L("Momo can't reach the internet"),
                message: L("Check your connection, then try again. On-device brains keep working."),
                details: raw, actions: [.retry])
        } else if has("429", "rate limit", "quota", "too many requests", "usage limit") {
            self.init(
                kind: .rateLimit, title: L("The brain needs a break"),
                message: L(
                    "Its usage limit was reached. Try again in a little while, or pick another brain in AI settings."
                ),
                details: raw, actions: [.retry, .openAISettings])
        } else if has("sign in", "signed in", "log in", "login", "auth", "401", "403", "api key") {
            self.init(
                kind: .signIn, title: L("Momo needs you to sign in again"),
                message: L("Open AI settings and reconnect the brain. It only takes a moment."),
                details: raw, actions: [.openAISettings, .retry])
        } else if has(
            "no brain", "no on-device brain", "isn't available", "is not available",
            "brain is available", "connect ", "set up")
        {
            self.init(
                kind: .noBrain, title: L("No brain can answer right now"),
                message: L(
                    "Connect ChatGPT, Gemini, Claude or a free model on this Mac, then try again."),
                details: raw, actions: [.setUpAI, .retry])
        } else if has("not installed", "was not found", "not found", "download") {
            self.init(
                kind: .setup, title: L("Something needs setting up"),
                message: L("Open AI settings to finish connecting it, then try again."),
                details: raw, actions: [.openAISettings, .retry])
        } else {
            self.init(
                kind: .other, title: L("That didn't work"),
                message: L("Something went wrong on the way. Trying again usually helps."),
                details: raw, actions: [.retry])
        }
    }

    /// A step failed because macOS hasn't given Momo `permission` yet.
    static func missing(_ permission: MacPermission) -> ChatIssue {
        ChatIssue(
            kind: .permission(permission),
            title: String(format: L("Momo needs access to %@"), permission.title),
            message: L(
                "Allow it once and Momo can do this from now on. Then try again."),
            details: nil, actions: [.allow(permission), .retry])
    }
}
