import Foundation
import MomoKit
import Testing

@testable import MomoBrain

private let pixel = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
private let image = ChatAttachment(
    name: "shot.png", content: .image(data: pixel, mimeType: "image/png"))
private let file = ChatAttachment(name: "notes.md", content: .file(text: "# Trip\nPack socks"))

@Suite("Attachments")
struct AttachmentTests {
    let turn = ChatTurn(role: .user, text: "What is this?", attachments: [image, file])

    @Test("puts documents before the message and describes images for brains that can't see")
    func context() {
        #expect(
            turn.contextText
                == "[image attached: shot.png, not visible to this brain]\n\n"
                + "[Attached file: notes.md]\n# Trip\nPack socks\n[End of notes.md]\n\n"
                + "What is this?")
        #expect(!turn.context(imagesVisible: true).contains("shot.png"))
        #expect(turn.hasImages)
        #expect(turn.images.first?.mimeType == "image/png")
    }

    @Test("sends images to Claude as base64 image blocks followed by the text")
    func anthropic() throws {
        let content = AnthropicProvider.content(of: turn)
        let blocks = try #require(content.arrayValue)
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"]?.stringValue == "image")
        #expect(blocks[0]["source"]?["media_type"]?.stringValue == "image/png")
        #expect(blocks[0]["source"]?["data"]?.stringValue == pixel.base64EncodedString())
        #expect(blocks[1]["text"]?.stringValue?.hasSuffix("What is this?") == true)
        #expect(blocks[1]["text"]?.stringValue?.contains("Pack socks") == true)

        let plain = AnthropicProvider.content(of: ChatTurn(role: .user, text: "hi"))
        #expect(plain == .string("hi"))
    }

    @Test("sends images to OpenAI-compatible vision models as data URIs")
    func openAIVision() async throws {
        let (session, host) = MockURLProtocol.session(responses: [
            .init(body: sse([#"{"choices":[{"delta":{"content":"A PNG."}}]}"#, "[DONE]"]))
        ])
        let provider = OpenAICompatibleProvider.openAI(
            apiKey: "k", model: "gpt-5", session: session)
        let redirected = OpenAICompatibleProvider(
            info: provider.info, baseURL: URL(string: "https://\(host)/v1")!, model: "gpt-5",
            apiKey: "k", session: session)
        #expect(redirected.info.supportsImages)
        for try await _ in redirected.respond(
            to: ChatRequest(systemPrompt: "s", turns: [turn]),
            runTool: { ToolResult(callID: $0.id, name: $0.name, output: "") })
        {}
        let body = try #require(MockURLProtocol.requestBodies(host: host).first)
        let json = try JSONValue.parse(body)
        let parts = try #require(json["messages"]?.arrayValue?.last?["content"]?.arrayValue)
        #expect(parts.first?["type"]?.stringValue == "text")
        #expect(
            parts.last?["image_url"]?["url"]?.stringValue
                == "data:image/png;base64,\(pixel.base64EncodedString())")
    }

    @Test("describes images in words for models that can't see")
    func openAITextOnly() throws {
        let provider = OpenAICompatibleProvider.ollama(model: "llama3.2")
        #expect(!provider.info.supportsImages)
        let content = provider.content(of: turn)
        #expect(content.stringValue?.contains("not visible to this brain") == true)
        #expect(content.stringValue?.contains("Pack socks") == true)
    }

    @Test("recognises vision models by name")
    func visionModels() {
        #expect(OpenAICompatibleProvider.modelSupportsImages("gpt-4o-mini", providerID: "openai"))
        #expect(OpenAICompatibleProvider.modelSupportsImages("o3", providerID: "openai"))
        #expect(!OpenAICompatibleProvider.modelSupportsImages("o3-mini", providerID: "openai"))
        #expect(
            OpenAICompatibleProvider.modelSupportsImages("gemini-3-flash", providerID: "gemini-api")
        )
        #expect(OpenAICompatibleProvider.modelSupportsImages("llava:13b", providerID: "ollama"))
        #expect(
            OpenAICompatibleProvider.modelSupportsImages(
                "anthropic/claude-sonnet-5", providerID: "openrouter"))
        #expect(!OpenAICompatibleProvider.modelSupportsImages("qwen3:8b", providerID: "ollama"))
    }

    @Test("passes images to Codex with -i right after exec")
    func codexImages() {
        let arguments = CodexProvider.adding(
            images: ["/tmp/a.png", "/tmp/b.jpg"], to: ["exec", "--json", "-"])
        #expect(arguments == ["exec", "-i", "/tmp/a.png,/tmp/b.jpg", "--json", "-"])
        #expect(CodexProvider.adding(images: [], to: ["exec", "-"]) == ["exec", "-"])

        let written = CodexProvider.writeImages(
            of: ChatRequest(systemPrompt: "", turns: [turn]))
        let paths = written?.paths ?? []
        #expect(paths.count == 1)
        #expect(paths.first.map { FileManager.default.contents(atPath: $0) } == pixel)
        if let folder = written?.folder { try? FileManager.default.removeItem(at: folder) }
        #expect(CodexProvider.writeImages(of: ChatRequest(systemPrompt: "", turns: [])) == nil)
    }

    @Test("gives flattened prompts the attached documents of the new message")
    func flattened() {
        let prompt = PromptFlattener.prompt(
            for: [.init(role: .user, text: "Hi"), .init(role: .assistant, text: "Hello"), turn],
            budget: 1_000)
        #expect(prompt.contains("Pack socks"))
        #expect(prompt.contains("not visible to this brain"))
        #expect(
            !PromptFlattener.prompt(for: [turn], budget: 1_000, imagesVisible: true)
                .contains("not visible"))
    }

    @Test("masks attached documents for remote brains but keeps images, and prefers seeing brains")
    func assistant() async throws {
        let local = FakeProvider(
            info: ProviderInfo(id: "local", name: "Local", kind: .local), reply: [.text("?")])
        let remote = FakeProvider(
            info: ProviderInfo(id: "remote", name: "Remote", kind: .apiKey, supportsImages: true),
            reply: [.text("A shot.")])
        let assistant = Assistant()
        let document = ChatAttachment(name: "c.txt", content: .file(text: "Mail ayse@example.com"))
        var events: [AssistantEvent] = []
        for try await event in await assistant.reply(
            to: "Look", attachments: [image, document],
            configuration: Assistant.Configuration(
                providers: [local, remote], toolbox: Toolbox(), policy: RoutingPolicy(),
                masksPersonalData: true, systemPrompt: "s"),
            consent: { _, _, _ in .allowOnce }, confirm: { _ in true })
        {
            events.append(event)
        }
        #expect(events.first == .brainSelected(remote.info, .imageAttached))
        #expect(local.seen.value.isEmpty)
        let sent = try #require(remote.seen.value.first?.turns.last)
        #expect(sent.images.first?.data == pixel)
        #expect(!sent.contextText.contains("ayse@example.com"))
        #expect(await assistant.history.first?.attachments.count == 2)
    }
}
