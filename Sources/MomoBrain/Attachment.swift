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
        switch content {
        case .file(let text):
            return "[Attached file: \(name)]\n\(text)\n[End of \(name)]"
        case .image:
            return imagesVisible ? nil : "[image attached: \(name), not visible to this brain]"
        }
    }
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
        let parts =
            attachments.compactMap { $0.contextText(imagesVisible: imagesVisible) }
            + [text, ToolRecord.render(toolRecords)]
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
