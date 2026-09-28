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
    /// The tools an assistant turn used and what they returned, kept compact so follow-up
    /// questions can refer to their results.
    public var toolRecords: [ToolRecord]
    /// Files and images the user attached to this turn.
    public var attachments: [ChatAttachment]

    public init(
        role: Role, text: String, toolRecords: [ToolRecord] = [],
        attachments: [ChatAttachment] = []
    ) {
        self.role = role
        self.text = text
        self.toolRecords = toolRecords
        self.attachments = attachments
    }

    /// The text providers without vision send for this turn: attached documents, the
    /// message, notes for images and a short account of the tools it used, if any.
    public var contextText: String { context(imagesVisible: false) }

    /// The turn with its text, attached documents and tool records passed through
    /// `transform`, for example to mask personal data before it leaves the Mac. Images
    /// can't be masked and are kept as they are.
    public func mapText(_ transform: (String) -> String) -> ChatTurn {
        ChatTurn(
            role: role, text: transform(text),
            toolRecords: toolRecords.map { record in
                ToolRecord(
                    name: record.name, arguments: transform(record.arguments),
                    result: transform(record.result), isError: record.isError)
            },
            attachments: attachments.map { attachment in
                var attachment = attachment
                if case .file(let text) = attachment.content {
                    attachment.content = .file(text: transform(text))
                }
                return attachment
            })
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
    /// The answer is awaited in a live voice conversation, so a quick answer beats a
    /// thorough one; brains that can think less (Codex's reasoning effort) should.
    public var prefersSpeed: Bool

    public init(
        systemPrompt: String, turns: [ChatTurn], tools: [ToolDefinition] = [],
        prefersSpeed: Bool = false
    ) {
        self.systemPrompt = systemPrompt
        self.turns = turns
        self.tools = tools
        self.prefersSpeed = prefersSpeed
    }
}

/// Runs a tool call on behalf of a provider, including confirmation and privacy handling.
public typealias ToolRunner = @Sendable (ToolCall) async -> ToolResult

/// Something a brain made while answering, such as a generated image or a written file.
public struct ChatArtifact: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case image
        case file
    }

    /// Where the artifact is on this Mac.
    public var url: URL
    public var kind: Kind

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }

    /// Picks the kind from the file's extension.
    public init(url: URL) {
        let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"]
        self.init(url: url, kind: images.contains(url.pathExtension.lowercased()) ? .image : .file)
    }
}

/// What a provider reports while answering.
public enum ChatEvent: Sendable, Equatable {
    /// More reply text.
    case text(String)
    /// The model started a tool call.
    case toolStarted(ToolCall)
    /// A tool call finished.
    case toolFinished(ToolResult)
    /// The brain made an image or a file.
    case artifact(ChatArtifact)
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
    /// Whether the brain can look at attached images.
    public var supportsImages: Bool

    public init(
        id: String, name: String, kind: BrainKind, comfortableLength: Int = 100_000,
        supportsImages: Bool = false
    ) {
        self.supportsImages = supportsImages
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

/// The largest number of model ↔ tool round trips per request. Simple requests finish in one
/// or two; the headroom lets longer multi-step jobs complete.
let maximumToolRounds = 24

/// What a provider appends when a request used up `maximumToolRounds`, so the answer never
/// just stops.
let toolRoundLimitNotice =
    "\n\n(I stopped after \(maximumToolRounds) tool steps without finishing. Say “continue” and I'll pick up where I left off.)"
