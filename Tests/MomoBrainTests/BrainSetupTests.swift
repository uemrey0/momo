import Foundation
import Testing

@testable import MomoBrain

@Suite("Brain setup")
struct BrainSetupTests {
    @Test("recognises copied API keys for the right provider")
    func recognisesKeys() {
        let anthropic = "sk-ant-api03-" + String(repeating: "a", count: 40)
        let openAI = "sk-proj-" + String(repeating: "b", count: 40)
        let openRouter = "sk-or-v1-" + String(repeating: "c", count: 40)
        let gemini = "AIza" + String(repeating: "d", count: 35)

        #expect(APIKeySetup.looksLikeKey(anthropic, for: "anthropic"))
        #expect(!APIKeySetup.looksLikeKey(anthropic, for: "openai"))
        #expect(APIKeySetup.looksLikeKey(" \(openAI)\n", for: "openai"))
        #expect(!APIKeySetup.looksLikeKey(openRouter, for: "openai"))
        #expect(APIKeySetup.looksLikeKey(openRouter, for: "openrouter"))
        #expect(APIKeySetup.looksLikeKey(gemini, for: "gemini-api"))
        #expect(!APIKeySetup.looksLikeKey("sk-short", for: "openai"))
        #expect(
            !APIKeySetup.looksLikeKey(
                "sk-" + String(repeating: "x", count: 20) + " words here", for: "openai"))
    }

    @Test("builds a free check request with the provider's auth header")
    func buildsCheckRequests() {
        let anthropic = APIKeySetup.request(for: "anthropic", key: " key ")
        #expect(anthropic?.value(forHTTPHeaderField: "x-api-key") == "key")
        #expect(anthropic?.value(forHTTPHeaderField: "anthropic-version") != nil)
        let gemini = APIKeySetup.request(for: "gemini-api", key: "key")
        #expect(gemini?.value(forHTTPHeaderField: "x-goog-api-key") == "key")
        #expect(gemini?.url?.query == nil)
        #expect(
            APIKeySetup.request(for: "openrouter", key: "key")?
                .value(forHTTPHeaderField: "Authorization") == "Bearer key")
        #expect(APIKeySetup.request(for: "ollama", key: "key") == nil)
    }

    @Test("reads the provider's answer about a key")
    func interpretsKeyChecks() {
        #expect(APIKeySetup.interpret(status: 200, for: "openai") == .valid)
        #expect(APIKeySetup.interpret(status: 429, for: "openai") == .valid)
        #expect(APIKeySetup.interpret(status: 401, for: "anthropic") == .rejected)
        #expect(APIKeySetup.interpret(status: 400, for: "gemini-api") == .rejected)
        #expect(APIKeySetup.interpret(status: 400, for: "openai") == .unreachable)
        #expect(APIKeySetup.interpret(status: 503, for: "openai") == .unreachable)
    }

    @Test("finds Ollama's native API next to its OpenAI-compatible one")
    func ollamaAPIBase() {
        #expect(
            OllamaSetup.apiBase(from: "http://localhost:11434/v1")?.absoluteString
                == "http://localhost:11434")
        #expect(
            OllamaSetup.apiBase(from: "http://127.0.0.1:11434/v1/")?.absoluteString
                == "http://127.0.0.1:11434")
    }

    @Test("suggests a model that fits the Mac's memory")
    func recommendsModelForMemory() {
        let gigabyte: UInt64 = 1_073_741_824
        #expect(OllamaSetup.recommendedModel(memory: 8 * gigabyte).tier == .fast)
        #expect(OllamaSetup.recommendedModel(memory: 16 * gigabyte).tier == .balanced)
        #expect(OllamaSetup.recommendedModel(memory: 64 * gigabyte).tier == .smart)
    }

    @Test("lists downloaded Ollama models")
    func listsOllamaModels() async throws {
        let (session, host) = MockURLProtocol.session(responses: [
            .init(body: #"{"models":[{"name":"qwen3:8b"},{"name":"llama3.2:3b"}]}"#)
        ])
        let base = try #require(URL(string: "http://\(host)"))
        let models = try await OllamaSetup.installedModels(base: base, session: session)
        #expect(models == ["qwen3:8b", "llama3.2:3b"])
    }

    @Test("reports model download progress")
    func pullsOllamaModel() async throws {
        let body = [
            #"{"status":"pulling manifest"}"#,
            #"{"status":"pulling abc","total":200,"completed":50}"#,
            #"{"status":"success"}"#,
        ].joined(separator: "\n")
        let (session, host) = MockURLProtocol.session(responses: [.init(body: body)])
        let base = try #require(URL(string: "http://\(host)"))
        var updates: [OllamaSetup.PullProgress] = []
        for try await progress in OllamaSetup.pull("qwen3:8b", base: base, session: session) {
            updates.append(progress)
        }
        #expect(updates.count == 3)
        #expect(updates[1].fraction == 0.25)
        #expect(updates.last?.isFinished == true)
        #expect(MockURLProtocol.requestBodies(host: host).first?.contains("qwen3:8b") == true)
    }

    @Test("surfaces a failed model download")
    func failedPull() {
        #expect(throws: ProviderError.self) {
            try OllamaSetup.parsePullLine(#"{"error":"pull model manifest: file does not exist"}"#)
        }
    }

    @Test("finds the sign-in page in command output")
    func findsWebAddress() {
        let line = "Starting local login server. Open https://auth.openai.com/oauth?x=1 to continue"
        #expect(firstWebAddress(in: line)?.host() == "auth.openai.com")
        #expect(firstWebAddress(in: "nothing here") == nil)
    }
}
