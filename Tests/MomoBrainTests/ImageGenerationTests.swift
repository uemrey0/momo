import Foundation
import MomoKit
import Testing

@testable import MomoBrain

/// A backend with canned behaviour, recording what it was asked.
private final class FakeBackend: ImageBackend, @unchecked Sendable {
    let id: ImageBackendID
    let name: String
    let isRemote: Bool
    let supportsEditing: Bool
    let ready: Bool
    let failure: String?
    private let lock = NSLock()
    private var _requests: [ImageRequest] = []

    init(
        _ id: ImageBackendID, remote: Bool = true, ready: Bool = true, failure: String? = nil,
        editing: Bool = true
    ) {
        self.id = id
        self.name = id.rawValue
        self.isRemote = remote
        self.ready = ready
        self.failure = failure
        self.supportsEditing = editing
    }

    var requests: [ImageRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func availability() async -> ProviderAvailability {
        ready ? .ready : .unavailable("\(name) is off.")
    }

    func generate(_ request: ImageRequest) async throws -> [GeneratedImage] {
        lock.withLock { _requests.append(request) }
        if let failure { throw ProviderError(failure) }
        return (0..<request.count).map { _ in
            GeneratedImage(data: Data("png-\(id.rawValue)".utf8), fileExtension: "png")
        }
    }
}

/// Collects the privacy log entries a generator reports.
private actor OutboundLog {
    var entries: [String] = []
    func add(_ service: String) { entries.append(service) }
}

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("momo-images-\(UUID().uuidString)", isDirectory: true)
}

private let tinyPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

@Suite("Image requests")
struct ImageRequestTests {
    @Test("aspects accept names, synonyms and ratios")
    func aspects() {
        #expect(ImageAspect(loose: "Landscape") == .landscape)
        #expect(ImageAspect(loose: "wide") == .landscape)
        #expect(ImageAspect(loose: "9:16") == .portrait)
        #expect(ImageAspect(loose: "1792x1024") == .landscape)
        #expect(ImageAspect(loose: "512x512") == .square)
        #expect(ImageAspect(loose: "") == .square)
        #expect(ImageAspect(loose: "banana") == nil)
    }

