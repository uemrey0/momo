import AppKit
import MomoBrain
import MomoKit
import UniformTypeIdentifiers

extension AssistantController {
    /// The most attachments one message can carry.
    static let maximumAttachments = 10

    /// Reads files and adds them to the next message: images as pictures, documents as text.
    /// Each file shows as a placeholder at once and is read in the background.
    func attach(fileURLs urls: [URL]) {
        for url in urls {
            guard
                let placeholder = startLoading(
                    name: url.lastPathComponent, isImage: DocumentText.isImage(url))
            else { return }
            Task {
                let loaded = await Task.detached { Result { try Self.attachment(from: url) } }.value
                guard finishLoading(placeholder) else { return }
                switch loaded {
                case .success(let attachment): add(attachment)
                case .failure:
                    attachmentNotice = String(
                        format: L(
                            "Couldn't read “%@”. Momo can attach images, PDFs, and text or Word documents."
                        ), url.lastPathComponent)
                }
            }
        }
    }

    /// Adds image data, such as a pasted picture, to the next message.
    func attach(imageData data: Data, name: String) {
        guard let prepared = ImageData.prepared(data) else {
            attachmentNotice = L("That picture couldn't be read.")
            return
        }
        add(
            ChatAttachment(
                name: name, content: .image(data: prepared.data, mimeType: prepared.mimeType)))
    }

    /// Takes a screenshot of the screen, without Momo, and adds it to the next message.
    func attachScreenshot() {
        guard ScreenReader.hasPermission else {
            ScreenReader.requestPermission()
            attachmentNotice = L(
                "To attach screenshots, allow Momo in System Settings → Privacy & Security → Screen Recording."
            )
            return
        }
        let name =
            String(
                format: L("Screenshot %@"),
                Date().formatted(date: .omitted, time: .shortened)) + ".png"
        guard let placeholder = startLoading(name: name, isImage: true) else { return }
        Task {
            do {
                let data = try await ScreenReader.screenshot()
                guard finishLoading(placeholder) else { return }
                attach(imageData: data, name: name)
            } catch {
                guard finishLoading(placeholder) else { return }
                attachmentNotice = L("The screenshot didn't work. Try again.")
            }
        }
    }

    /// Removes a pending attachment, or stops one that is still loading.
    func removeAttachment(id: String) {
        pendingAttachments.removeAll { $0.id == id }
        loadingAttachments.removeAll { $0.id == id }
        attachmentNotice = nil
    }

    /// Shows a placeholder for an attachment being read, or returns `nil` when the message
    /// is already full.
    private func startLoading(name: String, isImage: Bool) -> LoadingAttachment? {
        guard pendingAttachments.count + loadingAttachments.count < Self.maximumAttachments else {
            attachmentNotice = String(
                format: L("A message can have up to %d attachments."), Self.maximumAttachments)
            return nil
        }
        attachmentNotice = nil
        let placeholder = LoadingAttachment(name: name, isImage: isImage)
        loadingAttachments.append(placeholder)
        return placeholder
    }

    /// Removes a placeholder once its attachment is read. Returns `false` if the user removed
    /// it meanwhile, so the result should be dropped.
    private func finishLoading(_ placeholder: LoadingAttachment) -> Bool {
        guard let index = loadingAttachments.firstIndex(where: { $0.id == placeholder.id })
        else { return false }
        loadingAttachments.remove(at: index)
        return true
    }

    private func add(_ attachment: ChatAttachment) {
        guard pendingAttachments.count + loadingAttachments.count < Self.maximumAttachments else {
            attachmentNotice = String(
                format: L("A message can have up to %d attachments."), Self.maximumAttachments)
            return
        }
        attachmentNotice = nil
        pendingAttachments.append(attachment)
    }

    /// Reads a file as an attachment. Runs off the main thread.
    nonisolated static func attachment(from url: URL) throws -> ChatAttachment {
        guard DocumentText.isImage(url) else {
            return ChatAttachment(
                name: url.lastPathComponent,
                content: .file(text: try DocumentText.extract(from: url)))
        }
        let data = try Data(contentsOf: url)
        guard let prepared = ImageData.prepared(data) else {
            throw ToolError("“\(url.lastPathComponent)” is not an image Momo can read.")
        }
        return ChatAttachment(
            name: url.lastPathComponent,
            content: .image(data: prepared.data, mimeType: prepared.mimeType))
    }
}

/// An attachment still being read, shown in the composer until it is ready.
struct LoadingAttachment: Identifiable, Equatable, Sendable {
    let id = UUID().uuidString
    var name: String
    var isImage: Bool
}

/// Something dropped or pasted onto the panel.
enum DroppedItem: Sendable {
    case file(URL)
    case image(Data)
}

/// Loads dropped items. Its callbacks run on background threads, so it lives outside
/// main-actor code.
enum DropLoader {
    /// The types the panel accepts.
    static let types: [UTType] = [.fileURL, .image]

    /// Loads each provider's file or image and hands it to `deliver` on the main actor.
    static func load(
        _ providers: [NSItemProvider], deliver: @escaping @MainActor @Sendable (DroppedItem) -> Void
    ) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in deliver(.file(url)) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) {
                    data, _ in
                    guard let data else { return }
                    Task { @MainActor in deliver(.image(data)) }
                }
            }
        }
    }

    /// Files or an image on the pasteboard, if it holds those rather than text.
    static func pastedItems(from pasteboard: NSPasteboard = .general) -> [DroppedItem] {
        let urls =
            pasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            ?? []
        if !urls.isEmpty { return urls.map(DroppedItem.file) }
        // Text copied from documents often comes with a picture of itself; paste the text.
        guard pasteboard.string(forType: .string) == nil,
            let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        else { return [] }
        return [.image(data)]
    }
}

extension AssistantController {
    /// Adds dropped or pasted items to the next message.
    func attach(_ items: [DroppedItem]) {
        let files = items.compactMap { if case .file(let url) = $0 { url } else { nil } }
        if !files.isEmpty { attach(fileURLs: files) }
        for case .image(let data) in items {
            attach(imageData: data, name: L("Pasted image") + ".png")
        }
    }
}
