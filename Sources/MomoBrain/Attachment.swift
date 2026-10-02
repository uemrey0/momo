import Foundation
import MomoKit

/// A file or image the user attached to a message.
public struct ChatAttachment: Sendable, Hashable, Identifiable {
    public enum Content: Sendable, Hashable {
        /// PNG or JPEG data, sent to brains that can see.
        case image(data: Data, mimeType: String)
        /// The text extracted from a document, sent to every brain.
        case file(text: String)
    }

    public var id: String
    /// The file name, shown to the user and the model.
    public var name: String
    public var content: Content

    public init(id: String = UUID().uuidString, name: String, content: Content) {
        self.id = id
        self.name = name
        self.content = content
    }

    public var isImage: Bool {
        if case .image = content { return true }
        return false
    }

    /// How a brain reads the attachment as text: the file's contents, or a note for an image
    /// it cannot see (`nil` when the image is sent to it natively).
    func contextText(imagesVisible: Bool) -> String? {
        contextText(images: imagesVisible ? .sent : .notVisible)
    }

    func contextText(images: ImageNote) -> String? {
        switch (content, images) {
        case (.file(let text), _):
            "[Attached file: \(name)]\n\(text)\n[End of \(name)]"
        case (.image, .sent):
            nil
        case (.image, .notVisible):
            "[image attached: \(name), not visible to this brain]"
        case (.image, .sharedEarlier):
            "[image shared earlier: \(name), no longer attached; "
                + "ask the user to send it again if you need to look at it]"
        }
    }
}

/// How a turn's images read as text.
public enum ImageNote: Sendable {
    /// The provider sends the images natively, so the text doesn't mention them.
    case sent
    /// The brain can't see images.
    case notVisible
    /// The brain can see images, but this older turn's are no longer sent with each message.
    case sharedEarlier
}

extension ChatTurn {
    /// The images attached to this turn.
    public var images: [(data: Data, mimeType: String)] {
        attachments.compactMap { attachment in
            if case .image(let data, let mimeType) = attachment.content {
                (data, mimeType)
            } else {
                nil
            }
        }
    }

    public var hasImages: Bool { attachments.contains(where: \.isImage) }

    /// The turn as text: attached documents, then the message, then the tools it used.
    /// Images are described in words unless `imagesVisible`, when the provider sends them
    /// natively alongside this text.
    public func context(imagesVisible: Bool) -> String {
        context(images: imagesVisible ? .sent : .notVisible)
    }

    /// The turn as text, with its images described as `images` says.
    public func context(images: ImageNote) -> String {
        let parts =
            attachments.compactMap { $0.contextText(images: images) }
            + [text, ToolRecord.render(toolRecords)]
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
