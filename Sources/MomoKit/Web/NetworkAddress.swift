import Darwin
import Foundation

/// An IPv4 or IPv6 address, for telling public internet addresses from the user's own
/// network and this Mac.
public enum NetworkAddress: Sendable, Hashable {
    /// An IPv4 address in host byte order.
    case v4(UInt32)
    /// The 16 bytes of an IPv6 address.
    case v6([UInt8])

    /// Parses an address literal the way the system's resolver does, so shortened and
    /// octal or hexadecimal forms (`127.1`, `0177.0.0.1`, `0x7f000001`) and every IPv6
    /// spelling (`0:0:0:0:0:0:0:1`) are recognized. `nil` for host names.
    public static func literal(_ host: String) -> NetworkAddress? {
        var text = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
        guard !text.isEmpty else { return nil }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return .v6(bytes(of: v6)) }
        var v4 = in_addr()
        if inet_aton(text, &v4) == 1 { return .v4(UInt32(bigEndian: v4.s_addr)) }
        return nil
    }

    /// Whether the address is on the public internet: not loopback, private, link-local,
    /// shared, multicast, reserved or documentation space, also when an IPv4 address is
    /// embedded in an IPv6 one.
    public var isPublic: Bool {
        switch self {
        case .v4(let address):
            return !Self.privateV4.contains { address & $0.mask == $0.network }
        case .v6(let bytes):
            guard bytes.count == 16 else { return false }
            if let embedded = Self.embeddedV4(in: bytes) {
                return NetworkAddress.v4(embedded).isPublic
            }
            let first = bytes[0]
            let second = bytes[1]
            if first == 0xFF { return false }  // multicast
            if first & 0xFE == 0xFC { return false }  // unique local fc00::/7
            if first == 0xFE, second & 0xC0 == 0x80 || second & 0xC0 == 0xC0 {
                return false  // link-local fe80::/10 and site-local fec0::/10
            }
            if first == 0x20, second == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 {
                return false  // documentation 2001:db8::/32
            }
            return true
        }
    }

    /// The addresses `host` resolves to; an address literal resolves to itself. Empty when
    /// the name doesn't resolve.
    public static func resolve(_ host: String) async -> [NetworkAddress] {
        if let literal = literal(host) { return [literal] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: lookUp(host))
            }
        }
    }

    // MARK: - Private

    private struct Range {
        var network: UInt32
        var mask: UInt32

        init(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32, prefix: UInt32) {
            network = a << 24 | b << 16 | c << 8 | d
            mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        }
    }

    private static let privateV4: [Range] = [
        Range(0, 0, 0, 0, prefix: 8),  // "this network"
        Range(10, 0, 0, 0, prefix: 8),
        Range(100, 64, 0, 0, prefix: 10),  // carrier-grade NAT
        Range(127, 0, 0, 0, prefix: 8),
        Range(169, 254, 0, 0, prefix: 16),
        Range(172, 16, 0, 0, prefix: 12),
        Range(192, 0, 0, 0, prefix: 24),
        Range(192, 0, 2, 0, prefix: 24),
        Range(192, 168, 0, 0, prefix: 16),
        Range(198, 18, 0, 0, prefix: 15),  // benchmarking
        Range(198, 51, 100, 0, prefix: 24),
        Range(203, 0, 113, 0, prefix: 24),
        Range(224, 0, 0, 0, prefix: 4),  // multicast
        Range(240, 0, 0, 0, prefix: 4),  // reserved and broadcast
    ]

    /// The IPv4 address inside an IPv4-mapped (`::ffff:a.b.c.d`), IPv4-compatible
    /// (`::a.b.c.d`, which includes `::` and `::1`), NAT64 (`64:ff9b::/96`) or 6to4
    /// (`2002::/16`) address.
    private static func embeddedV4(in bytes: [UInt8]) -> UInt32? {
        func v4(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        let prefix = bytes[0..<10]
        if prefix.allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF { return v4(12) }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) { return v4(12) }
        if bytes[0..<12] == [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0] { return v4(12) }
        if bytes[0] == 0x20, bytes[1] == 0x02 { return v4(2) }
        return nil
    }

    private static func bytes(of address: in6_addr) -> [UInt8] {
        withUnsafeBytes(of: address) { Array($0) }
    }

    private static func lookUp(_ host: String) -> [NetworkAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [NetworkAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let socketAddress = entry.pointee.ai_addr else { continue }
            switch entry.pointee.ai_family {
            case AF_INET:
                let address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                addresses.append(.v4(UInt32(bigEndian: address.s_addr)))
            case AF_INET6:
                let address = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_addr
                }
                addresses.append(.v6(bytes(of: address)))
            default:
                continue
            }
        }
        return addresses
    }
}
