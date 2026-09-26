import Foundation
import MomoKit

/// Draws with the OpenAI Images API and the user's OpenAI key.
public struct OpenAIImageBackend: ImageBackend {
    public static let defaultModel = "gpt-image-2.5-flare"

    public let id = ImageBackendID.openAI
    public let name = "OpenAI Images"
    public let isRemote = true
    public let supportsEditing = true
    let apiKey: String?
    let model: String
    let baseURL: URL
    let session: URLSession

    public init(
        apiKey: String?, model: String = OpenAIImageBackend.defaultModel,
        baseURL: URL? = nil, session: URLSession = .shared
    ) {
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.model = model.isEmpty ? Self.defaultModel : model
        self.baseURL = baseURL ?? URL(literal: "https://api.openai.com/v1")
        self.session = session
    }

    public func availability() async -> ProviderAvailability {
        apiKey == nil ? .unavailable("Add an OpenAI API key in Settings → AI.") : .ready
    }

    /// The size the API takes for an aspect.
    static func size(_ aspect: ImageAspect) -> String {
        switch aspect {
        case .square: "1024x1024"
        case .landscape: "1536x1024"
        case .portrait: "1024x1536"
        }
    }

    /// The request for new pictures (`images/generations`).
    func generationRequest(_ request: ImageRequest) -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("images/generations"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey ?? "")", forHTTPHeaderField: "Authorization")
        let body: JSONValue = [
            "model": .string(model), "prompt": .string(request.fullPrompt),
            "n": .number(Double(request.count)), "size": .string(Self.size(request.aspect)),
        ]
        urlRequest.httpBody = Data(body.jsonString.utf8)
        return urlRequest
    }

    /// The request that changes an existing picture (`images/edits`, multipart).
    func editRequest(_ request: ImageRequest, source: Data, sourceName: String) -> URLRequest {
        let boundary = "momo-\(UUID().uuidString)"
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("images/edits"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey ?? "")", forHTTPHeaderField: "Authorization")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(
                Data(
                    "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
                        .utf8))
        }
        field("model", model)
        field("prompt", request.fullPrompt)
        field("n", String(request.count))
        field("size", Self.size(request.aspect))
        let ext = (sourceName as NSString).pathExtension.lowercased()
        let mime = ext == "png" ? "image/png" : ext == "webp" ? "image/webp" : "image/jpeg"
        body.append(
            Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"\(sourceName)\"\r\nContent-Type: \(mime)\r\n\r\n"
                    .utf8))
        body.append(source)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        urlRequest.httpBody = body
        return urlRequest
    }

    /// Reads `data[].b64_json` from a response.
    static func parse(_ data: Data) throws -> [GeneratedImage] {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let format = json["output_format"]?.stringValue
        let images = (json["data"]?.arrayValue ?? []).compactMap { item -> GeneratedImage? in
            guard let base64 = item["b64_json"]?.stringValue,
                let bytes = Data(base64Encoded: base64)
            else { return nil }
            return GeneratedImage(
                data: bytes, fileExtension: format.map { $0 == "jpeg" ? "jpg" : $0 } ?? "png")
        }
        guard !images.isEmpty else { throw ProviderError("OpenAI returned no image.") }
        return images
    }

    public func generate(_ request: ImageRequest) async throws -> [GeneratedImage] {
        guard apiKey != nil else { throw ProviderError("There is no OpenAI API key.") }
        let urlRequest: URLRequest
        if let source = request.source {
            urlRequest = editRequest(
                request, source: try Data(contentsOf: source), sourceName: source.lastPathComponent)
        } else {
            urlRequest = generationRequest(request)
        }
        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTP.error(status: status, body: data) }
        return try Self.parse(data)
    }
}

/// Draws with a Gemini image model ("Nano Banana") and the user's Gemini API key.
public struct GeminiImageBackend: ImageBackend {
    public static let defaultModel = "gemini-3.1-flash-image"

    public let id = ImageBackendID.gemini
    public let name = "Gemini Images"
    public let isRemote = true
    public let supportsEditing = true
    let apiKey: String?
    let model: String
    let baseURL: URL
    let session: URLSession

