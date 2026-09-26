import Foundation
import MomoKit

// Helpers that let people connect a brain from Settings without ever opening Terminal. Momo
// finds apps the user installed, starts their own sign-in flows and talks to their local APIs.
// The only software it downloads are the official Codex and Gemini command line tools (see
// `ToolInstaller`), so people can use their subscriptions.

/// The result of trying an API key.
public enum KeyCheck: Equatable, Sendable {
    /// The provider accepted the key.
    case valid
    /// The provider rejected the key.
    case rejected
    /// The provider could not be reached, or answered with an unexpected error.
    case unreachable
}

/// Recognises and checks API keys.
public enum APIKeySetup {
    /// Whether `text` looks like an API key for `providerID`, for spotting a key the user just
    /// copied.
    public static func looksLikeKey(_ text: String, for providerID: String) -> Bool {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 30, key.count <= 300,
            key.allSatisfy({ $0.isASCII && !$0.isWhitespace })
        else { return false }
        switch providerID {
        case "anthropic": return key.hasPrefix("sk-ant-")
        case "openrouter": return key.hasPrefix("sk-or-")
        case "openai":
            return key.hasPrefix("sk-") && !key.hasPrefix("sk-ant-") && !key.hasPrefix("sk-or-")
        case "gemini-api": return key.hasPrefix("AIza") && key.count == 39
        default: return false
        }
    }

    /// Asks the provider whether it accepts `key`, using a free request that lists models or
    /// describes the key.
    public static func validate(
        _ key: String, for providerID: String, session: URLSession = .shared
    ) async -> KeyCheck {
        guard let request = request(for: providerID, key: key) else { return .unreachable }
        do {
            let (_, response) = try await session.data(for: request)
            return interpret(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0, for: providerID)
        } catch {
            return .unreachable
        }
    }

    static func interpret(status: Int, for providerID: String) -> KeyCheck {
        switch status {
        // A rate limit means the key itself works.
        case 200..<300, 429: .valid
        // Google answers 400 "API key not valid" for a malformed key.
        case 400 where providerID == "gemini-api": .rejected
        case 401, 403: .rejected
        default: .unreachable
        }
    }

    static func request(for providerID: String, key: String) -> URLRequest? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        var headers: [String: String] = [:]
        switch providerID {
        case "anthropic":
            url = URL(literal: "https://api.anthropic.com/v1/models")
            headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]
        case "openai":
            url = URL(literal: "https://api.openai.com/v1/models")
            headers = ["Authorization": "Bearer \(key)"]
        case "gemini-api":
            url = URL(literal: "https://generativelanguage.googleapis.com/v1beta/models")
            headers = ["x-goog-api-key": key]
        case "openrouter":
            url = URL(literal: "https://openrouter.ai/api/v1/key")
            headers = ["Authorization": "Bearer \(key)"]
        default:
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}

/// Ollama: a free app that runs models on the Mac and offers an HTTP API.
public enum OllamaSetup {
    /// A model Momo suggests downloading.
    public struct SuggestedModel: Identifiable, Sendable, Equatable {
        public enum Tier: Sendable { case fast, balanced, smart }
        public var id: String
        public var tier: Tier
        /// Download size in gigabytes.
        public var gigabytes: Double
        /// Memory the Mac should have for the model to run comfortably, in gigabytes.
        public var minimumMemory: Double
    }

    /// Models that work well with Momo's tools and speak many languages.
    public static let suggestedModels = [
        SuggestedModel(id: "qwen3:4b", tier: .fast, gigabytes: 2.5, minimumMemory: 8),
        SuggestedModel(id: "qwen3:8b", tier: .balanced, gigabytes: 5.2, minimumMemory: 16),
        SuggestedModel(id: "qwen3:14b", tier: .smart, gigabytes: 9.3, minimumMemory: 24),
    ]

