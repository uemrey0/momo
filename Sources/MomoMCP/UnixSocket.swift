import Darwin
import Foundation

/// Small, careful wrappers around POSIX Unix domain sockets, shared by the in-app bridge
/// server and the `momo-mcp --bridge` relay.
enum UnixSocket {
    /// An error from a system call, with the call's name and `errno`.
    struct Failure: LocalizedError, Equatable {
        var call: String
        var code: Int32

        var errorDescription: String? {
            "\(call) failed: \(String(cString: strerror(code)))"
        }
    }

    /// The largest socket path in bytes, excluding the terminating NUL (`sun_path` is 104
    /// bytes on macOS).
    static let maximumPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// Whether `path` fits into `sun_path`.
    static func fits(_ path: String) -> Bool {
        path.utf8.count <= maximumPathLength
    }

    /// Creates a listening socket bound to `path`, readable and writable only by the owner.
    static func listen(at path: String, backlog: Int32 = 8) throws -> Int32 {
        let fd = try makeSocket()
        do {
            try withAddress(path) { address, length in
                guard Darwin.bind(fd, address, length) == 0 else {
                    throw Failure(call: "bind", code: errno)
                }
            }
            guard chmod(path, 0o600) == 0 else { throw Failure(call: "chmod", code: errno) }
            guard Darwin.listen(fd, backlog) == 0 else {
                throw Failure(call: "listen", code: errno)
            }
            try setNonBlocking(fd)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    /// Connects to the socket at `path`. The returned descriptor is blocking.
    static func connect(to path: String) throws -> Int32 {
        let fd = try makeSocket()
        do {
            try withAddress(path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else {
                    throw Failure(call: "connect", code: errno)
                }
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    /// Makes `fd` non-blocking.
    static func setNonBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Failure(call: "fcntl", code: errno)
        }
    }

    /// Writes all of `data`, waiting for the descriptor when it is non-blocking and full.
    /// Returns `false` when the peer went away or the write timed out.
    @discardableResult
    static func writeAll(_ data: Data, to fd: Int32, timeout: Int32 = 10_000) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                } else if written < 0 && errno == EINTR {
                    continue
                } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    guard poll(&poller, 1, timeout) > 0 else { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(call: "socket", code: errno) }
        // Report a closed peer as EPIPE instead of killing the process with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    private static func withAddress(
        _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void
    ) throws {
        let bytes = Array(path.utf8)
        guard bytes.count <= maximumPathLength else {
            throw Failure(call: "socket path", code: ENAMETOOLONG)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                try body(address, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
