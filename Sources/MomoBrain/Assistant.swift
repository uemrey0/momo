import Foundation
import MomoKit

/// What the assistant reports while answering, for the UI and the character.
public enum AssistantEvent: Sendable, Equatable {
    /// A brain was chosen.
    case brainSelected(ProviderInfo, RoutingReason)
    /// More reply text, with personal data already restored.
    case text(String)
    /// A tool started running.
    case toolStarted(name: String)
    /// A tool finished.
    case toolFinished(name: String, succeeded: Bool)
}

/// The user's answer when Momo asks before using a remote brain.
public enum RemoteConsent: Sendable, Equatable {
    /// Use the remote brain for this message.
    case allowOnce
    /// Use the remote brain for the rest of this conversation.
    case allowForConversation
    /// Answer with the local brain instead.
    case useLocal
    /// Don't answer.
    case cancel
}

/// Asks the user whether to send a message to a remote brain.
public typealias RemoteConsentHandler =
    @Sendable (_ brain: ProviderInfo, _ reason: RoutingReason, _ masked: Bool) async ->
    RemoteConsent

/// Replaces personal data consistently for one conversation, across messages and tools.
public final class PrivacySession: @unchecked Sendable {
    private let masker: PrivacyMasker
    private var replacements: [String: String] = [:]
    private let lock = NSLock()

    public init(masker: PrivacyMasker = PrivacyMasker()) {
        self.masker = masker
    }

    public func mask(_ text: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let masked = masker.mask(text, continuing: replacements)
        replacements = masked.replacements
        return masked.text
    }

    public func unmask(_ text: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return MaskedText(text: text, replacements: replacements).unmask(text)
    }

    /// Whether anything has been masked so far.
    public var hasMaskedData: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !replacements.isEmpty
    }
}