    @Test("counts stay between one and four, and empty styles are dropped")
    func counts() {
        #expect(ImageRequest(prompt: "a", count: 9).count == 4)
        #expect(ImageRequest(prompt: "a", count: 0).count == 1)
        #expect(ImageRequest(prompt: "a", style: "  ").style == nil)
        #expect(
            ImageRequest(prompt: "a cat", style: "sketch").fullPrompt == "a cat\n\nStyle: sketch")
    }

    @Test("settings decode tolerantly and fill in empty models")
    func settings() throws {
        let decoded = try JSONDecoder().decode(
            ImageSettings.self,
            from: Data(#"{"preferred": "gemini", "openAIModel": "", "extra": 1}"#.utf8))
        #expect(decoded.preferred == .gemini)
        #expect(decoded.openAIModel == OpenAIImageBackend.defaultModel)
        let unknown = try JSONDecoder().decode(
            ImageSettings.self, from: Data(#"{"preferred": "dalle"}"#.utf8))
        #expect(unknown.preferred == nil)
    }
}

@Suite("Image backend selection")
struct ImageBackendSelectionTests {
    let backends: [any ImageBackend] = [
        FakeBackend(.codex), FakeBackend(.gemini), FakeBackend(.openAI),
        FakeBackend(.applePlayground, remote: false),
    ]

    @Test("without a preference, on-device comes first, then keys, then the plan")
    func defaultOrder() {
        let order = ImageBackendSelector.order(backends, preferred: nil, localOnly: false)
        #expect(order.map(\.id) == [.applePlayground, .openAI, .gemini, .codex])
    }

    @Test("the preferred backend is tried first")
    func preference() {
        let order = ImageBackendSelector.order(backends, preferred: .codex, localOnly: false)
        #expect(order.map(\.id) == [.codex, .applePlayground, .openAI, .gemini])
    }

    @Test("local-only mode leaves out every remote backend, even the preferred one")
    func localOnly() {
        let order = ImageBackendSelector.order(backends, preferred: .openAI, localOnly: true)
        #expect(order.map(\.id) == [.applePlayground])
    }

    @Test("editing leaves out backends that can't edit")
    func editing() {
        let backends: [any ImageBackend] = [
            FakeBackend(.applePlayground, remote: false, editing: false), FakeBackend(.gemini),
        ]
        let order = ImageBackendSelector.order(
            backends, preferred: nil, localOnly: false, editing: true)
        #expect(order.map(\.id) == [.gemini])
    }

    @Test("the first ready backend is skipped over unavailable ones")
    func firstReady() async {
        let backends: [any ImageBackend] = [
            FakeBackend(.applePlayground, remote: false, ready: false), FakeBackend(.gemini),
        ]
        let ready = await ImageBackendSelector.firstReady(
            backends, preferred: nil, localOnly: false)
        #expect(ready?.id == .gemini)
        let local = await ImageBackendSelector.firstReady(
            backends, preferred: nil, localOnly: true)
        #expect(local == nil)
    }
}

@Suite("Image generator")
struct ImageGeneratorTests {
    @Test("falls back to the next backend when one fails, and logs remote requests")
    func fallback() async throws {
        let apple = FakeBackend(.applePlayground, remote: false, failure: "Unsupported language")
        let openAI = FakeBackend(.openAI)
        let log = OutboundLog()
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let generator = ImageGenerator(
            backends: [openAI, apple], preferred: nil, localOnly: false, folder: folder,
            recordRemoteRequest: { service, _ in await log.add(service) })
        let result = try await generator.generate(ImageRequest(prompt: "A red fox", count: 2))
        #expect(result.backendID == .openAI)
        #expect(result.files.count == 2)
        #expect(apple.requests.count == 1)
        #expect(await log.entries == ["openai"])
        for file in result.files {
            #expect(file.path.hasPrefix(folder.path))
            #expect(try Data(contentsOf: file) == Data("png-openai".utf8))
        }
    }

    @Test("on-device drawing is not logged as leaving the Mac")
    func localNotLogged() async throws {
        let log = OutboundLog()
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let generator = ImageGenerator(
            backends: [FakeBackend(.applePlayground, remote: false)], preferred: nil,
            localOnly: true, folder: folder,
            recordRemoteRequest: { service, _ in await log.add(service) })
        _ = try await generator.generate(ImageRequest(prompt: "A boat"))
        #expect(await log.entries.isEmpty)
    }

    @Test("explains how to enable drawing when nothing is available")
    func nothingAvailable() async {
        let generator = ImageGenerator(
            backends: [
                FakeBackend(.applePlayground, remote: false, ready: false),
                FakeBackend(.openAI, ready: false),
            ], preferred: nil, localOnly: false, folder: temporaryFolder())
        await #expect {
            try await generator.generate(ImageRequest(prompt: "A boat"))
        } throws: { error in
            let message = (error as? ToolError)?.message ?? ""
            return message.contains("not set up yet") && message.contains("Apple Intelligence")
                && message.contains("OpenAI or Gemini API key") && message.contains("ChatGPT")
        }
    }

    @Test("local-only mode never touches remote backends and says why")
    func localOnlyExplains() async {
        let openAI = FakeBackend(.openAI)
        let generator = ImageGenerator(
            backends: [FakeBackend(.applePlayground, remote: false, ready: false), openAI],
            preferred: .openAI, localOnly: true, folder: temporaryFolder())
        await #expect {
            try await generator.generate(ImageRequest(prompt: "A boat"))
        } throws: { error in
            ((error as? ToolError)?.message ?? "").contains("local-only mode is on")
        }
        #expect(openAI.requests.isEmpty)
    }

    @Test("reports failures when every ready backend failed")
    func failures() async {
        let generator = ImageGenerator(
            backends: [FakeBackend(.gemini, failure: "Blocked by safety")], preferred: nil,
            localOnly: false, folder: temporaryFolder())
        await #expect {
            try await generator.generate(ImageRequest(prompt: "A boat"))
        } throws: { error in
            let message = (error as? ToolError)?.message ?? ""
            return message.hasPrefix("Drawing failed.") && message.contains("Blocked by safety")
        }
    }

    @Test("file names come from the prompt and the time, in a folder per day")
    func fileNames() throws {
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 9, 26)
        (components.hour, components.minute, components.second) = (14, 30, 5)
        let date = try #require(Calendar.current.date(from: components))
        #expect(
            ImageGenerator.fileBaseName(for: "A cat, in a HAT!", date: date)
                == "a-cat-in-a-hat-143005")
        #expect(
            ImageGenerator.fileBaseName(for: "Şapkalı kedi", date: date) == "şapkalı-kedi-143005")
        #expect(ImageGenerator.fileBaseName(for: "!!!", date: date) == "image-143005")
        let long = ImageGenerator.fileBaseName(
            for: "one two three four five six seven eight nine ten eleven", date: date)
        #expect(long == "one-two-three-four-five-six-seven-eight-143005")

        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var generator = ImageGenerator(
            backends: [], preferred: nil, localOnly: false, folder: folder)
        generator.now = { date }
        let image = GeneratedImage(data: tinyPNG, fileExtension: "png")
        let first = try generator.save([image, image], prompt: "Sunset")
        #expect(first.map(\.lastPathComponent) == ["sunset-143005-1.png", "sunset-143005-2.png"])
        #expect(first[0].deletingLastPathComponent().lastPathComponent == "2026-09-26")
        let again = try generator.save([image], prompt: "Sunset")
        let repeated = try generator.save([image], prompt: "Sunset")
        #expect(again[0].lastPathComponent == "sunset-143005.png")
        // "-2" is taken by the second picture of the pair.
        #expect(repeated[0].lastPathComponent == "sunset-143005-3.png")
    }
}

