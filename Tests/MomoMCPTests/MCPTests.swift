import Foundation
import MomoKit
import Testing

@testable import MomoMCP

/// Connects a client directly to a server in memory.
final class InMemoryTransport: MCPTransport, @unchecked Sendable {
    let lines: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let server: MCPServer

    init(server: MCPServer) {
        self.server = server
        (lines, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
    }

    func send(_ line: String) async throws {
        let message = try JSONValue.parse(line)
        if let response = await server.handle(message) {
            continuation.yield(response.jsonString)
        }
    }

    func close() async {
        continuation.finish()
    }
}

func temporaryStore() -> MomoStore {
    MomoStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-mcp-tests-\(UUID().uuidString).json"))
}

@Suite("MCP server")
struct MCPServerTests {
    @Test("negotiates the protocol version")
    func initialize() async throws {
        let server = MCPServer(toolbox: Toolbox())
        let known = await server.handle(
            [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["protocolVersion": "2025-03-26"],
            ])
        #expect(known?["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
        let unknown = await server.handle(
            [
                "jsonrpc": "2.0", "id": 2, "method": "initialize",
                "params": ["protocolVersion": "1999-01-01"],
            ])
        #expect(unknown?["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
    }

    @Test("ignores notifications and rejects unknown methods")
    func notificationsAndErrors() async {
        let server = MCPServer(toolbox: Toolbox())
        #expect(
            await server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let response = await server.handle(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        #expect(response?["error"]?["code"]?.intValue == -32601)
    }

    @Test("hides tools that need confirmation unless allowed")
    func confirmationTools() async {
        let store = temporaryStore()
        let safe = MCPServer(toolbox: Toolbox(StoreTools.all(store: store)))
        let list = await safe.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let names =
            list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("add_task"))
        #expect(names.contains("update_routine"))
        // A routine runs its prompt unattended, so other agents can't add one by default.
        #expect(!names.contains("add_routine"))
        #expect(!names.contains("delete_task"))
        #expect(!names.contains("delete_routine"))
        #expect(!names.contains("forget"))

        let open = MCPServer(
            toolbox: Toolbox(StoreTools.all(store: store)), allowsConfirmationTools: true)
        let all = await open.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        #expect(
            all?["result"]?["tools"]?.arrayValue?.contains { $0["name"] == "delete_task" } == true)
    }
}

@Suite("MCP client")
struct MCPClientTests {
    @Test("lists and calls tools on a server")
    func roundTrip() async throws {
        let store = temporaryStore()
        let server = MCPServer(toolbox: Toolbox(StoreTools.all(store: store)))
        let client = MCPClient(transport: InMemoryTransport(server: server))
        try await client.connect()
        #expect(await client.serverName == "momo")

        let tools = try await client.listTools()
        #expect(tools.contains { $0.name == "add_task" })

        let output = try await client.callTool("add_task", arguments: ["title": "Buy stamps"])
        #expect(output.contains("Buy stamps"))
        #expect(await store.tasks().first?.title == "Buy stamps")

        await #expect(throws: MCPClient.ClientError.self) {
            _ = try await client.callTool("complete_task", arguments: ["task": "nothing like this"])
        }
        await client.close()
    }

    @Test("wraps remote tools as Momo tools with prefixed names")
    func remoteTools() async throws {
        let store = temporaryStore()
        let client = MCPClient(
            transport: InMemoryTransport(
                server: MCPServer(toolbox: Toolbox(StoreTools.all(store: store)))))
        try await client.connect()
        let remote = try #require(try await client.listTools().first { $0.name == "add_note" })
        let tool = MCPRemoteTool(
            tool: remote, client: client, prefix: "other app", requiresConfirmation: true)
        #expect(tool.definition.name == "other_app__add_note")
        #expect(tool.definition.requiresConfirmation)
        let output = try await tool.run(arguments: ["title": "From MCP", "body": "Hello"])
        #expect(output.contains("From MCP"))
    }
}

@Suite("MCP client robustness")
struct MCPClientRobustnessTests {
    private func isTooLarge(_ error: any Error) -> Bool {
        if case .messageTooLarge = error as? MCPClient.ClientError { return true }
        return false
    }

    @Test("line buffer stops at its limit")
    func lineBufferLimit() throws {
        let buffer = LineBuffer(limit: 8)
        #expect(try buffer.append(Data("a".utf8)).isEmpty)
        #expect(try buffer.append(Data("b\nc\n\nd".utf8)) == ["ab", "c", ""])
        #expect(try buffer.append(Data("\nshort\nrest".utf8)) == ["d", "short"])
        #expect(throws: MCPClient.ClientError.self) {
            _ = try buffer.append(Data("of a line far too long".utf8))
        }
        // The oversized data is dropped rather than kept growing.
        #expect(try buffer.append(Data("ok\n".utf8)) == ["ok"])
    }

    @Test("process transport ends with an error when a line grows too large")
    func processOverflow() async throws {
        // `cat /dev/zero` writes endlessly without a newline.
        let transport = try ProcessTransport(command: "/bin/cat", arguments: ["/dev/zero"])
        var failure: (any Error)?
        do {
            for try await _ in transport.lines {}
        } catch {
            failure = error
        }
        let error = try #require(failure)
        #expect(isTooLarge(error))
        #expect(await waitUntilStopped(transport))
    }

    @Test("a failed handshake stops the server process")
    func failedConnectCloses() async throws {
        // `sleep` never answers the handshake.
        let transport = try ProcessTransport(command: "/bin/sleep", arguments: ["60"])
        let client = MCPClient(transport: transport, initializeTimeout: .milliseconds(200))
        await #expect(throws: MCPClient.ClientError.self) {
            try await client.connect()
        }
        #expect(await waitUntilStopped(transport))
    }

    private func waitUntilStopped(_ transport: ProcessTransport) async -> Bool {
        for _ in 0..<50 {
            if !transport.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !transport.isRunning
    }
}
