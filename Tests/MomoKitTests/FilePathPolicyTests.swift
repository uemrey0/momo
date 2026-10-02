import Foundation
import Testing

@testable import MomoKit

@Suite("FilePathPolicy")
struct FilePathPolicyTests {
    let policy = FilePathPolicy(homeDirectory: URL(fileURLWithPath: "/Users/test"))

    @Test("resolves home-relative and relative paths")
    func resolves() {
        #expect(policy.resolve("~").path == "/Users/test")
        #expect(policy.resolve("~/Documents/a.txt").path == "/Users/test/Documents/a.txt")
        #expect(policy.resolve("Desktop").path == "/Users/test/Desktop")
        #expect(policy.resolve("/Users/test/Documents/../.ssh").path == "/Users/test/.ssh")
    }

    @Test(
        "refuses to read secrets",
        arguments: [
            "~/.ssh", "~/.ssh/config", "~/Documents/../.ssh/id_ed25519", "~/.gnupg/pubring.kbx",
            "~/.aws/credentials", "~/Library/Keychains/login.keychain-db",
            "~/Library/Cookies/Cookies.binarycookies",
            "~/Library/Application Support/Google/Chrome/Default/Login Data",
            "~/Library/Application Support/Firefox/Profiles/x/logins.json",
            "~/Library/Safari/History.db", "~/LIBRARY/KEYCHAINS", "~/Projects/app/.env",
            "~/Projects/app/.env.local", "~/Projects/app/production.env", "/Library/Keychains",
            "~/backup/id_rsa", "~/Downloads/cert.p12", "~/.netrc", "~/vault.kdbx",
            "~/.codex/auth.json", "~/.gemini/oauth_creds.json", "~/.claude/.credentials.json",
            "~/.claude.json", "~/.zsh_history", "~/.bash_history", "~/.python_history",
            "~/.local/share/fish/fish_history", "~/.zsh_sessions/A.history",
            "~/.config/github-copilot/hosts.json", "~/.config/op/config",
            "~/.cargo/credentials.toml", "~/.vault-token", "~/.cache/huggingface/token",
            "~/Library/Mail/V10/MailData/Envelope Index",
        ])
    func refusesSecrets(_ path: String) {
        #expect(!policy.verdictForReading(path).isAllowed)
    }

    @Test(
        "reads ordinary files",
        arguments: [
            "~/Documents/report.pdf", "~/Desktop", "~/.zshrc", "~/Projects/app/.env.example",
            "~/.ssh-notes.txt", "~/backup/id_rsa.pub", "/Applications",
            "~/Library/Mobile Documents",
        ])
    func readsOrdinaryFiles(_ path: String) {
        #expect(policy.verdictForReading(path).isAllowed)
    }

    @Test("reads .env files when allowed")
    func environmentFilesOptIn() {
        let relaxed = FilePathPolicy(
            homeDirectory: URL(fileURLWithPath: "/Users/test"), allowsEnvironmentFiles: true)
        #expect(relaxed.verdictForReading("~/Projects/app/.env").isAllowed)
        #expect(!relaxed.verdictForReading("~/.ssh/id_rsa").isAllowed)
    }

    @Test(
        "trashes only the user's own items",
        arguments: [
            ("~/Desktop/old.txt", true), ("~/Downloads/installer.dmg", true),
            ("/Volumes/USB/photo.jpg", true), ("~/Desktop", false), ("~", false),
            ("~/Library/Preferences/x.plist", false), ("/Applications/Safari.app", false),
            ("/System/Library", false), ("/Volumes/USB", false), ("~/.ssh/id_rsa", false),
        ])
    func trashing(_ path: String, allowed: Bool) {
        #expect(policy.verdictForTrashing(path).isAllowed == allowed)
    }
}

@Suite("SpotlightQuery")
struct SpotlightQueryTests {
    @Test("combines name, content, kind and date")
    func combines() {
        let query = SpotlightQuery(
            name: "tax 2025", content: "invoice", kind: "PDF", modifiedWithinDays: 7)
        #expect(
            query.queryString
                == "kMDItemFSName == \"*tax*\"cd && kMDItemFSName == \"*2025*\"cd && "
                + "kMDItemTextContent == \"invoice*\"cdw && "
                + "kMDItemContentTypeTree == \"com.adobe.pdf\" && "
                + "kMDItemFSContentChangeDate >= $time.today(-7)")
    }

    @Test("escapes quotes, wildcards and backslashes")
    func escapes() {
        #expect(SpotlightQuery.escape(#"a"b*c\d"#) == #"a\"b\*c\\d"#)
        let query = SpotlightQuery(name: #"x" ||"#)
        #expect(
            query.queryString == #"kMDItemFSName == "*x\"*"cd && kMDItemFSName == "*||*"cd"#)
    }

    @Test("needs at least one criterion and a known kind")
    func invalid() {
        #expect(SpotlightQuery().queryString == nil)
        #expect(SpotlightQuery(name: "  ").queryString == nil)
        #expect(SpotlightQuery(kind: "hologram").queryString == nil)
    }
}

@Suite("OutputText")
struct OutputTextTests {
    @Test("truncates long text and says how much is missing")
    func truncates() {
        #expect(OutputText.truncate("short", limit: 10) == "short")
        #expect(
            OutputText.truncate("abcdefghij", limit: 4) == "abcd\n… (6 more characters not shown)")
    }
}
