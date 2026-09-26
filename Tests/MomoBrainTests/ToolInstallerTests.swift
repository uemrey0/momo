import Foundation
import MomoKit
import Testing

@testable import MomoBrain

@Suite("Tool installer")
struct ToolInstallerTests {
    private let release: JSONValue = [
        "assets": [
            [
                "name": "gemini-darwin-arm64-unsigned.zip",
                "browser_download_url":
                    "https://github.com/google-gemini/gemini-cli/releases/download/v1/gemini-darwin-arm64-unsigned.zip",
                "digest": "sha256:ABC123",
                "size": 42,
            ],
            [
                "name": "evil.zip",
                "browser_download_url": "https://example.com/evil.zip",
                "digest": "sha256:def",
            ],
        ]
    ]

    @Test("finds the asset for this Mac with its checksum")
    func findsAsset() throws {
        let asset = try ToolInstaller.asset(named: "gemini-darwin-arm64-unsigned.zip", in: release)
        #expect(asset.url.host() == "github.com")
        #expect(asset.sha256 == "abc123")
        #expect(asset.size == 42)
    }

    @Test("refuses assets that are missing, off GitHub or without a checksum")
    func refusesUnsafeAssets() {
        #expect(throws: ProviderError.self) {
            try ToolInstaller.asset(named: "evil.zip", in: release)
        }
        #expect(throws: ProviderError.self) {
            try ToolInstaller.asset(named: "missing.zip", in: release)
        }
    }

    @Test("computes SHA-256 checksums of files")
    func checksums() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-sha-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(
            try ToolInstaller.sha256(of: file)
                == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test("names the executable inside each archive")
    func archivedNames() {
        #expect(ManagedTool.gemini.archivedName == "gemini")
        #expect(ManagedTool.codex.archivedName.hasPrefix("codex-"))
        #expect(!ManagedTool.codex.archivedName.hasSuffix(".tar.gz"))
    }
}

@Suite("ACP sign-in")
struct ACPSignInTests {
    @Test("reads the agent's replies")
    func readsReplies() throws {
        #expect(
            ACPSignIn.reply(to: try JSONValue.parse(#"{"jsonrpc":"2.0","id":1,"result":{}}"#))
                == .initialized)
        #expect(
            ACPSignIn.reply(to: try JSONValue.parse(#"{"jsonrpc":"2.0","id":2,"result":null}"#))
                == .signedIn)
        #expect(
            ACPSignIn.reply(
                to: try JSONValue.parse(#"{"jsonrpc":"2.0","id":2,"error":{"message":"denied"}}"#))
                == .failed("denied"))
        #expect(
            ACPSignIn.reply(
                to: try JSONValue.parse(#"{"jsonrpc":"2.0","method":"session/update"}"#))
                == .other)
    }

    @Test("initializes, asks for the sign-in method and finishes when signed in")
    func signsInWithFakeAgent() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("requests.txt")
        let agent = folder.appendingPathComponent("agent")
        try """
        #!/bin/sh
        read first; echo "$first" >> "\(log.path)"
        echo '{"jsonrpc":"2.0","id":1,"result":{"authMethods":[]}}'
        read second; echo "$second" >> "\(log.path)"
        echo 'Opening the browser'
        echo '{"jsonrpc":"2.0","id":2,"result":{}}'
        sleep 10
        """.write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)

        var lines: [String] = []
        for try await line in ACPSignIn.run(executable: agent, method: "oauth-personal") {
            lines.append(line)
        }
        #expect(lines == ["Opening the browser"])
        let requests = try String(contentsOf: log, encoding: .utf8)
        #expect(requests.contains("\"initialize\""))
        #expect(requests.contains("\"authenticate\""))
        #expect(requests.contains("oauth-personal"))
    }

    @Test("reports a failed sign-in")
    func failedSignIn() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = folder.appendingPathComponent("agent")
        try """
        #!/bin/sh
        read first
        echo '{"jsonrpc":"2.0","id":1,"result":{}}'
        read second
        echo '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"cancelled"}}'
        sleep 10
        """.write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)

        await #expect(throws: ProviderError.self) {
            for try await _ in ACPSignIn.run(executable: agent, method: "oauth-personal") {}
        }
    }
}
