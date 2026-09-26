import Foundation
import MomoKit

/// The shape of a picture to draw.
public enum ImageAspect: String, Sendable, CaseIterable, Codable {
    case square
    case landscape
    case portrait

    /// Reads what a model wrote: the names above, or common synonyms and ratios such as
    /// "wide", "tall" and "16:9". Unknown values give `nil`.
    public init?(loose value: String) {
        let text = value.lowercased().trimmingCharacters(in: .whitespaces)
        switch text {
        case "square", "1:1", "1x1", "": self = .square
        case "landscape", "wide", "horizontal", "16:9", "3:2", "4:3", "21:9", "1536x1024":
            self = .landscape
        case "portrait", "tall", "vertical", "9:16", "2:3", "3:4", "1024x1536":
            self = .portrait
        default:
            guard let (width, height) = Self.dimensions(text) else { return nil }
            self = width == height ? .square : width > height ? .landscape : .portrait
        }
    }

    private static func dimensions(_ text: String) -> (Double, Double)? {
        let parts = text.split(whereSeparator: { $0 == "x" || $0 == ":" || $0 == "×" })
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
            width > 0, height > 0
        else { return nil }
        return (width, height)
    }
}

/// What to draw.
public struct ImageRequest: Sendable, Equatable {
    /// What the picture shows, in any language.
    public var prompt: String
    public var aspect: ImageAspect
    /// A style hint such as "watercolor" or "sketch".
    public var style: String?
    /// How many pictures, 1 to 4.
    public var count: Int
    /// An existing image to change, for editing.
    public var source: URL?

    public static let maximumCount = 4

    public init(
        prompt: String, aspect: ImageAspect = .square, style: String? = nil, count: Int = 1,
        source: URL? = nil
    ) {
        self.prompt = prompt
        self.aspect = aspect
        let style = style?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.style = style?.isEmpty == true ? nil : style
        self.count = min(max(count, 1), Self.maximumCount)
        self.source = source
    }

    /// The prompt with the style hint, for services that take one text.
    public var fullPrompt: String {
        guard let style else { return prompt }
        return "\(prompt)\n\nStyle: \(style)"
    }
}

/// A picture a backend made.
public struct GeneratedImage: Sendable, Equatable {
    public var data: Data
    /// The file extension for the data: png, jpg or webp.
    public var fileExtension: String

    public init(data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension
    }

    /// The file extension for a MIME type such as "image/jpeg".
    public static func fileExtension(mimeType: String?) -> String {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/jpg": "jpg"
        case "image/webp": "webp"
        default: "png"
        }
    }
}

/// The services Momo can draw with.
public enum ImageBackendID: String, Sendable, CaseIterable, Codable {
    case applePlayground = "apple"
    case openAI = "openai"
    case gemini
    case codex

    /// The order Momo tries them in when the user has no preference: on the Mac and free
    /// first, then the user's API keys, then their ChatGPT plan (the slowest).
    public static let priority: [ImageBackendID] = [.applePlayground, .openAI, .gemini, .codex]
}

/// Something that draws pictures.
public protocol ImageBackend: Sendable {
    var id: ImageBackendID { get }
    /// A short name for messages and the privacy log, such as "OpenAI Images".
    var name: String { get }
    /// Whether the prompt leaves the Mac.
    var isRemote: Bool { get }
    /// Whether the backend can change an existing image.
    var supportsEditing: Bool { get }
    func availability() async -> ProviderAvailability
    func generate(_ request: ImageRequest) async throws -> [GeneratedImage]
}

/// Which service draws, and the models of the services that have several.
public struct ImageSettings: Codable, Sendable, Equatable {
    /// The service to try first; `nil` picks automatically.
    public var preferred: ImageBackendID?
    public var openAIModel: String
    public var geminiModel: String

    public init() {
        preferred = nil
        openAIModel = OpenAIImageBackend.defaultModel
        geminiModel = GeminiImageBackend.defaultModel
    }

    public init(from decoder: any Decoder) throws {
        let defaults = ImageSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        preferred =
            (try? container.decodeIfPresent(ImageBackendID.self, forKey: .preferred))
            ?? nil
        openAIModel = value(.openAIModel, defaults.openAIModel)
        geminiModel = value(.geminiModel, defaults.geminiModel)
        if openAIModel.isEmpty { openAIModel = defaults.openAIModel }
        if geminiModel.isEmpty { geminiModel = defaults.geminiModel }
    }
}

/// Decides which backends to try, in order.
public enum ImageBackendSelector {
    /// The backends to try: the preferred one first, then the rest by
    /// ``ImageBackendID/priority``. Remote backends are left out in local-only mode, and
    /// backends that can't edit when `editing`.
    public static func order(
        _ backends: [any ImageBackend], preferred: ImageBackendID?, localOnly: Bool,
        editing: Bool = false
    ) -> [any ImageBackend] {
        let rank = { (backend: any ImageBackend) -> Int in
            if backend.id == preferred { return -1 }
            return ImageBackendID.priority.firstIndex(of: backend.id) ?? Int.max
        }
        return
            backends
            .filter { !(localOnly && $0.isRemote) && (!editing || $0.supportsEditing) }
            .enumerated()
            .sorted { lhs, rhs in
                (rank(lhs.element), lhs.offset) < (rank(rhs.element), rhs.offset)
            }
            .map(\.element)
    }

