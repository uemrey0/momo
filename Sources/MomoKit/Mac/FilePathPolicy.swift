import Foundation

/// Decides which files Momo's file tools may touch.
///
/// Reading is allowed almost everywhere except places that hold passwords, keys, tokens and
/// browser data (`~/.ssh`, Keychains, cookie jars, browser profiles, `.env` files and similar).
/// Moving to the Trash is stricter: only items inside the home folder or on external volumes,
/// never the home folder's standard folders or anything in `~/Library`.
public struct FilePathPolicy: Sendable {
    /// The outcome of a check.
    public enum Verdict: Sendable, Equatable {
        case allowed
        /// Refused, with an explanation for the model.
        case denied(String)

        public var isAllowed: Bool { self == .allowed }
    }

    /// The user's home folder, injectable for tests.
    public var homeDirectory: URL
    /// Whether `.env` files may be read. Off by default because they usually hold secrets.
    public var allowsEnvironmentFiles: Bool

    public init(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        allowsEnvironmentFiles: Bool = false
    ) {
        self.homeDirectory = homeDirectory
        self.allowsEnvironmentFiles = allowsEnvironmentFiles
    }

    /// Folders inside the home folder that hold secrets, relative to it and lowercased.
    static let sensitiveHomeFolders: [String] = [
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".password-store",
        ".config/gcloud", ".config/gh", ".local/share/keyrings",
        "library/keychains", "library/cookies", "library/safari",
        "library/containers/com.apple.safari",
        "library/application support/google/chrome",
        "library/application support/chromium",
        "library/application support/bravesoftware",
        "library/application support/microsoft edge",
        "library/application support/arc",
        "library/application support/firefox",
        "library/application support/com.operasoftware.opera",
        "library/application support/vivaldi",
        "library/application support/1password",
        "library/group containers/2bua8c4s2c.com.1password",
        "library/messages",
    ]

    /// Folders outside the home folder that hold secrets, lowercased.
    static let sensitiveSystemFolders: [String] = [
        "/library/keychains", "/system/library/keychains", "/private/var/db/sudo",
        "/var/db/sudo",
    ]

    /// File names that hold secrets wherever they are, lowercased.
    static let sensitiveFileNames: Set<String> = [
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".netrc", ".pgpass", ".npmrc", ".pypirc",
        ".git-credentials", "master.passwd", "shadow",
    ]

    /// File extensions of key and password stores, lowercased.
    static let sensitiveExtensions: Set<String> = [
        "keychain", "keychain-db", "p12", "pfx", "kdbx", "agilekeychain", "opvault",
    ]

    /// `.env` variants that are meant to be shared and hold no secrets.
    static let harmlessEnvironmentSuffixes = [".example", ".sample", ".template", ".dist"]

    /// Turns what a model wrote (`~/Documents/a.txt`, `Desktop`, `/tmp/x`) into an absolute,
    /// standardized file URL with symbolic links resolved. Relative paths start at the home
    /// folder.
    public func resolve(_ path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        if trimmed == "~" || trimmed.isEmpty {
            url = homeDirectory
        } else if trimmed.hasPrefix("~/") {
            url = homeDirectory.appendingPathComponent(String(trimmed.dropFirst(2)))
        } else if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
        } else {
            url = homeDirectory.appendingPathComponent(trimmed)
        }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Whether Momo may read the file or list the folder at `path`.
    public func verdictForReading(_ path: String) -> Verdict {
        verdictForReading(resolve(path))
    }

    /// Whether Momo may read the file or list the folder at an already resolved URL.
    public func verdictForReading(_ url: URL) -> Verdict {
        let denial = Verdict.denied(
            "This location holds passwords, keys, tokens or browser data, so Momo doesn't open it."
        )
        let path = url.path.lowercased()
        let home = homePath
        if path.hasPrefix(home + "/") {
            let relative = String(path.dropFirst(home.count + 1))
            for folder in Self.sensitiveHomeFolders where Self.isSame(relative, orInside: folder) {
                return denial
            }
        }
        for folder in Self.sensitiveSystemFolders where Self.isSame(path, orInside: folder) {
            return denial
        }
        let name = url.lastPathComponent.lowercased()
        if Self.sensitiveFileNames.contains(name) { return denial }
        if Self.sensitiveExtensions.contains(url.pathExtension.lowercased()) { return denial }
        if !allowsEnvironmentFiles, Self.isEnvironmentFile(name) {
            return .denied(
                "Environment (.env) files usually hold secrets, so Momo doesn't read them.")
        }
        return .allowed
    }

    /// Whether Momo may move the item at `path` to the Trash.
    public func verdictForTrashing(_ path: String) -> Verdict {
        verdictForTrashing(resolve(path))
    }

    /// Whether Momo may move the item at an already resolved URL to the Trash.
    public func verdictForTrashing(_ url: URL) -> Verdict {
        if case .denied(let reason) = verdictForReading(url) { return .denied(reason) }
        let path = url.path.lowercased()
        let home = homePath
        let onExternalVolume =
            path.hasPrefix("/volumes/") && path.split(separator: "/").count > 2
        guard path.hasPrefix(home + "/") || onExternalVolume else {
            return .denied("Momo only moves items inside the home folder or on external drives.")
        }
        if path.hasPrefix(home + "/") {
            let relative = String(path.dropFirst(home.count + 1))
            let components = relative.split(separator: "/")
            if components.count == 1 {
                return .denied("Momo doesn't move the home folder's own folders to the Trash.")
            }
            if components.first == "library" {
                return .denied("Momo doesn't move items in the Library folder to the Trash.")
            }
        }
        return .allowed
    }

    private var homePath: String {
        homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }

    private static func isSame(_ path: String, orInside folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    private static func isEnvironmentFile(_ name: String) -> Bool {
        guard name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") else {
            return false
        }
        return !harmlessEnvironmentSuffixes.contains { name.hasSuffix($0) }
    }
}
