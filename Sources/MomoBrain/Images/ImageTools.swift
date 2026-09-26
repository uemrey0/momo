import Foundation
import MomoKit

/// Builds the image backends from the user's settings and keys.
public enum ImageBackendCatalog {
    /// Every backend Momo knows, configured; each reports its own availability.
    public static func backends(
        settings: ImageSettings, keys: any APIKeyStore, workingDirectory: URL,
        session: URLSession = .shared
    ) -> [any ImageBackend] {
        [
            ApplePlaygroundBackend(),
            OpenAIImageBackend(
                apiKey: keys.key(for: "openai"), model: settings.openAIModel, session: session),
            GeminiImageBackend(
                apiKey: keys.key(for: "gemini-api"), model: settings.geminiModel,
                session: session),
            CodexImageBackend(model: nil, workingDirectory: workingDirectory),
        ]
    }
}

/// The `generate_image` and `edit_image` tools, which work with every brain.
public enum ImageTools {
    /// - Parameter activityLabel: The localized label shown while a picture is drawn.
    public static func all(
        generator: ImageGenerator, activityLabel: String? = nil,
        editActivityLabel: String? = nil
    ) -> [any MomoTool] {
        [
            generateImage(generator, label: activityLabel),
            editImage(generator, label: editActivityLabel ?? activityLabel),
        ]
    }

    static let styleDescription =
        "Optional style hint, such as illustration, sketch, animation (3D cartoon), watercolor or photo."

    static func generateImage(_ generator: ImageGenerator, label: String?) -> any MomoTool {
        ClosureTool.makingFiles(
            ToolDefinition(
                name: "generate_image",
                description:
                    "Draw pictures: illustrations, drawings, photos, icons, wallpapers. Use this whenever the user asks you to draw, paint, sketch or create an image, whichever brain you are. The images are shown to the user in the chat and saved on their Mac.",
                parameters: JSONSchema.object(
                    [
                        "prompt": JSONSchema.string(
                            "A detailed description of the picture: subject, setting, composition, colors, mood. English or the user's language."
                        ),
                        "aspect": JSONSchema.oneOf(
                            ImageAspect.allCases.map(\.rawValue),
                            description: "The shape of the picture. Defaults to square."),
                        "style": JSONSchema.string(styleDescription),
                        "count": JSONSchema.integer(
                            "How many pictures to make, 1 to 4. Defaults to 1."),
                    ], required: ["prompt"]),
                activityLabel: label),
            summary: { $0["prompt"]?.stringValue ?? "" }
        ) { arguments in
            let request = try imageRequest(from: arguments)
            return reply(for: try await generator.generate(request), editing: false)
        }
    }

    static func editImage(_ generator: ImageGenerator, label: String?) -> any MomoTool {
        ClosureTool.makingFiles(
            ToolDefinition(
                name: "edit_image",
                description:
                    "Change an existing picture on the user's Mac, such as one you drew earlier or one they attached: restyle it, add or remove things, change colors. The result is a new picture shown in the chat; the original stays as it is.",
                parameters: JSONSchema.object(
                    [
                        "path": JSONSchema.string(
                            "The full path of the image to change, for example one generate_image returned."
                        ),
                        "instructions": JSONSchema.string(
                            "What to change, in English or the user's language."),
                        "aspect": JSONSchema.oneOf(
                            ImageAspect.allCases.map(\.rawValue),
                            description: "The shape of the result. Defaults to square."),
                        "style": JSONSchema.string(styleDescription),
                        "count": JSONSchema.integer(
                            "How many versions to make, 1 to 4. Defaults to 1."),
                    ], required: ["path", "instructions"]),
                activityLabel: label),
            summary: { $0["instructions"]?.stringValue ?? "" }
        ) { arguments in
            let request = try editRequest(from: arguments)
            return reply(for: try await generator.generate(request), editing: true)
        }
    }

    /// Reads `generate_image` arguments.
    static func imageRequest(from arguments: JSONValue) throws -> ImageRequest {
        let prompt =
            (arguments["prompt"]?.stringValue ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ToolError("Describe the picture in 'prompt'.")
        }
        return ImageRequest(
            prompt: prompt, aspect: aspect(from: arguments),
            style: arguments["style"]?.stringValue,
            count: arguments["count"]?.intValue ?? 1)
    }

    /// Reads `edit_image` arguments and checks that the image exists.
    static func editRequest(from arguments: JSONValue) throws -> ImageRequest {
        let instructions =
            (arguments["instructions"]?.stringValue ?? arguments["prompt"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else {
            throw ToolError("Say what to change in 'instructions'.")
        }
        let rawPath = (arguments["path"]?.stringValue ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { throw ToolError("Give the image's full path in 'path'.") }
        let path =
            rawPath.hasPrefix("file://")
            ? (URL(string: rawPath)?.path ?? rawPath) : (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        let images: Set<String> = ["png", "jpg", "jpeg", "webp", "heic"]
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("There is no file at \(url.path).")
        }
        guard images.contains(url.pathExtension.lowercased()) else {
            throw ToolError("\(url.lastPathComponent) is not a PNG, JPEG, WebP or HEIC image.")
        }
        return ImageRequest(
            prompt: instructions, aspect: aspect(from: arguments),
            style: arguments["style"]?.stringValue,
            count: arguments["count"]?.intValue ?? 1, source: url)
    }

    private static func aspect(from arguments: JSONValue) -> ImageAspect {
        let value = arguments["aspect"]?.stringValue ?? arguments["size"]?.stringValue ?? ""
        return ImageAspect(loose: value) ?? .square
    }

    /// The text for the model, with the files for the chat.
    static func reply(for result: ImageGenerationResult, editing: Bool) -> ToolReply {
        let what =
            result.files.count == 1
            ? (editing ? "Made 1 edited picture" : "Drew 1 picture")
            : (editing
                ? "Made \(result.files.count) edited pictures"
                : "Drew \(result.files.count) pictures")
        let text = """
            \(what) with \(result.backendName). The user already sees \
            \(result.files.count == 1 ? "it" : "them") in the chat, so don't describe \
            \(result.files.count == 1 ? "it" : "them") at length or paste the path unless asked. \
            Saved at:
            \(result.files.map { "- \($0.path)" }.joined(separator: "\n"))
            Use these paths with edit_image to change \(result.files.count == 1 ? "it" : "them").
            """
        return ToolReply(text: text, files: result.files)
    }
}
