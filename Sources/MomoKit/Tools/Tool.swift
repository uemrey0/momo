import Foundation

/// Describes a tool to a language model.
public struct ToolDefinition: Sendable, Hashable {
    /// A snake_case identifier, unique within a toolbox.
    public var name: String
    /// What the tool does and when to use it, written for the model.
    public var description: String
    /// A JSON Schema object describing the arguments.
    public var parameters: JSONValue
    /// Whether the user must approve each call before it runs.
    public var requiresConfirmation: Bool
    /// A short, localized phrase shown while the tool runs ("Checking the weather"). `nil`
    /// falls back to a generic label.
    public var activityLabel: String?

    public init(
        name: String, description: String, parameters: JSONValue = JSONSchema.object(),
        requiresConfirmation: Bool = false, activityLabel: String? = nil
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
        self.activityLabel = activityLabel
    }
}

/// A request from a model to run a tool.
public struct ToolCall: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// The raw JSON arguments as produced by the model.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

extension ToolCall {
    /// Argument names that best describe what a call works on, in order of preference.
    static let describingArguments = [
        "query", "title", "text", "path", "url", "name", "command", "prompt", "city", "app",
        "request", "search", "to", "recipient",
    ]

    /// A short, readable hint of what the call works on, such as a search query or a file
    /// name, for showing next to the step. `nil` when the arguments hold nothing readable.
    public var briefDetail: String? {
        guard let arguments = try? JSONValue.parse(arguments), case .object(let fields) = arguments
        else { return nil }
        let value =
            Self.describingArguments.lazy.compactMap { fields[$0]?.stringValue }.first
            ?? fields.keys.sorted().lazy.compactMap { fields[$0]?.stringValue }.first
        guard
            let text = value?.split(whereSeparator: \.isNewline).first
                .map({ $0.trimmingCharacters(in: .whitespaces) }), !text.isEmpty
        else { return nil }
        return text.count > 60 ? String(text.prefix(59)) + "…" : text
    }
}

/// The outcome of running a tool.
public struct ToolResult: Sendable, Hashable {
    public var callID: String
    public var name: String
    /// Text returned to the model.
    public var output: String
    public var isError: Bool
    /// The macOS permission the tool was missing, when that is why it failed.
    public var missingPermission: MacPermission?
    /// Files the tool made, such as a generated image, for showing in the chat.
    public var files: [URL] = []

    public init(
        callID: String, name: String, output: String, isError: Bool = false,
        missingPermission: MacPermission? = nil
    ) {
        self.callID = callID
        self.name = name
        self.output = output
        self.isError = isError
        self.missingPermission = missingPermission
    }
}

/// An error a tool reports back to the model, phrased so the model can recover.
public struct ToolError: LocalizedError, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Something Momo can do on the user's behalf.
public protocol MomoTool: Sendable {
    var definition: ToolDefinition { get }

    /// Runs the tool and returns text for the model.
    func run(arguments: JSONValue) async throws -> String

    /// Runs the tool and returns text for the model with any files it made. Tools that make
    /// files implement this; the default wraps ``run(arguments:)``.
    func reply(arguments: JSONValue) async throws -> ToolReply

    /// A short, human-readable description of what a call will do, shown when asking the
    /// user for confirmation.
    func summary(for arguments: JSONValue) -> String
}

/// What a tool returns: text for the model and the files it made.
public struct ToolReply: Sendable, Hashable {
    public var text: String
    public var files: [URL]

    public init(text: String, files: [URL] = []) {
        self.text = text
        self.files = files
    }
}

extension MomoTool {
    public func reply(arguments: JSONValue) async throws -> ToolReply {
        ToolReply(text: try await run(arguments: arguments))
    }

    public func summary(for arguments: JSONValue) -> String {
        "\(definition.name) \(arguments.jsonString)"
    }
}

/// A request shown to the user before a tool that needs confirmation runs.
public struct ToolConfirmationRequest: Sendable, Hashable {
    public var toolName: String
    public var summary: String

    public init(toolName: String, summary: String) {
        self.toolName = toolName
        self.summary = summary
    }
}

/// Asks the user to approve a tool call. Returns `true` to run it.
public typealias ToolConfirmationHandler =
    @Sendable (ToolConfirmationRequest) async -> Bool

/// A set of tools that can be offered to a model and executed by name.
public struct Toolbox: Sendable {
    private var tools: [String: any MomoTool]
    private var order: [String]

    public init(_ tools: [any MomoTool] = []) {
        self.tools = [:]
        self.order = []
        for tool in tools { add(tool) }
    }

    public mutating func add(_ tool: any MomoTool) {
        let name = tool.definition.name
        if tools[name] == nil { order.append(name) }
        tools[name] = tool
    }

