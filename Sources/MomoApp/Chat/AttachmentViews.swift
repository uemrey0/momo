import AppKit
import MomoBrain
import MomoKit
import SwiftUI

/// The paperclip in the composer: attach files or a screenshot. A plain button that opens
/// a native menu, so it lines up with the composer's other buttons exactly.
struct AttachMenu: View {
    var chooseFiles: () -> Void
    var attachScreenshot: () -> Void

    var body: some View {
        Button(action: showMenu) {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L("Attach files or a screenshot"))
        .accessibilityLabel(L("Attach"))
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("Attach files…"), systemImage: "doc", action: chooseFiles))
        menu.addItem(
            ClosureMenuItem(
                L("Attach screenshot"), systemImage: "camera.viewfinder", action: attachScreenshot))
        // Opens just above the pointer, like a menu button's would.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, systemImage: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

/// Attachments waiting to be sent, each with a remove button. Ones still being read show
/// as placeholders with a spinner.
struct AttachmentStrip: View {
    var attachments: [ChatAttachment]
    var loading: [LoadingAttachment]
    var remove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment)
                        .overlay(alignment: .topTrailing) {
                            removeButton(id: attachment.id, name: attachment.name)
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                ForEach(loading) { placeholder in
                    LoadingChip(attachment: placeholder)
                        .overlay(alignment: .topTrailing) {
                            removeButton(id: placeholder.id, name: placeholder.name)
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(.top, 4)
            .padding(.trailing, 4)
        }
        .scrollIndicators(.never)
    }

    private func removeButton(id: String, name: String) -> some View {
        Button {
            remove(id)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.black.opacity(0.7))
        }
        .buttonStyle(.plain)
        .offset(x: 4, y: -4)
        .help(L("Remove"))
        .accessibilityLabel(String(format: L("Remove %@"), name))
    }
}

/// An attachment still being read: a spinner, with the name for documents.
struct LoadingChip: View {
    var attachment: LoadingAttachment
    var size: CGFloat = 44

    var body: some View {
        Group {
            if attachment.isImage {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: size, height: size)
            } else {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(verbatim: attachment.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .frame(height: size)
            }
        }
        .background(Theme.cardStrong, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(attachment.name)
        .accessibilityLabel(String(format: L("Loading %@"), attachment.name))
    }
}

/// One attachment: a thumbnail for an image, an icon and name for a document.
struct AttachmentChip: View {
    var attachment: ChatAttachment
    var size: CGFloat = 44

    var body: some View {
        switch attachment.content {
        case .image(let data, _):
            Group {
                if let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1))
            )
            .help(attachment.name)
            .accessibilityLabel(attachment.name)
        case .file:
            FileChip(name: attachment.name, isImage: false, height: size)
        }
    }
}

/// A document's icon and name.
struct FileChip: View {
    var name: String
    var isImage: Bool
    var height: CGFloat = 44

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isImage ? "photo" : "doc.text.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.pastel(for: name))
            Text(verbatim: name)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(Theme.cardStrong, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(name)
    }
}

/// The attachments of a sent message, above its bubble.
struct SentAttachments: View {
    var attachments: [ChatAttachment]
    var saved: [ConversationMessage.AttachmentInfo]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                AttachmentChip(attachment: attachment, size: attachment.isImage ? 72 : 34)
            }
            ForEach(Array(saved.enumerated()), id: \.offset) { _, info in
                FileChip(name: info.name, isImage: info.isImage, height: 34)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A short note about attachments, dismissed with a tap.
struct AttachmentNotice: View {
    var text: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "paperclip").foregroundStyle(Theme.apiKey)
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiaryText)
            .help(L("Dismiss"))
            .accessibilityLabel(L("Dismiss"))
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Shown over the chat while files are dragged onto it.
struct DropHighlight: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.panelBackground.opacity(0.82))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(verbatim: L("Drop to attach"))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
        }
        .padding(10)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
