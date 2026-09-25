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

    public init(
        name: String, description: String, parameters: JSONValue = JSONSchema.object(),
        requiresConfirmation: Bool = false
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
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

/// The outcome of running a tool.
public struct ToolResult: Sendable, Hashable {
    public var callID: String
    public var name: String
    /// Text returned to the model.
    public var output: String
    public var isError: Bool

    public init(callID: String, name: String, output: String, isError: Bool = false) {
        self.callID = callID
        self.name = name
        self.output = output
        self.isError = isError
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

    /// A short, human-readable description of what a call will do, shown when asking the
    /// user for confirmation.
    func summary(for arguments: JSONValue) -> String
}

extension MomoTool {
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
            let output = try await tool.run(arguments: arguments)
            return ToolResult(callID: call.id, name: call.name, output: output)
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
    private let action: @Sendable (JSONValue) async throws -> String
    private let describe: @Sendable (JSONValue) -> String

    public init(
        _ definition: ToolDefinition,
        summary: @escaping @Sendable (JSONValue) -> String = { $0.jsonString },
        run: @escaping @Sendable (JSONValue) async throws -> String
    ) {
        self.definition = definition
        self.action = run
        self.describe = summary
    }

    public func run(arguments: JSONValue) async throws -> String {
        try await action(arguments)
    }

    public func summary(for arguments: JSONValue) -> String {
        describe(arguments)
    }
}