    /// The first backend that is ready, or `nil`.
    public static func firstReady(
        _ backends: [any ImageBackend], preferred: ImageBackendID?, localOnly: Bool
    ) async -> (any ImageBackend)? {
        for backend in order(backends, preferred: preferred, localOnly: localOnly)
        where await backend.availability().isReady {
            return backend
        }
        return nil
    }
}

/// What ``ImageGenerator`` made.
public struct ImageGenerationResult: Sendable, Equatable {
    /// The backend that drew the pictures.
    public var backendName: String
    public var backendID: ImageBackendID
    /// Where the pictures were saved.
    public var files: [URL]
}

/// Draws pictures with the best available backend and saves them.
public struct ImageGenerator: Sendable {
    public var backends: [any ImageBackend]
    public var preferred: ImageBackendID?
    public var localOnly: Bool
    /// Pictures are saved in a folder per day under this folder.
    public var folder: URL
    /// Called before a prompt leaves the Mac, with the service's name and the characters
    /// sent, for the privacy log.
    public var recordRemoteRequest: @Sendable (_ service: String, _ characters: Int) async -> Void
    var now: @Sendable () -> Date = { Date() }

    public init(
        backends: [any ImageBackend], preferred: ImageBackendID?, localOnly: Bool, folder: URL,
        recordRemoteRequest: @escaping @Sendable (String, Int) async -> Void = { _, _ in }
    ) {
        self.backends = backends
        self.preferred = preferred
        self.localOnly = localOnly
        self.folder = folder
        self.recordRemoteRequest = recordRemoteRequest
    }

    /// Draws with the first ready backend, falling back to the next one when it fails.
    /// Throws a ``ToolError`` written for the model when nothing can draw.
    public func generate(_ request: ImageRequest) async throws -> ImageGenerationResult {
        let editing = request.source != nil
        let candidates = ImageBackendSelector.order(
            backends, preferred: preferred, localOnly: localOnly, editing: editing)
        var unavailable: [String] = []
        var failures: [String] = []
        for backend in candidates {
            try Task.checkCancellation()
            let availability = await backend.availability()
            guard availability.isReady else {
                if case .unavailable(let reason) = availability {
                    unavailable.append("\(backend.name): \(reason)")
                }
                continue
            }
            do {
                if backend.isRemote {
                    await recordRemoteRequest(backend.name, request.fullPrompt.count)
                }
                let images = try await backend.generate(request)
                guard !images.isEmpty else {
                    failures.append("\(backend.name): it returned no image.")
                    continue
                }
                let files = try save(images, prompt: request.prompt)
                return ImageGenerationResult(
                    backendName: backend.name, backendID: backend.id, files: files)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(backend.name): \(error.localizedDescription)")
            }
        }
        throw ToolError(
            Self.explanation(
                failures: failures, unavailable: unavailable, localOnly: localOnly,
                editing: editing))
    }

    /// Why nothing could draw, and what to tell the user.
    static func explanation(
        failures: [String], unavailable: [String], localOnly: Bool, editing: Bool
    ) -> String {
        if !failures.isEmpty {
            return "Drawing failed. "
                + failures.joined(separator: " ")
                + " Tell the user briefly what went wrong; if the prompt was refused, suggest "
                + "rephrasing it."
        }
        let details = unavailable.isEmpty ? "" : " (" + unavailable.joined(separator: " ") + ")"
        let task = editing ? "Editing images" : "Drawing"
        if localOnly {
            return "\(task) is not available: local-only mode is on, so only Apple Image "
                + "Playground may draw, and it isn't available on this Mac\(details). Tell the "
                + "user they can turn on Apple Intelligence in System Settings (macOS 15.4 or "
                + "later), or turn off \"Keep everything on this Mac\" in Momo's Privacy "
                + "settings to draw with OpenAI, Gemini or ChatGPT. Don't try to draw another way."
        }
        return "\(task) is not set up yet\(details). Tell the user, in a friendly way, that "
            + "they can enable it by turning on Apple Intelligence in System Settings (free "
            + "and on this Mac, macOS 15.4 or later), by adding an OpenAI or Gemini API key "
            + "in Momo's Settings → AI, or by connecting ChatGPT in Settings → AI. Don't try "
            + "to draw another way."
    }

    /// Writes the pictures to `<folder>/<day>/<name>.<ext>` and returns their locations.
    func save(_ images: [GeneratedImage], prompt: String) throws -> [URL] {
        let date = now()
        let day = folder.appendingPathComponent(Self.dayName(date), isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let base = Self.fileBaseName(for: prompt, date: date)
        return try images.enumerated().map { index, image in
            let suffix = images.count > 1 ? "-\(index + 1)" : ""
            let url = Self.uniqueURL(
                for: "\(base)\(suffix).\(image.fileExtension)", in: day)
            try image.data.write(to: url, options: .atomic)
            return url
        }
    }

    /// A readable, file-safe name from the first words of the prompt and the time:
    /// "a-cat-in-a-hat-143005".
    static func fileBaseName(for prompt: String, date: Date) -> String {
        let words =
            prompt.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var slug = ""
        for word in words {
            let next = slug.isEmpty ? word : slug + "-" + word
            if next.count > 40 { break }
            slug = next
        }
        if slug.isEmpty { slug = String(words.first?.prefix(40) ?? "image") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        return "\(slug)-\(formatter.string(from: date))"
    }

    static func dayName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func uniqueURL(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