@Suite("OpenAI images")
struct OpenAIImageTests {
    @Test("builds a generation request with the model, size and count")
    func request() throws {
        let backend = OpenAIImageBackend(apiKey: "sk-test", model: "gpt-image-x")
        let request = backend.generationRequest(
            ImageRequest(prompt: "A fox", aspect: .portrait, style: "watercolor", count: 3))
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/images/generations")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try JSONValue.parse(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        #expect(body["model"]?.stringValue == "gpt-image-x")
        #expect(body["size"]?.stringValue == "1024x1536")
        #expect(body["n"]?.intValue == 3)
        #expect(body["prompt"]?.stringValue == "A fox\n\nStyle: watercolor")
    }

    @Test("builds a multipart edit request with the image")
    func editRequest() {
        let backend = OpenAIImageBackend(apiKey: "sk-test")
        let request = backend.editRequest(
            ImageRequest(prompt: "Make it blue", aspect: .landscape), source: tinyPNG,
            sourceName: "cat.png")
        #expect(request.url?.path == "/v1/images/edits")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix(
                "multipart/form-data; boundary=") == true)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("name=\"prompt\"\r\n\r\nMake it blue"))
        #expect(body.contains("name=\"size\"\r\n\r\n1536x1024"))
        #expect(body.contains("name=\"image[]\"; filename=\"cat.png\"\r\nContent-Type: image/png"))
    }

    @Test("reads base64 images and their format")
    func parse() throws {
        let json = """
            {"output_format": "jpeg", "data": [{"b64_json": "\(tinyPNG.base64EncodedString())"}]}
            """
        let images = try OpenAIImageBackend.parse(Data(json.utf8))
        #expect(images == [GeneratedImage(data: tinyPNG, fileExtension: "jpg")])
        #expect(throws: ProviderError.self) {
            try OpenAIImageBackend.parse(Data(#"{"data": []}"#.utf8))
        }
    }

    @Test("sends the request and reports API errors")
    func roundTrip() async throws {
        let (session, host) = MockURLProtocol.session(responses: [
            .init(body: #"{"data": [{"b64_json": "\#(tinyPNG.base64EncodedString())"}]}"#),
            .init(status: 401, body: #"{"error": {"message": "Incorrect API key"}}"#),
        ])
        let backend = OpenAIImageBackend(
            apiKey: "k", baseURL: URL(string: "https://\(host)/v1"), session: session)
        let images = try await backend.generate(ImageRequest(prompt: "A fox"))
        #expect(images.first?.data == tinyPNG)
        #expect(images.first?.fileExtension == "png")
        let body = try JSONValue.parse(MockURLProtocol.requestBodies(host: host)[0])
        #expect(body["model"]?.stringValue == OpenAIImageBackend.defaultModel)
        await #expect {
            try await backend.generate(ImageRequest(prompt: "A fox"))
        } throws: { error in
            (error as? ProviderError)?.message.contains("rejected") == true
        }
    }

    @Test("is unavailable without a key")
    func noKey() async {
        #expect(await OpenAIImageBackend(apiKey: "").availability() != .ready)
        #expect(await OpenAIImageBackend(apiKey: "k").availability() == .ready)
    }
}

@Suite("Gemini images")
struct GeminiImageTests {
    @Test("builds a generateContent request with the aspect ratio and the image to edit")
    func request() throws {
        let backend = GeminiImageBackend(apiKey: "g-key")
        let request = backend.request(
            ImageRequest(prompt: "A fox", aspect: .landscape),
            source: (tinyPNG, "image/png"))
        #expect(
            request.url?.absoluteString
                == "https://generativelanguage.googleapis.com/v1/models/\(GeminiImageBackend.defaultModel):generateContent"
        )
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "g-key")
        let body = try JSONValue.parse(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        let config = body["generationConfig"]
        #expect(config?["responseModalities"] == ["TEXT", "IMAGE"])
        #expect(config?["responseFormat"]?["image"]?["aspectRatio"]?.stringValue == "16:9")
        let parts = body["contents"]?.arrayValue?.first?["parts"]?.arrayValue ?? []
        #expect(parts.first?["text"]?.stringValue == "A fox")
        #expect(parts.last?["inline_data"]?["data"]?.stringValue == tinyPNG.base64EncodedString())
    }

    @Test("reads inline images in both spellings")
    func parse() throws {
        let base64 = tinyPNG.base64EncodedString()
        let camel = """
            {"candidates": [{"content": {"parts": [{"text": "Here"}, \
            {"inlineData": {"mimeType": "image/jpeg", "data": "\(base64)"}}]}}]}
            """
        #expect(
            try GeminiImageBackend.parse(Data(camel.utf8))
                == [GeneratedImage(data: tinyPNG, fileExtension: "jpg")])
        let snake = """
            {"candidates": [{"content": {"parts": [\
            {"inline_data": {"mime_type": "image/png", "data": "\(base64)"}}]}}]}
            """
        #expect(try GeminiImageBackend.parse(Data(snake.utf8)).first?.fileExtension == "png")
    }

    @Test("explains an answer without an image")
    func noImage() {
        let json = """
            {"candidates": [{"finishReason": "IMAGE_SAFETY", "content": {"parts": []}}]}
            """
        #expect {
            try GeminiImageBackend.parse(Data(json.utf8))
        } throws: { error in
            (error as? ProviderError)?.message.contains("IMAGE_SAFETY") == true
        }
    }

    @Test("asks once per picture")
    func several() async throws {
        let reply = """
            {"candidates": [{"content": {"parts": [\
            {"inlineData": {"mimeType": "image/png", "data": "\(tinyPNG.base64EncodedString())"}}]}}]}
            """
        let (session, host) = MockURLProtocol.session(responses: [
            .init(body: reply), .init(body: reply),
        ])
        let backend = GeminiImageBackend(
            apiKey: "k", baseURL: URL(string: "https://\(host)/v1"), session: session)
        let images = try await backend.generate(ImageRequest(prompt: "A fox", count: 2))
        #expect(images.count == 2)
        #expect(MockURLProtocol.requestBodies(host: host).count == 2)
    }
}