    public func merging(_ other: Toolbox) -> Toolbox {
        var merged = self
        for name in other.order {
            if let tool = other.tools[name] { merged.add(tool) }
        }
        return merged
    }

    public var definitions: [ToolDefinition] {
        order.compactMap { tools[$0]?.definition }
    }

    public var isEmpty: Bool { tools.isEmpty }

    public func tool(named name: String) -> (any MomoTool)? {
        tools[name]
    }

    /// Runs a call, asking for confirmation when the tool requires it. Never throws: failures
    /// become error results the model can read.
    public func execute(
        _ call: ToolCall, confirm: ToolConfirmationHandler? = nil
    ) async -> ToolResult {
        guard let tool = tools[call.name] else {
            return ToolResult(
                callID: call.id, name: call.name,
                output:
                    "Unknown tool '\(call.name)'. Available tools: \(order.joined(separator: ", "))",
                isError: true)
        }
        let arguments: JSONValue
        do {
            arguments = try JSONValue.parse(call.arguments)
        } catch {
            return ToolResult(
                callID: call.id, name: call.name,
                output: "The arguments were not valid JSON: \(call.arguments)", isError: true)
        }
        if tool.definition.requiresConfirmation {
            let request = ToolConfirmationRequest(
                toolName: call.name, summary: tool.summary(for: arguments))
            let approved = await confirm?(request) ?? false
            guard approved else {
                return ToolResult(
                    callID: call.id, name: call.name,
                    output:
                        "The user declined this action. Do not retry it; ask what they want instead.",
                    isError: true)
            }
        }
        do {
            let reply = try await tool.reply(arguments: arguments)
            var result = ToolResult(callID: call.id, name: call.name, output: reply.text)
            result.files = reply.files
            return result
        } catch let error as PermissionRequired {
            return ToolResult(
                callID: call.id, name: call.name, output: "Error: \(error.localizedDescription)",
                isError: true, missingPermission: error.permission)
        } catch {
            return ToolResult(
                callID: call.id, name: call.name, output: "Error: \(error.localizedDescription)",
                isError: true)
        }
    }
}

/// A tool built from a closure, handy for small tools and tests.
public struct ClosureTool: MomoTool {
    public let definition: ToolDefinition
    private let action: @Sendable (JSONValue) async throws -> ToolReply
    private let describe: @Sendable (JSONValue) -> String

    public init(
        _ definition: ToolDefinition,
        summary: @escaping @Sendable (JSONValue) -> String = { $0.jsonString },
        run: @escaping @Sendable (JSONValue) async throws -> String
    ) {
        self.definition = definition
        self.action = { ToolReply(text: try await run($0)) }
        self.describe = summary
    }

    private init(
        definition: ToolDefinition, describe: @escaping @Sendable (JSONValue) -> String,
        action: @escaping @Sendable (JSONValue) async throws -> ToolReply
    ) {
        self.definition = definition
        self.action = action
        self.describe = describe
    }

    /// A tool that can return files along with its text.
    public static func makingFiles(
        _ definition: ToolDefinition,
        summary: @escaping @Sendable (JSONValue) -> String = { $0.jsonString },
        reply: @escaping @Sendable (JSONValue) async throws -> ToolReply
    ) -> ClosureTool {
        ClosureTool(definition: definition, describe: summary, action: reply)
    }

    public func run(arguments: JSONValue) async throws -> String {
        try await action(arguments).text
    }

    public func reply(arguments: JSONValue) async throws -> ToolReply {
        try await action(arguments)
    }

    public func summary(for arguments: JSONValue) -> String {
        describe(arguments)
    }
}

/// Wraps a tool so that every call needs the user's approval first.
public struct ConfirmingTool: MomoTool {
    public let definition: ToolDefinition
    private let base: any MomoTool
    private let label: String?

    /// - Parameter label: A short description of the action, shown in the confirmation before
    ///   the call's details (the wrapped tool may have no summary of its own).
    public init(_ base: any MomoTool, label: String? = nil) {
        var definition = base.definition
        definition.requiresConfirmation = true
        self.definition = definition
        self.base = base
        self.label = label
    }

    public func run(arguments: JSONValue) async throws -> String {
        try await base.run(arguments: arguments)
    }

    public func reply(arguments: JSONValue) async throws -> ToolReply {
        try await base.reply(arguments: arguments)
    }

    public func summary(for arguments: JSONValue) -> String {
        let details = base.summary(for: arguments)
        guard let label else { return details }
        if case .object(let fields) = arguments, fields.isEmpty { return label }
        return "\(label): \(details)"
    }
}
