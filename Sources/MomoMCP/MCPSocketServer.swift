import Darwin
import Foundation
import MomoKit

/// Serves an ``MCPServer`` on a private Unix domain socket, one JSON-RPC message per line.
///
/// The socket lives in a freshly created directory only the current user can open (`0700`),
/// and only processes of the same user may connect. Several clients and concurrent requests
/// are supported. Call ``stop()`` when done: it closes every connection, cancels running
/// requests and removes the socket and its directory.
public final class MCPSocketServer: @unchecked Sendable {
    /// The socket's path, to hand to `momo-mcp --bridge`.
    public let socketPath: String
    private let directory: String
    private let server: MCPServer
    private let listener: Int32
    /// Protects all mutable state below; also runs the socket event handlers.
    private let queue = DispatchQueue(label: "app.momo.mcp.socket-server")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var listenSource: (any DispatchSourceRead)?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var isStopped = false

    /// Creates the socket and starts accepting connections.
    ///
    /// - Parameter parentDirectory: Where to create the private directory. Defaults to the
    ///   user's temporary folder, or `/tmp` when that path would be too long for a socket.
    public init(server: MCPServer, parentDirectory: String? = nil) throws {
        self.server = server
        let directory = try Self.makePrivateDirectory(in: parentDirectory)
        let path = (directory as NSString).appendingPathComponent("mcp.sock")
        do {
            listener = try UnixSocket.listen(at: path)
        } catch {
            rmdir(directory)
            throw error
        }
        self.directory = directory
        self.socketPath = path
        queue.setSpecific(key: queueKey, value: true)

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        let listener = listener
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(listener) }
        listenSource = source
        source.resume()
    }

    deinit {
        stop()
    }

    /// Stops serving. Safe to call more than once.
    public func stop() {
        // The last reference may be released inside an event handler, so avoid a sync
        // dispatch onto the queue we are already on.
        let take = { () -> ((any DispatchSourceRead)?, [Connection]) in
            guard !self.isStopped else { return (nil, []) }
            self.isStopped = true
            defer {
                self.listenSource = nil
                self.connections = [:]
            }
            return (self.listenSource, Array(self.connections.values))
        }
        let (source, open) =
            DispatchQueue.getSpecific(key: queueKey) == true ? take() : queue.sync(execute: take)
        guard let source else { return }
        source.cancel()
        for connection in open { connection.close() }
        unlink(socketPath)
        rmdir(directory)
    }

    // MARK: - Connections

    /// Accepts every waiting client. Runs on `queue`.
    private func acceptPending() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard !isStopped, getpeereid(client, &uid, &gid) == 0, uid == getuid(),
                (try? UnixSocket.setNonBlocking(client)) != nil
            else {
                close(client)
                continue
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let connection = Connection(fd: client, server: server, queue: queue)
            let key = ObjectIdentifier(connection)
            connection.onClose = { [weak self] in self?.connections[key] = nil }
            connections[key] = connection
            connection.start()
        }
    }

    // MARK: - Directory

    static func makePrivateDirectory(in parent: String?) throws -> String {
        let candidates =
            parent.map { [$0] } ?? [NSTemporaryDirectory(), "/tmp"]
        for base in candidates {
            let template = (base as NSString).appendingPathComponent("momo-XXXXXXXX")
            // Leave room for "/mcp.sock".
            guard UnixSocket.fits(template + "/mcp.sock") else { continue }
            var bytes = Array(template.utf8CString)
            guard let created = mkdtemp(&bytes) else {
                throw UnixSocket.Failure(call: "mkdtemp", code: errno)
            }
            let path = String(cString: created)
            // mkdtemp already uses 0700; make it explicit regardless of the umask.
            chmod(path, 0o700)
            return path
        }
        throw UnixSocket.Failure(call: "socket path", code: ENAMETOOLONG)
    }
}

/// One client of an ``MCPSocketServer``.
///
/// Reading happens on the server's queue. Every write and the final `close` happen on a
/// private serial queue, so a response can never be written to a closed (or reused)
/// descriptor.
private final class Connection: @unchecked Sendable {
    private let fd: Int32
    private let server: MCPServer
    private let queue: DispatchQueue
    private let writer = DispatchQueue(label: "app.momo.mcp.socket-connection")
    private var source: (any DispatchSourceRead)?
    private var buffer = Data()
    private var requests: [UUID: Task<Void, Never>] = [:]
    /// Only touched on `writer`.
    private var isClosed = false
    /// Called on `queue` once the connection closed by itself.
    var onClose: (() -> Void)?

    init(fd: Int32, server: MCPServer, queue: DispatchQueue) {
        self.fd = fd
        self.server = server
        self.queue = queue
    }

    /// Starts reading. Call on `queue`.
    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        let fd = fd
        let writer = writer
        source.setCancelHandler { [weak self] in
            // Close after any queued responses, never while a write might still use it.
            let connection = self
            writer.async {
                connection?.isClosed = true
                Darwin.close(fd)
            }
        }
        self.source = source
        source.resume()
    }

    /// Closes the connection and cancels its running requests. Call on any thread.
    func close() {
        queue.async { self.shutDown(notify: false) }
    }

    private func shutDown(notify: Bool) {
        guard let source else { return }
        self.source = nil
        source.cancel()
        for request in requests.values { request.cancel() }
        requests = [:]
        if notify { onClose?() }
        onClose = nil
    }

    /// Reads whatever arrived and handles complete lines. Runs on `queue`.
    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                // A single message this large is not something Momo's tools produce.
                if buffer.count > 16 * 1024 * 1024 {
                    shutDown(notify: true)
                    return
                }
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                break
            } else {
                // End of file or a real error: the client went away.
                handleLines()
                shutDown(notify: true)
                return
            }
        }
        handleLines()
    }

    private func handleLines() {
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            handle(line)
        }
    }

    private func handle(_ line: String) {
        guard let message = try? JSONValue.parse(line) else {
            send(MCPServer.error(id: .null, code: -32700, message: "Parse error"))
            return
        }
        let id = UUID()
        let server = server
        requests[id] = Task { [weak self] in
            let response = await server.handle(message)
            guard let self else { return }
            if let response, !Task.isCancelled { self.send(response) }
            self.queue.async { self.requests[id] = nil }
        }
    }

    private func send(_ message: JSONValue) {
        let data = Data((message.jsonString + "\n").utf8)
        writer.async {
            guard !self.isClosed else { return }
            UnixSocket.writeAll(data, to: self.fd)
        }
    }
}
