import Foundation
import MomoKit

/// Carries JSON-RPC messages to and from an MCP server.
public protocol MCPTransport: Sendable {
    func send(_ line: String) async throws
    /// Incoming lines. Finishes when the server goes away.
    var lines: AsyncThrowingStream<String, any Error> { get }
    func close() async
}

/// Launches an MCP server as a child process and talks to it over stdio.
public final class ProcessTransport: MCPTransport, @unchecked Sendable {
    public let lines: AsyncThrowingStream<String, any Error>
    private let process = Process()
    private let input = Pipe()

    public init(command: String, arguments: [String], environment: [String: String] = [:]) throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        process.environment = merged
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        lines = stream
        let buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in buffer.append(data) { continuation.yield(line) }
        }
        process.terminationHandler = { _ in continuation.finish() }
        try process.run()
    }

    public func send(_ line: String) async throws {
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    public func close() async {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

/// Splits incoming data into lines.
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: data[data.startIndex..<newline], as: UTF8.self))
            data.removeSubrange(data.startIndex...newline)
        }
        return lines
    }
}

/// Connects to an MCP server and calls its tools.
public actor MCPClient {
    public struct RemoteTool: Sendable, Hashable {
        public var name: String
        public var description: String
        public var inputSchema: JSONValue
    }

    public enum ClientError: LocalizedError {
        case server(String)
        case closed
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .server(let message): "The MCP server reported an error: \(message)"
            case .closed: "The MCP server stopped."
            case .timedOut: "The MCP server did not answer in time."
            }
        }
    }

    private let transport: any MCPTransport
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var reader: Task<Void, Never>?
    public private(set) var serverName = ""

    public init(transport: any MCPTransport) {
        self.transport = transport
    }

    /// Performs the MCP handshake.
    public func connect(clientName: String = "momo", version: String = "0.1.0") async throws {
        startReading()
        let result = try await request(
            "initialize",
            params: [
                "protocolVersion": .string(MCPServer.supportedProtocolVersions[0]),
                "capabilities": .object([:]),
                "clientInfo": ["name": .string(clientName), "version": .string(version)],
            ])
        serverName = result["serverInfo"]?["name"]?.stringValue ?? ""
        try await notify("notifications/initialized")
    }

    public func listTools() async throws -> [RemoteTool] {
        let result = try await request("tools/list", params: .object([:]))
        return (result["tools"]?.arrayValue ?? []).compactMap { tool in
            guard let name = tool["name"]?.stringValue else { return nil }
            return RemoteTool(
                name: name, description: tool["description"]?.stringValue ?? "",
                inputSchema: tool["inputSchema"] ?? JSONSchema.object())
        }
    }

    /// Calls a tool and returns its text output. Throws when the tool reports an error.
    public func callTool(_ name: String, arguments: JSONValue) async throws -> String {
        let result = try await request(
            "tools/call", params: ["name": .string(name), "arguments": arguments])
        let text = (result["content"]?.arrayValue ?? []).compactMap { item -> String? in
            item["type"]?.stringValue == "text" ? item["text"]?.stringValue : nil
        }.joined(separator: "\n")
        if result["isError"]?.boolValue == true { throw ClientError.server(text) }
        return text
    }

    public func close() async {
        reader?.cancel()
        await transport.close()
        failAll(ClientError.closed)
    }

    // MARK: - JSON-RPC

    private func request(
        _ method: String, params: JSONValue, timeout: Duration = .seconds(30)
    )
        async throws -> JSONValue
    {
        let id = nextID
        nextID += 1
        let message: JSONValue = [
            "jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method),
            "params": params,
        ]
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.fail(id: id, ClientError.timedOut)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await transport.send(message.jsonString)
                } catch {
                    self.fail(id: id, error)
                }
            }
        }
    }

    private func notify(_ method: String) async throws {
        try await transport.send(
            (["jsonrpc": "2.0", "method": .string(method)] as JSONValue).jsonString)
    }

    private func startReading() {
        guard reader == nil else { return }
        let lines = transport.lines
        reader = Task { [weak self] in
            do {
                for try await line in lines {
                    guard let message = try? JSONValue.parse(line) else { continue }
                    await self?.receive(message)
                }
            } catch {}
            await self?.failAll(ClientError.closed)
        }
    }

    private func receive(_ message: JSONValue) {
        guard let id = message["id"]?.intValue, let continuation = pending.removeValue(forKey: id)
        else { return }
        if let error = message["error"] {
            continuation.resume(
                throwing: ClientError.server(error["message"]?.stringValue ?? "Unknown error"))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }

    private func fail(id: Int, _ error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(_ error: any Error) {
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
    }
}

/// Offers a tool from another MCP server to Momo's own brains.
public struct MCPRemoteTool: MomoTool {
    public let definition: ToolDefinition
    private let client: MCPClient
    private let remoteName: String

    /// - Parameter prefix: Prepended to the tool name to keep names unique across servers.
    public init(
        tool: MCPClient.RemoteTool, client: MCPClient, prefix: String, requiresConfirmation: Bool
    ) {
        self.client = client
        self.remoteName = tool.name
        let name = "\(prefix)__\(tool.name)"
            .replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "_", options: .regularExpression)
        self.definition = ToolDefinition(
            name: String(name.prefix(64)), description: tool.description,
            parameters: tool.inputSchema, requiresConfirmation: requiresConfirmation)
    }

    public func run(arguments: JSONValue) async throws -> String {
        try await client.callTool(remoteName, arguments: arguments)
    }

    public func summary(for arguments: JSONValue) -> String {
        "\(remoteName) \(arguments.jsonString)"
    }
}