    public init(
        apiKey: String?, model: String = GeminiImageBackend.defaultModel,
        baseURL: URL? = nil, session: URLSession = .shared
    ) {
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.model = model.isEmpty ? Self.defaultModel : model
        self.baseURL = baseURL ?? URL(literal: "https://generativelanguage.googleapis.com/v1")
        self.session = session
    }

    public func availability() async -> ProviderAvailability {
        apiKey == nil ? .unavailable("Add a Gemini API key in Settings → AI.") : .ready
    }

    static func aspectRatio(_ aspect: ImageAspect) -> String {
        switch aspect {
        case .square: "1:1"
        case .landscape: "16:9"
        case .portrait: "9:16"
        }
    }

    /// One `generateContent` request, which makes one picture.
    func request(_ request: ImageRequest, source: (data: Data, mimeType: String)?) -> URLRequest {
        var urlRequest = URLRequest(
            url: baseURL.appendingPathComponent("models/\(model):generateContent"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey ?? "", forHTTPHeaderField: "x-goog-api-key")
        var parts: [JSONValue] = [["text": .string(request.fullPrompt)]]
        if let source {
            parts.append([
                "inline_data": [
                    "mime_type": .string(source.mimeType),
                    "data": .string(source.data.base64EncodedString()),
                ]
            ])
        }
        let body: JSONValue = [
            "contents": [["role": "user", "parts": .array(parts)]],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"],
                "responseFormat": [
                    "image": ["aspectRatio": .string(Self.aspectRatio(request.aspect))]
                ],
            ],
        ]
        urlRequest.httpBody = Data(body.jsonString.utf8)
        return urlRequest
    }

    /// Reads the inline image parts of a response, in either spelling the API uses.
    static func parse(_ data: Data) throws -> [GeneratedImage] {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let candidate = json["candidates"]?.arrayValue?.first
        let parts = candidate?["content"]?["parts"]?.arrayValue ?? []
        let images = parts.compactMap { part -> GeneratedImage? in
            guard let inline = part["inlineData"] ?? part["inline_data"],
                let base64 = inline["data"]?.stringValue,
                let bytes = Data(base64Encoded: base64)
            else { return nil }
            let mime = (inline["mimeType"] ?? inline["mime_type"])?.stringValue
            return GeneratedImage(
                data: bytes, fileExtension: GeneratedImage.fileExtension(mimeType: mime))
        }
        guard !images.isEmpty else {
            let text = parts.compactMap { $0["text"]?.stringValue }.joined(separator: " ")
            let reason =
                candidate?["finishReason"]?.stringValue
                ?? json["promptFeedback"]?["blockReason"]?.stringValue
            let detail = [reason, text.isEmpty ? nil : text].compactMap { $0 }
                .joined(separator: ": ")
            throw ProviderError(
                "Gemini returned no image" + (detail.isEmpty ? "." : " (\(detail))."))
        }
        return images
    }

    public func generate(_ request: ImageRequest) async throws -> [GeneratedImage] {
        guard apiKey != nil else { throw ProviderError("There is no Gemini API key.") }
        let source = try request.source.map { url -> (data: Data, mimeType: String) in
            let ext = url.pathExtension.lowercased()
            let mime =
                ext == "png"
                ? "image/png"
                : ext == "webp"
                    ? "image/webp"
                    : ext == "heic" ? "image/heic" : "image/jpeg"
            return (try Data(contentsOf: url), mime)
        }
        // Each request makes one picture, so several are asked for side by side.
        return try await withThrowingTaskGroup(of: [GeneratedImage].self) { group in
            for _ in 0..<request.count {
                let urlRequest = self.request(request, source: source)
                group.addTask {
                    let (data, response) = try await session.data(for: urlRequest)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        throw HTTP.error(status: status, body: data)
                    }
                    return try Self.parse(data)
                }
            }
            var images: [GeneratedImage] = []
            for try await batch in group { images += batch }
            return Array(images.prefix(request.count))
        }
    }
}