@Suite("Codex images")
struct CodexImageTests {
    /// A Codex stand-in that saves a picture in the fake home folder, like Codex does.
    private func backend(
        home: URL, thread: String = "thread-1", draws: Bool = true,
        arguments: LockedArguments = LockedArguments()
    ) -> CodexImageBackend {
        CodexImageBackend(
            model: nil, workingDirectory: home, home: home,
            locate: { URL(fileURLWithPath: "/usr/bin/true") }, isSignedIn: { true },
            run: { _, args, input, _ in
                arguments.set(args, input)
                return AsyncThrowingStream { continuation in
                    continuation.yield(#"{"type":"thread.started","thread_id":"\#(thread)"}"#)
                    if draws {
                        let folder = home.appendingPathComponent("generated_images/\(thread)")
                        try? FileManager.default.createDirectory(
                            at: folder, withIntermediateDirectories: true)
                        try? tinyPNG.write(to: folder.appendingPathComponent("exec-1.png"))
                    }
                    continuation.yield(
                        #"{"type":"item.completed","item":{"type":"agent_message","text":"Here it is."}}"#
                    )
                    continuation.finish()
                }
            })
    }

    @Test("collects the picture Codex saved for its thread")
    func collects() async throws {
        let home = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let arguments = LockedArguments()
        let source = home.appendingPathComponent("in.png")
        let images = try await backend(home: home, arguments: arguments).generate(
            ImageRequest(prompt: "A fox", aspect: .landscape, source: source))
        #expect(images == [GeneratedImage(data: tinyPNG, fileExtension: "png")])
        let (args, input) = arguments.value
        #expect(args.starts(with: ["exec", "--json"]))
        #expect(args.contains("image_generation"))
        #expect(args.contains(source.path))
        #expect(args.last == "-")
        #expect(input.contains("A fox"))
        #expect(input.contains("landscape"))
        #expect(input.contains("Edit the attached image"))
    }

    @Test("says so when Codex made no picture")
    func nothingDrawn() async {
        let home = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        await #expect {
            try await backend(home: home, draws: false).generate(ImageRequest(prompt: "A fox"))
        } throws: { error in
            (error as? ProviderError)?.message.contains("Here it is.") == true
        }
    }
}

