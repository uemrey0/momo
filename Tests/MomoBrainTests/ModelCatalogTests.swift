import Foundation
import MomoKit
import Testing

@testable import MomoBrain

@Suite("Model catalog")
struct ModelCatalogTests {
    @Test("reads Claude models, newest first and recommended")
    func anthropicModels() throws {
        let json = try JSONValue.parse(
            #"{"data":[{"id":"claude-new","display_name":"Claude New"},{"id":"claude-old","display_name":"Claude Old"}]}"#
        )
        let choices = try ModelCatalog.parseAnthropic(json)
        #expect(choices.map(\.name) == ["Claude New", "Claude Old"])
        #expect(choices.first?.isRecommended == true)
    }

    @Test("keeps only OpenAI chat models, newest first")
    func openAIModels() throws {
        let json = try JSONValue.parse(
            #"{"data":[{"id":"gpt-4o","created":1},{"id":"gpt-5","created":3},{"id":"whisper-1","created":5},{"id":"text-embedding-3-small","created":4},{"id":"gpt-4o-audio-preview","created":6},{"id":"o3","created":2},{"id":"omni-moderation-latest","created":7}]}"#
        )
        #expect(try ModelCatalog.parseOpenAI(json).map(\.id) == ["gpt-5", "o3", "gpt-4o"])
    }

    @Test("keeps Gemini models that can chat")
    func geminiModels() throws {
        let json = try JSONValue.parse(
            #"{"models":[{"name":"models/gemini-flash-latest","displayName":"Gemini Flash Latest","description":"Fast. Very good.","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-embedding-001","supportedGenerationMethods":["embedContent"]},{"name":"models/gemini-2.5-flash-preview-tts","supportedGenerationMethods":["generateContent"]}]}"#
        )
        let choices = try ModelCatalog.parseGemini(json)
        #expect(choices.map(\.id) == ["gemini-flash-latest"])
        #expect(choices.first?.detail == "Fast.")
        #expect(choices.first?.isRecommended == true)
    }

    @Test("puts OpenRouter's automatic choice first")
    func openRouterModels() throws {
        let json = try JSONValue.parse(
            #"{"data":[{"id":"openrouter/auto","name":"Auto Router"},{"id":"anthropic/claude","name":"Claude"}]}"#
        )
        let choices = try ModelCatalog.parseOpenRouter(json)
        #expect(choices.map(\.id) == ["openrouter/auto", "anthropic/claude"])
        #expect(choices.first?.isRecommended == true)
    }

    @Test("reads Codex's model list and skips hidden models")
    func codexModels() throws {
        let json = try JSONValue.parse(
            #"{"data":[{"id":"gpt-new","displayName":"GPT New","description":"Frontier.","hidden":false,"isDefault":true},{"id":"gpt-secret","hidden":true,"isDefault":false}]}"#
        )
        let choices = ModelCatalog.parseCodex(json)
        #expect(
            choices == [
                ModelChoice(
                    id: "gpt-new", name: "GPT New", detail: "Frontier.", isRecommended: true)
            ])
    }

    @Test("offers the Gemini CLI's aliases with Auto first")
    func geminiCLIChoices() {
        #expect(ModelCatalog.geminiCLIChoices.first?.id == "")
        #expect(ModelCatalog.geminiCLIChoices.map(\.id).contains("pro"))
    }

    @Test("gets a JSON-RPC answer from a server that stays running")
    func jsonRPCRequest() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = folder.appendingPathComponent("server")
        try """
        #!/bin/sh
        read first
        echo '{"id":1,"result":{}}'
        read second
        echo '{"method":"note"}'
        echo '{"id":2,"result":{"data":[1,2]}}'
        sleep 30
        """.write(to: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        let result = try await JSONRPCProcess.request(
            executable: server, arguments: [], messages: [["id": 1], ["id": 2]], responseID: 2)
        #expect(result["data"]?.arrayValue?.count == 2)
    }
}