/// Draws with Codex and the user's ChatGPT plan: `codex exec` is asked to use its image
/// generation tool, and the pictures are collected from `generated_images/<thread>` in
/// Codex's home folder.
public struct CodexImageBackend: ImageBackend {
    /// Runs Codex with arguments and input, streaming its output lines.
    public typealias Runner =
        @Sendable (
            _ executable: URL, _ arguments: [String], _ input: String, _ workingDirectory: URL
        )
        -> AsyncThrowingStream<String, any Error>

    public let id = ImageBackendID.codex
    public let name = "ChatGPT (Codex)"
    public let isRemote = true
    public let supportsEditing = true
    let model: String?
    let workingDirectory: URL
    let home: URL
    let locate: @Sendable () -> URL?
    let isSignedIn: @Sendable () async -> Bool
    let run: Runner

    public init(model: String?, workingDirectory: URL) {
        self.init(
            model: model, workingDirectory: workingDirectory, home: CodexProvider.home,
            locate: { CodexSetup.locate() }, isSignedIn: { await CodexSetup.isSignedIn() },
            run: { executable, arguments, input, folder in
                CommandRunner.lines(
                    executable: executable, arguments: arguments, input: input,
                    workingDirectory: folder)
            })
    }

    init(
        model: String?, workingDirectory: URL, home: URL, locate: @escaping @Sendable () -> URL?,
        isSignedIn: @escaping @Sendable () async -> Bool, run: @escaping Runner
    ) {
        self.model = model?.isEmpty == true ? nil : model
        self.workingDirectory = workingDirectory
        self.home = home
        self.locate = locate
        self.isSignedIn = isSignedIn
        self.run = run
    }

    public func availability() async -> ProviderAvailability {
        guard locate() != nil else { return .unavailable("Connect ChatGPT in Settings → AI.") }
        guard await isSignedIn() else {
            return .unavailable("Sign in with ChatGPT in Settings → AI.")
        }
        return .ready
    }

    func arguments(source: URL?) -> [String] {
        var arguments = [
            "exec", "--json", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
            "--enable", "image_generation",
        ]
        if let source { arguments += ["-i", source.path] }
        if let model { arguments += ["-m", model] }
        arguments.append("-")
        return arguments
    }

    static func prompt(for request: ImageRequest) -> String {
        let count = request.count == 1 ? "one image" : "\(request.count) separate images"
        let shape =
            switch request.aspect {
            case .square: "square (1:1)"
            case .landscape: "landscape (3:2)"
            case .portrait: "portrait (2:3)"
            }
        let task =
            request.source == nil
            ? "Create \(count) with your image generation tool."
            : "Edit the attached image with your image generation tool, making \(count)."
        var lines = [
            task,
            "Do not run commands, write files or search the web; only generate the image.",
            "Shape: \(shape).",
        ]
        if let style = request.style { lines.append("Style: \(style).") }
        lines += [
            "", "Image description:", request.prompt, "",
            "When the image is done, reply with one short sentence.",
        ]
        return lines.joined(separator: "\n")
    }

    public func generate(_ request: ImageRequest) async throws -> [GeneratedImage] {
        guard let executable = locate() else { throw ProviderError("Codex was not found.") }
        var parser = CodexEventParser()
        var reply = ""
        do {
            for try await line in run(
                executable, arguments(source: request.source), Self.prompt(for: request),
                workingDirectory)
            {
                for event in try parser.consume(line) {
                    if case .text(let text) = event { reply += text }
                }
            }
        } catch let failure as CommandRunner.Failure {
            throw ProviderError(parser.lastError ?? CLIPrompt.describe(failure, tool: "Codex"))
        }
        guard let thread = parser.threadID else {
            throw ProviderError(parser.lastError ?? "Codex did not start.")
        }
        var finder = CodexGeneratedImages(home: home)
        let images = try finder.newImages(thread: thread).prefix(request.count).map { url in
            GeneratedImage(
                data: try Data(contentsOf: url),
                fileExtension: url.pathExtension.lowercased() == "jpeg"
                    ? "jpg" : url.pathExtension.lowercased())
        }
        guard !images.isEmpty else {
            let said = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError(
                "Codex made no image" + (said.isEmpty ? "." : ". It said: \(said.prefix(300))"))
        }
        return images
    }
}
