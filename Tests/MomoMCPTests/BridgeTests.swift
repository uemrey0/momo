import Darwin
import Foundation
import MomoKit
import Testing

@testable import MomoMCP

/// Talks to a socket server through ``MCPBridgeRelay``, the way a CLI talks to
/// `momo-mcp --bridge`: through a pair of pipes.
final class RelayTransport: MCPTransport, @unchecked Sendable {
    let lines: AsyncThrowingStream<String, any Error>
    let input = Pipe()
    private let output = Pipe()
    private let done = NSLock()
    private var isDone = false
    /// Whether the relay returned.
    var finished: Bool { done.withLock { isDone } }

    init(socketPath: String) {
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        lines = stream
        let input = input.fileHandleForReading.fileDescriptor
        let output = output.fileHandleForWriting
        Thread { [self] in
            try? MCPBridgeRelay.run(
                socketPath: socketPath, input: input, output: output.fileDescriptor)
            try? output.close()
            done.withLock { isDone = true }
        }.start()
        let buffer = LineBuffer()
        self.output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in buffer.append(data) { continuation.yield(line) }
        }
    }

    /// Writes raw bytes, to test framing across and within writes.
    func write(_ text: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    }

    func send(_ line: String) async throws {
        try write(line + "\n")
    }

    func close() async {
        try? input.fileHandleForWriting.close()
    }
}

private func echoServer() -> MCPServer {
    let echo = ToolDefinition(name: "echo", description: "Echoes its text.")
    let fail = ToolDefinition(name: "fail", description: "Always fails.")
    return MCPServer(tools: [echo, fail]) { call in
        if call.name == "fail" {
            return ToolResult(callID: call.id, name: call.name, output: "Broken", isError: true)
        }
        let text = (try? JSONValue.parse(call.arguments))?["text"]?.stringValue ?? ""
        return ToolResult(callID: call.id, name: call.name, output: "echo: \(text)")
    }
}

@Suite("MCP socket bridge")
struct MCPSocketBridgeTests {
    @Test("serves tools on a private socket and cleans up")
    func roundTrip() async throws {
        let server = try MCPSocketServer(server: echoServer())
        let path = server.socketPath
        let directory = (path as NSString).deletingLastPathComponent
        #expect(UnixSocket.fits(path))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let client = MCPClient(transport: try UnixSocketTransport(path: path))
        try await client.connect()
        #expect(await client.serverName == "momo")
        #expect(try await client.listTools().map(\.name) == ["echo", "fail"])
        #expect(try await client.callTool("echo", arguments: ["text": "hi"]) == "echo: hi")
        await #expect(throws: MCPClient.ClientError.self) {
            _ = try await client.callTool("fail", arguments: [:])
        }
        await #expect(throws: MCPClient.ClientError.self) {
            _ = try await client.callTool("missing", arguments: [:])
        }

        // Concurrent calls on one connection all get their own answer.
        let answers = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                group.addTask {
                    try await client.callTool("echo", arguments: ["text": .string("\(index)")])
                }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(answers.count == 8)

        await client.close()
        server.stop()
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    @Test("closes connections when stopped")
    func stopClosesClients() async throws {
        let server = try MCPSocketServer(server: echoServer())
        let transport = try UnixSocketTransport(path: server.socketPath)
        let client = MCPClient(transport: transport)
        try await client.connect()
        server.stop()
        // Once the app closed the connection, calls fail instead of hanging.
        var failed = false
        for _ in 0..<200 where !failed {
            do {
                _ = try await client.callTool("echo", arguments: ["text": "late"])
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                failed = true
            }
        }
        #expect(failed)
        _ = transport
    }

    @Test("refuses socket paths longer than sun_path allows")
    func longPaths() throws {
        let long = "/tmp/" + String(repeating: "x", count: 120)
        #expect(throws: UnixSocket.Failure.self) {
            _ = try MCPSocketServer.makePrivateDirectory(in: long)
        }
        #expect(UnixSocket.maximumPathLength == 103)
    }

    @Test("relays stdio to the socket without changing the framing")
    func relayFraming() async throws {
        let server = try MCPSocketServer(server: echoServer())
        defer { server.stop() }
        let relay = RelayTransport(socketPath: server.socketPath)
        func call(_ id: Int, _ text: String) -> String {
            ([
                "jsonrpc": "2.0", "id": .number(Double(id)), "method": "tools/call",
                "params": ["name": "echo", "arguments": ["text": .string(text)]],
            ] as JSONValue).jsonString
        }
        // Two messages in one write, then one message split across three writes, with a
        // multibyte character on a boundary.
        try relay.write(call(1, "one") + "\n" + call(2, "two") + "\n")
        let third = Data((call(3, "çay ☕️") + "\n").utf8)
        try relay.input.fileHandleForWriting.write(contentsOf: third.prefix(10))
        try relay.input.fileHandleForWriting.write(contentsOf: third.dropFirst(10).prefix(40))
        try relay.input.fileHandleForWriting.write(contentsOf: third.dropFirst(50))

        var texts: [Int: String] = [:]
        for try await line in relay.lines {
            let response = try JSONValue.parse(line)
            let id = try #require(response["id"]?.intValue)
            texts[id] = response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
            if texts.count == 3 { break }
        }
        #expect(texts == [1: "echo: one", 2: "echo: two", 3: "echo: çay ☕️"])

        // Closing the input ends the relay once the app closed its side.
        await relay.close()
        for _ in 0..<500 where !relay.finished {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(relay.finished)
    }

    @Test("reports a missing socket")
    func missingSocket() {
        #expect(throws: UnixSocket.Failure.self) {
            try MCPBridgeRelay.run(socketPath: "/tmp/momo-no-such-socket-\(getpid()).sock")
        }
    }
}
