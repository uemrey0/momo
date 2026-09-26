import Darwin
import Foundation

/// Talks to an MCP server listening on a Unix domain socket, such as ``MCPSocketServer``.
public final class UnixSocketTransport: MCPTransport, @unchecked Sendable {
    public let lines: AsyncThrowingStream<String, any Error>
    private let socket: Socket

    /// Connects to the socket at `path`.
    public init(path: String) throws {
        let socket = Socket(fd: try UnixSocket.connect(to: path))
        self.socket = socket
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        lines = stream
        let reader = Thread {
            let buffer = LineBuffer()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = chunk.withUnsafeMutableBytes {
                    read(socket.fd, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    for line in buffer.append(Data(chunk[0..<count])) { continuation.yield(line) }
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            continuation.finish()
            socket.release()
        }
        reader.start()
    }

    deinit {
        socket.shutDown()
    }

    public func send(_ line: String) async throws {
        guard socket.write(Data((line + "\n").utf8)) else { throw MCPClient.ClientError.closed }
    }

    public func close() async {
        socket.shutDown()
    }

    /// The descriptor and its state. The reader thread owns the descriptor and closes it once
    /// the connection ends, so neither a blocked read nor a write can race the close.
    private final class Socket: @unchecked Sendable {
        let fd: Int32
        private let lock = NSLock()
        private var isShutDown = false
        private var isReleased = false

        init(fd: Int32) {
            self.fd = fd
        }

        func write(_ data: Data) -> Bool {
            lock.withLock { !isShutDown && !isReleased && UnixSocket.writeAll(data, to: fd) }
        }

        /// Ends the connection; wakes the reader, which then releases the descriptor.
        func shutDown() {
            lock.withLock {
                guard !isShutDown, !isReleased else { return }
                isShutDown = true
                Darwin.shutdown(fd, SHUT_RDWR)
            }
        }

        func release() {
            lock.withLock {
                isReleased = true
                Darwin.close(fd)
            }
        }
    }
}
