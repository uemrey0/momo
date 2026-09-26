import Foundation
import MomoKit

#if canImport(ImagePlayground)
    import CoreGraphics
    import ImageIO
    import ImagePlayground
    import UniformTypeIdentifiers
#endif

/// Draws on the Mac with Apple's Image Playground (Apple Intelligence, macOS 15.4 or later).
/// Free, and nothing leaves the Mac, so it also works in local-only mode.
public struct ApplePlaygroundBackend: ImageBackend {
    public let id = ImageBackendID.applePlayground
    public let name = "Image Playground"
    public let isRemote = false
    public let supportsEditing = true

    public init() {}

    public func availability() async -> ProviderAvailability {
        #if canImport(ImagePlayground)
            if #available(macOS 15.4, *) {
                return await PlaygroundCreator.availability()
            }
        #endif
        return .unavailable("Image Playground needs macOS 15.4 or later with Apple Intelligence.")
    }

    public func generate(_ request: ImageRequest) async throws -> [GeneratedImage] {
        #if canImport(ImagePlayground)
            if #available(macOS 15.4, *) {
                return try await PlaygroundCreator.generate(request)
            }
        #endif
        throw ProviderError("Image Playground needs macOS 15.4 or later.")
    }

    /// Which Image Playground style a hint asks for: "sketch", "illustration" or
    /// "animation", by keywords in English and Turkish. `nil` leaves the choice to the backend.
    static func styleName(for hint: String?) -> String? {
        guard let hint = hint?.lowercased(), !hint.isEmpty else { return nil }
        let styles: [(String, [String])] = [
            ("sketch", ["sketch", "pencil", "drawing", "line art", "çizim", "karakalem", "eskiz"]),
            (
                "animation",
                ["anim", "3d", "cartoon", "pixar", "render", "çizgi film", "animasyon"]
            ),
            (
                "illustration",
                ["illustr", "flat", "vector", "poster", "watercolor", "painting", "illüstrasyon"]
            ),
        ]
        return styles.first { _, words in words.contains { hint.contains($0) } }?.0
    }
}

#if canImport(ImagePlayground)

    /// The calls into `ImageCreator`, which macOS 27 deprecates in favour of the interactive
    /// sheet. It still draws without asking, which is what a tool needs, so it stays until
    /// Apple offers a replacement; this type is marked deprecated too, so the calls don't warn.
    @available(macOS 15.4, *)
    @available(macOS, deprecated: 27.0, message: "ImageCreator is deprecated")
    enum PlaygroundCreator {
        static func availability() async -> ProviderAvailability {
            do {
                _ = try await ImageCreator()
                return .ready
            } catch let error as ImageCreator.Error {
                return .unavailable(describe(error))
            } catch {
                return .unavailable("Image Playground is not available right now.")
            }
        }

        static func describe(_ error: ImageCreator.Error) -> String {
            switch error {
            case .notSupported: "This Mac doesn't support Image Playground."
            case .unavailable:
                "Turn on Apple Intelligence in System Settings (Image Playground may still be downloading)."
            case .unsupportedLanguage: "Image Playground doesn't support this language yet."
            case .backgroundCreationForbidden:
                "Image Playground only draws while Momo is in front. Try again with the chat open."
            case .creationCancelled: "The drawing was cancelled."
            case .unsupportedInputImage: "Image Playground can't use that image."
            case .faceInImageTooSmall: "The face in the image is too small."
            default: "Image Playground couldn't draw this."
            }
        }

        static func generate(_ request: ImageRequest) async throws -> [GeneratedImage] {
            do {
                let creator = try await ImageCreator()
                let style = style(for: request.style, available: creator.availableStyles)
                var concepts: [ImagePlaygroundConcept] = [
                    request.prompt.count <= 80
                        ? .text(request.prompt) : .extracted(from: request.prompt, title: nil)
                ]
                if let source = request.source {
                    guard let concept = ImagePlaygroundConcept.image(source) else {
                        throw ProviderError("Image Playground can't open that image.")
                    }
                    concepts.append(concept)
                }
                var images: [GeneratedImage] = []
                for try await created in creator.images(
                    for: concepts, style: style, limit: request.count)
                {
                    guard let data = png(created.cgImage) else { continue }
                    images.append(GeneratedImage(data: data, fileExtension: "png"))
                }
                return images
            } catch let error as ImageCreator.Error {
                throw ProviderError(describe(error))
            }
        }

        static func style(
            for hint: String?, available: [ImagePlaygroundStyle]
        ) -> ImagePlaygroundStyle {
            let wanted: ImagePlaygroundStyle? =
                switch ApplePlaygroundBackend.styleName(for: hint) {
                case "sketch": .sketch
                case "animation": .animation
                case "illustration": .illustration
                default: nil
                }
            if let wanted, available.contains(wanted) { return wanted }
            if available.contains(.illustration) { return .illustration }
            return available.first ?? .animation
        }

        static func png(_ image: CGImage) -> Data? {
            let data = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    data, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
    }

#endif