    /// The largest suggested model this Mac runs comfortably.
    public static func recommendedModel(
        memory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> SuggestedModel {
        let gigabytes = Double(memory) / 1_073_741_824
        return suggestedModels.last { $0.minimumMemory <= gigabytes + 0.5 } ?? suggestedModels[0]
    }

    /// Where the Ollama app is installed, if it is.
    public static var appURL: URL? {
        AppLocator.find(["Ollama.app"])
    }

    /// Whether Ollama is installed, as the app or as a command line tool.
    public static var isInstalled: Bool {
        appURL != nil || CommandLocator.locate("ollama") != nil
    }

    /// The native API address for an OpenAI-compatible address such as
    /// `http://localhost:11434/v1`.
    public static func apiBase(from address: String) -> URL? {
        var address = address.trimmingCharacters(in: .whitespaces)
        while address.hasSuffix("/") { address.removeLast() }
        if address.hasSuffix("/v1") { address.removeLast(3) }
        return URL(string: address)
    }

    /// The models Ollama has downloaded. Throws when Ollama is not running.
    public static func installedModels(
        base: URL, session: URLSession = .shared
    ) async throws -> [String] {
        let json = try await HTTP.getJSON(
            session: session, url: base.appendingPathComponent("api/tags"), timeout: 1.5)
        return json["models"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }

    /// Download progress for a model.
    public struct PullProgress: Sendable, Equatable {
        /// What Ollama is doing, for example "pulling manifest".
        public var status: String
        /// How much of the current file has arrived (0...1), when known.
        public var fraction: Double?
        /// Whether the model is ready.
        public var isFinished: Bool
    }

    /// Downloads `model` through Ollama, reporting progress.
    public static func pull(
        _ model: String, base: URL, session: URLSession = .shared
    ) -> AsyncThrowingStream<PullProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let lines = try await HTTP.streamLines(
                        session: session, url: base.appendingPathComponent("api/pull"),
                        headers: [:], body: ["model": .string(model), "stream": true])
                    for try await line in lines {
                        guard let progress = try parsePullLine(line) else { continue }
                        continuation.yield(progress)
                        if progress.isFinished { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func parsePullLine(_ line: String) throws -> PullProgress? {
        guard let json = try? JSONValue.parse(line) else { return nil }
        if let error = json["error"]?.stringValue { throw ProviderError(error) }
        guard let status = json["status"]?.stringValue else { return nil }
        var fraction: Double?
        if let total = json["total"]?.doubleValue, total > 0,
            let completed = json["completed"]?.doubleValue
        {
            fraction = min(1, completed / total)
        }
        return PullProgress(status: status, fraction: fraction, isFinished: status == "success")
    }
}

/// LM Studio: a free app for downloading and running models, with a local server.
public enum LMStudioSetup {
    /// Where the LM Studio app is installed, if it is.
    public static var appURL: URL? {
        AppLocator.find(["LM Studio.app"])
    }
}

/// ChatGPT through Codex. The official ChatGPT app for Mac includes the Codex engine, so
/// anyone with the app can use their plan without installing anything else.
public enum CodexSetup {
    /// Codex inside apps the user may have installed.
    static let bundledPaths = [
        "ChatGPT.app/Contents/Resources/codex", "Codex.app/Contents/Resources/codex",
    ]

    /// The Codex command line tool, the copy inside the ChatGPT app, or the one Momo
    /// downloaded.
    public static func locate() -> URL? {
        if let command = CommandLocator.locate("codex") { return command }
        for path in bundledPaths {
            for folder in AppLocator.folders {
                let candidate = folder.appendingPathComponent(path)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return ManagedTool.codex.installed
    }

    /// Whether the ChatGPT app is installed.
    public static var hasChatGPTApp: Bool {
        AppLocator.find(["ChatGPT.app"]) != nil
    }

    /// Whether the user signed in to Codex with ChatGPT or an API key.
    public static func isSignedIn() async -> Bool {
        if CodexProvider.isSignedIn { return true }
        // Credentials may live in the Keychain instead of `auth.json`.
        guard let executable = locate() else { return false }
        var output = ""
        do {
            for try await line in CommandRunner.lines(
                executable: executable, arguments: ["login", "status"], input: nil)
            {
                output += line
            }
        } catch {
            return false
        }
        return output.localizedCaseInsensitiveContains("logged in")
            && !output.localizedCaseInsensitiveContains("not logged in")
    }

    /// Starts Codex's own browser sign-in. Codex opens the sign-in page itself; the stream
    /// yields its output (which includes the page address) and finishes once the user signed
    /// in. Cancelling the stream stops the sign-in.
    public static func signIn() -> AsyncThrowingStream<String, any Error> {
        guard let executable = locate() else {
            return AsyncThrowingStream {
                $0.finish(throwing: ProviderError("Codex was not found."))
            }
        }
        return CommandRunner.lines(executable: executable, arguments: ["login"], input: nil)
    }
}

/// Gemini through the user's Google account (including Google AI Pro and Ultra plans) and the
/// Gemini CLI.
public enum GeminiCLISetup {
    /// The Gemini CLI the user installed, or the one Momo downloaded.
    public static func locate() -> URL? {
        CommandLocator.locate("gemini") ?? ManagedTool.gemini.installed
    }

    /// Whether the Gemini CLI is available.
    public static var isInstalled: Bool {
        locate() != nil
    }

    /// Signs in with Google through the CLI's Agent Client Protocol mode, the same way code
    /// editors do: the CLI opens the browser and the stream finishes once the user signed in.
    /// Cancelling the stream stops the sign-in.
    public static func signIn() -> AsyncThrowingStream<String, any Error> {
        guard let executable = locate() else {
            return AsyncThrowingStream {
                $0.finish(throwing: ProviderError("The Gemini CLI was not found."))
            }
        }
        return ACPSignIn.run(executable: executable, method: "oauth-personal")
    }
}

/// Just enough of the Agent Client Protocol (JSON-RPC over standard input and output) to
/// start an agent's own sign-in.
enum ACPSignIn {
    static func run(executable: URL, method: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--acp"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = CommandLocator.searchPath
            environment["NO_COLOR"] = "1"
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            let finished = LockedValue(false)
            let buffer = LockedValue(Data())
            @Sendable func finish(_ error: (any Error)?) {
                let first = finished.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                if let error { continuation.finish(throwing: error) } else { continuation.finish() }
                if process.isRunning { process.terminate() }
            }
            @Sendable func send(_ message: JSONValue) {
                input.fileHandleForWriting.write(Data((message.jsonString + "\n").utf8))
            }

            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                let lines: [String] = buffer.withLock { data in
                    data.append(chunk)
                    var lines: [String] = []
                    while let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                        lines.append(
                            String(decoding: data[data.startIndex..<newline], as: UTF8.self))
                        data.removeSubrange(data.startIndex...newline)
                    }
                    return lines
                }
                for line in lines {
                    guard let message = try? JSONValue.parse(line) else {
                        continuation.yield(line)
                        continue
                    }
                    switch reply(to: message) {
                    case .initialized:
                        send([
                            "jsonrpc": "2.0", "id": 2, "method": "authenticate",
                            "params": ["methodId": .string(method)],
                        ])
                    case .signedIn:
                        finish(nil)
                    case .failed(let reason):
                        finish(ProviderError(reason))
                    case .other:
                        continuation.yield(line)
                    }
                }
            }
            process.terminationHandler = { _ in
                output.fileHandleForReading.readabilityHandler = nil
                finish(ProviderError("The sign-in stopped before it finished."))
            }
            do {
                try process.run()
                send([
                    "jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": [
                        "protocolVersion": 1,
                        "clientCapabilities": [
                            "fs": ["readTextFile": false, "writeTextFile": false]
                        ],
                    ],
                ])
            } catch {
                finish(error)
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
        }
    }

    enum Reply: Equatable {
        case initialized, signedIn, failed(String), other
    }

    /// What a message from the agent means for the sign-in.
    static func reply(to message: JSONValue) -> Reply {
        guard let id = message["id"]?.intValue, message["method"] == nil else { return .other }
        if let error = message["error"] {
            return .failed(error["message"]?.stringValue ?? "The sign-in failed.")
        }
        switch id {
        case 1: return .initialized
        case 2: return .signedIn
        default: return .other
        }
    }
}

/// Finds apps in the usual Applications folders.
enum AppLocator {
    static var folders: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
        ]
    }

    static func find(_ names: [String]) -> URL? {
        for name in names {
            for folder in folders {
                let url = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}

/// Finds the first web address in a line of command output, such as a sign-in page.
public func firstWebAddress(in text: String) -> URL? {
    guard let start = text.range(of: "https://") else { return nil }
    let address = text[start.lowerBound...].prefix { !$0.isWhitespace && $0 != "\"" }
    return URL(string: String(address))
}

/// Runs an installed tool on the user's behalf, so they never have to type its command.
public enum ToolCommand {
    /// Runs `executable` with `arguments` and reports whether it succeeded.
    public static func succeeds(_ executable: URL, _ arguments: [String]) async -> Bool {
        do {
            for try await _ in CommandRunner.lines(
                executable: executable, arguments: arguments, input: nil)
            {}
            return true
        } catch {
            return false
        }
    }
}
