import Foundation

/// A version like `1.2.3`, parsed leniently from tags such as `v1.2` or `1.2.3-beta.1`.
public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Text after `-`, e.g. `beta.1`. Pre-releases sort before the release.
    public var prerelease: String?

    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        let parts = value.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 3, numbers.allSatisfy({ $0 != nil }) else {
            return nil
        }
        major = numbers[0] ?? 0
        minor = numbers.count > 1 ? numbers[1] ?? 0 : 0
        patch = numbers.count > 2 ? numbers[2] ?? 0 : 0
        prerelease = parts.count > 1 ? String(parts[1]) : nil
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _): return false
        case (_, nil): return true
        case (let left?, let right?):
            return left.compare(right, options: .numeric) == .orderedAscending
        }
    }
}