/// Arguments a fake runner received, readable from the test.
private final class LockedArguments: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ([String], String) = ([], "")

    func set(_ arguments: [String], _ input: String) {
        lock.lock()
        stored = (arguments, input)
        lock.unlock()
    }

    var value: ([String], String) {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite("Image tools")
struct ImageToolTests {
    private func toolbox(_ folder: URL, backend: FakeBackend = FakeBackend(.openAI)) -> Toolbox {
        Toolbox(
            ImageTools.all(
                generator: ImageGenerator(
                    backends: [backend], preferred: nil, localOnly: false, folder: folder),
                activityLabel: "Drawing"))
    }

    @Test("generate_image returns the files and tells the model where they are")
    func generate() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = FakeBackend(.openAI)
        let result = await toolbox(folder, backend: backend).execute(
            ToolCall(
                id: "1", name: "generate_image",
                arguments: #"{"prompt": "A fox", "aspect": "wide", "count": 7, "style": "sketch"}"#
            ))
        #expect(!result.isError)
        #expect(result.files.count == 4)
        #expect(result.output.contains("Drew 4 pictures with openai"))
        for file in result.files { #expect(result.output.contains(file.path)) }
        let request = try #require(backend.requests.first)
        #expect(request.aspect == .landscape)
        #expect(request.style == "sketch")
    }

    @Test("generate_image needs a prompt")
    func missingPrompt() async {
        let result = await toolbox(temporaryFolder()).execute(
            ToolCall(id: "1", name: "generate_image", arguments: #"{"prompt": "  "}"#))
        #expect(result.isError)
        #expect(result.output.contains("prompt"))
    }

    @Test("edit_image checks the file and passes it on")
    func edit() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("cat.png")
        try tinyPNG.write(to: source)
        let backend = FakeBackend(.gemini)
        let tools = toolbox(folder, backend: backend)

        let missing = await tools.execute(
            ToolCall(
                id: "1", name: "edit_image",
                arguments: #"{"path": "/nope/cat.png", "instructions": "Make it blue"}"#))
        #expect(missing.isError)
        #expect(missing.output.contains("no file"))

        let result = await tools.execute(
            ToolCall(
                id: "2", name: "edit_image",
                arguments: JSONValue.object([
                    "path": .string(source.absoluteString), "instructions": "Make it blue",
                ]).jsonString))
        #expect(!result.isError)
        #expect(result.output.contains("edited picture"))
        #expect(backend.requests.first?.source?.path == source.path)
        #expect(backend.requests.first?.prompt == "Make it blue")
    }

    @Test("the tools carry the activity label")
    func labels() {
        let definitions = toolbox(temporaryFolder()).definitions
        #expect(definitions.map(\.name) == ["generate_image", "edit_image"])
        #expect(definitions.allSatisfy { $0.activityLabel == "Drawing" })
    }

    @Test("Image Playground styles follow the hint")
    func playgroundStyles() {
        #expect(ApplePlaygroundBackend.styleName(for: "pencil sketch") == "sketch")
        #expect(ApplePlaygroundBackend.styleName(for: "3D cartoon") == "animation")
        #expect(ApplePlaygroundBackend.styleName(for: "Watercolor") == "illustration")
        #expect(ApplePlaygroundBackend.styleName(for: "photo") == nil)
        #expect(ApplePlaygroundBackend.styleName(for: nil) == nil)
    }

    @Test("the system prompt asks every brain to draw with the tool when it is offered")
    func systemPrompt() {
        let drawing = SystemPrompt.make(memories: [], languageName: "English", canDraw: true)
        let plain = SystemPrompt.make(memories: [], languageName: "English")
        #expect(drawing.contains("generate_image"))
        #expect(!plain.contains("generate_image"))
    }
}
