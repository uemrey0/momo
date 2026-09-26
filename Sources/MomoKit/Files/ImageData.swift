import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepares images to send to a brain: PNG or JPEG, no larger than vision models use.
public enum ImageData {
    /// The longest side vision models look at; bigger images only cost more.
    public static let maximumDimension = 1_568
    /// Images above this many bytes are re-encoded as JPEG.
    public static let maximumBytes = 3_500_000

    /// `data` as PNG or JPEG, scaled down so neither side exceeds `maximumDimension`, with
    /// its MIME type. `nil` when the data isn't an image.
    public static func prepared(
        _ data: Data, maximumDimension: Int = maximumDimension, maximumBytes: Int = maximumBytes
    ) -> (data: Data, mimeType: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let type = CGImageSourceGetType(source).map { $0 as String }
        let fits = max(width, height) <= maximumDimension && data.count <= maximumBytes
        if fits, type == UTType.png.identifier { return (data, "image/png") }
        if fits, type == UTType.jpeg.identifier { return (data, "image/jpeg") }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maximumDimension, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        if let png = encode(image, as: .png), png.count <= maximumBytes {
            return (png, "image/png")
        }
        guard let jpeg = encode(image, as: .jpeg, quality: 0.82) else { return nil }
        return (jpeg, "image/jpeg")
    }

    /// Encodes `image` in the given format.
    public static func encode(_ image: CGImage, as type: UTType, quality: Double = 0.9) -> Data? {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, type.identifier as CFString, 1, nil)
        else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
