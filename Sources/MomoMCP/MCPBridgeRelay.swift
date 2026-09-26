import Darwin
import Foundation

/// Pipes MCP traffic between a CLI agent (standard input and output) and the tool bridge the
/// Momo app serves on a Unix socket (see ``MCPSocketServer``).
///
/// The relay is deliberately dumb: it copies bytes in both directions without parsing them,
/// so line framing is preserved exactly. It returns when the app closes the socket, which
/// happens after the agent closed its input or when the app finished the request.
public enum MCPBridgeRelay {
    /// Connects to `socketPath` and relays until the socket closes.
    ///
    /// - Parameters:
    ///   - input: Read and forwarded to the socket; on end of file the socket's write side
    ///     is shut down so the app can finish.
    ///   - output: Receives everything the app sends.
    public static func run(
        socketPath: String, input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO
    ) throws {
        let socket = try UnixSocket.connect(to: socketPath)
        defer { close(socket) }

        let upstream = Thread {
            copy(from: input, to: socket)
            shutdown(socket, SHUT_WR)
        }
        upstream.stackSize = 256 * 1024
        upstream.start()
        copy(from: socket, to: output)
    }

    /// Copies until `source` reaches end of file or either side fails. Returns immediately
    /// when a write fails.
    static func copy(from source: Int32, to destination: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count > 0 {
                guard UnixSocket.writeAll(Data(chunk[0..<count]), to: destination) else { return }
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}
