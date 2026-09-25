import Foundation
import MomoKit

/// A single turn of conversation history, stored provider-neutrally so the user can switch
/// brains mid-conversation.
public struct ChatTurn: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable {
        case user
        case assistant
    }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// Everything a provider needs to answer.
public struct ChatRequest: Sendable {
    /// Instructions describing Momo's persona, the date and what it remembers.
    public var systemPrompt: String
    /// Earlier turns followed by the new user message as the last element.
    public var turns: [ChatTurn]
    /// Tools the model may call.
    public var tools: [ToolDefinition]

    public init(systemPrompt: String, turns: [ChatTurn], tools: [ToolDefinition] = []) {
        self.systemPrompt = systemPrompt
        self.turns = turns
        self.tools = tools
    }
}

/// Runs a tool call on behalf of a provider, including confirmation and privacy handling.
public typealias ToolRunner = @Sendable (ToolCall) async -> ToolResult

/// What a provider reports while answering.
public enum ChatEvent: Sendable, Equatable {
    /// More reply text.
    case text(String)
    /// The model started a tool call.
    case toolStarted(ToolCall)
    /// A tool call finished.
    case toolFinished(ToolResult)
}

/// Whether a provider can be used right now.
public enum ProviderAvailability: Sendable, Equatable {
    case ready
    /// Not usable; the message tells the user how to fix it.
    case unavailable(String)

    public var isReady: Bool { self == .ready }
}

/// Static information about a provider.
public struct ProviderInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: BrainKind
    /// Roughly how many characters of input the brain handles well.
    public var comfortableLength: Int

    public init(id: String, name: String, kind: BrainKind, comfortableLength: Int = 100_000) {
        self.id = id
        self.name = name
        self.kind = kind
        self.comfortableLength = comfortableLength
    }
}

/// A language model Momo can think with.
public protocol ChatProvider: Sendable {
    var info: ProviderInfo { get }

    /// Checks cheaply whether the provider can answer (installed, signed in, reachable).
    func availability() async -> ProviderAvailability

    /// Answers the request, running tool calls through `runTool` until the model is done.
    func respond(
        to request: ChatRequest, runTool: @escaping ToolRunner
    )
        -> AsyncThrowingStream<ChatEvent, any Error>
}

/// An error with a message meant for the user.
public struct ProviderError: LocalizedError, Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// The largest number of model ↔ tool round trips per request.
let maximumToolRounds = 8