/// One conversation with Momo: routing, consent, privacy, tools and streaming.
public actor Assistant {
    /// Everything the assistant needs for one reply.
    public struct Configuration: Sendable {
        public var providers: [any ChatProvider]
        public var toolbox: Toolbox
        public var policy: RoutingPolicy
        public var masksPersonalData: Bool
        public var systemPrompt: String

        public init(
            providers: [any ChatProvider], toolbox: Toolbox, policy: RoutingPolicy,
            masksPersonalData: Bool, systemPrompt: String
        ) {
            self.providers = providers
            self.toolbox = toolbox
            self.policy = policy
            self.masksPersonalData = masksPersonalData
            self.systemPrompt = systemPrompt
        }
    }

    public private(set) var history: [ChatTurn] = []
    /// A brain the user picked for this conversation, overriding the router.
    public var forcedProviderID: String?
    private var remoteApproved = false
    private let privacy = PrivacySession()

    public init() {}

    public func setForcedProvider(_ id: String?) {
        forcedProviderID = id
    }

    public func reset() {
        history = []
        remoteApproved = false
        forcedProviderID = nil
    }

    /// Answers `message`, streaming events. The reply is added to the history when done.
    public func reply(
        to message: String, configuration: Configuration,
        consent: @escaping RemoteConsentHandler,
        confirm: @escaping ToolConfirmationHandler
    ) -> AsyncThrowingStream<AssistantEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(
                        message, configuration: configuration, consent: consent,
                        confirm: confirm, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ message: String, configuration: Configuration, consent: RemoteConsentHandler,
        confirm: @escaping ToolConfirmationHandler,
        continuation: AsyncThrowingStream<AssistantEvent, any Error>.Continuation
    ) async throws {
        let turns = history + [ChatTurn(role: .user, text: message)]
        let provider = try await choose(
            for: turns, configuration: configuration, consent: consent)
        guard let (provider, reason) = provider else { return }
        continuation.yield(.brainSelected(provider.info, reason))

        let remote = provider.info.kind.isRemote
        let masking = remote && configuration.masksPersonalData
        let privacy = self.privacy
        let outgoing: @Sendable (String) -> String = { masking ? privacy.mask($0) : $0 }
        let incoming: @Sendable (String) -> String = { masking ? privacy.unmask($0) : $0 }

        let request = ChatRequest(
            systemPrompt: outgoing(configuration.systemPrompt),
            turns: turns.map { ChatTurn(role: $0.role, text: outgoing($0.text)) },
            tools: configuration.toolbox.definitions)
        let toolbox = configuration.toolbox
        let runTool: ToolRunner = { call in
            var call = call
            call.arguments = incoming(call.arguments)
            var result = await toolbox.execute(call, confirm: confirm)
            result.output = outgoing(result.output)
            return result
        }

        var reply = ""
        var pending = ""
        for try await event in provider.respond(to: request, runTool: runTool) {
            switch event {
            case .text(let chunk):
                guard masking else {
                    reply += chunk
                    continuation.yield(.text(chunk))
                    continue
                }
                // Hold back a possible placeholder split across chunks.
                pending += chunk
                var ready = pending
                if let open = pending.lastIndex(of: "["), !pending[open...].contains("]"),
                    pending.distance(from: open, to: pending.endIndex) < 16
                {
                    ready = String(pending[..<open])
                    pending = String(pending[open...])
                } else {
                    pending = ""
                }
                let restored = incoming(ready)
                reply += restored
                if !restored.isEmpty { continuation.yield(.text(restored)) }
            case .toolStarted(let call):
                continuation.yield(.toolStarted(name: call.name))
            case .toolFinished(let result):
                continuation.yield(.toolFinished(name: result.name, succeeded: !result.isError))
            }
        }
        if !pending.isEmpty {
            let restored = incoming(pending)
            reply += restored
            continuation.yield(.text(restored))
        }
        history = turns + [ChatTurn(role: .assistant, text: reply)]
    }

    /// Picks a provider, asking for consent when needed. Returns `nil` if the user cancelled.
    private func choose(
        for turns: [ChatTurn], configuration: Configuration, consent: RemoteConsentHandler
    ) async throws -> (any ChatProvider, RoutingReason)? {
        let providers = configuration.providers
        var candidates: [BrainCandidate] = []
        var reasons: [String: String] = [:]
        await withTaskGroup(of: (Int, ProviderAvailability).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { (index, await provider.availability()) }
            }
            var results = Array(
                repeating: ProviderAvailability.unavailable(""), count: providers.count)
            for await (index, availability) in group { results[index] = availability }
            for (provider, availability) in zip(providers, results) {
                candidates.append(
                    BrainCandidate(
                        id: provider.info.id, name: provider.info.name, kind: provider.info.kind,
                        isAvailable: availability.isReady,
                        comfortableLength: provider.info.comfortableLength))
                if case .unavailable(let reason) = availability {
                    reasons[provider.info.name] = reason
                }
            }
        }

        let text = turns.map(\.text).joined(separator: "\n")
        let router = BrainRouter(policy: configuration.policy)
        switch router.route(
            text: text, candidates: candidates, forcedBrainID: forcedProviderID,
            remoteApproved: remoteApproved)
        {
        case .unavailable(let reason):
            let details = reasons.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
            throw ProviderError(details.isEmpty ? reason : "\(reason)\n\(details)")
        case .use(let brain, let reason, let needsConsent):
            guard let provider = providers.first(where: { $0.info.id == brain.id }) else {
                throw ProviderError("The chosen brain is missing.")
            }
            guard needsConsent else { return (provider, reason) }
            let masking = configuration.masksPersonalData
            switch await consent(provider.info, reason, masking) {
            case .allowOnce:
                return (provider, reason)
            case .allowForConversation:
                remoteApproved = true
                return (provider, reason)
            case .useLocal:
                guard
                    let local = providers.first(where: { candidate in
                        candidate.info.kind == .local
                            && candidates.contains { $0.id == candidate.info.id && $0.isAvailable }
                    })
                else {
                    throw ProviderError("No on-device brain is available right now.")
                }
                return (local, .userChoice)
            case .cancel:
                return nil
            }
        }
    }
}
