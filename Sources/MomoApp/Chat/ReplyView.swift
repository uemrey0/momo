import AppKit
import ImageIO
import MomoBrain
import MomoKit
import SwiftUI

extension EnvironmentValues {
    /// Asks the last message again.
    @Entry var retryLastMessage: () -> Void = {}
    /// Opens Settings on the AI pane.
    @Entry var openAISettings: () -> Void = {}
    /// Asks macOS for a permission, or opens its page in System Settings.
    @Entry var requestPermission: (MacPermission) -> Void = { _ in }
}

// MARK: - Answer

/// One answer from Momo, told as it happens: while Momo works, what it is doing right now and
/// the steps so far; when it's done, the answer itself, what it made, and a quiet summary of
/// the work that can be opened.
struct AssistantReplyView: View {
    var message: ChatMessage
    var isLatest: Bool
    @State private var showsWork = false
    @State private var isHovering = false
    @State private var copied = false
    @Environment(\.retryLastMessage) private var retry

    private var isWorking: Bool { message.isStreaming }

    /// Permissions steps were missing, each once, so the answer can offer to fix them.
    private var missingPermissions: [MacPermission] {
        var seen: [MacPermission] = []
        for activity in message.activities {
            if let permission = activity.missingPermission, !seen.contains(permission) {
                seen.append(permission)
            }
        }
        return seen
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MomoAvatar(isAnimated: isLatest)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 10) {
                if isWorking {
                    WorkingStatus(message: message)
                    if message.hasWork {
                        WorkTimeline(message: message, isLive: true)
                            .transition(.opacity)
                    }
                } else if message.hasWork {
                    WorkSummary(message: message, isExpanded: $showsWork)
                    if showsWork {
                        WorkTimeline(message: message, isLive: false)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                if !isWorking || !message.hasWork, !message.answer.isEmpty {
                    Text(MessageRow.markdown(message.answer))
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                if !message.artifacts.isEmpty {
                    ArtifactGallery(artifacts: message.artifacts)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
                if !isWorking {
                    ForEach(missingPermissions, id: \.self) { permission in
                        IssueCard(issue: .missing(permission))
                    }
                    if message.answer.isEmpty, message.artifacts.isEmpty,
                        missingPermissions.isEmpty
                    {
                        Text(verbatim: L("Momo stopped before answering."))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Theme.spring, value: message.isStreaming)
        .animation(Theme.spring, value: message.activities)
        .animation(Theme.spring, value: message.artifacts)
        .animation(Theme.spring, value: showsWork)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(Theme.quickSpring) { isHovering = hovering } }
    }

    /// Copy and try again, on hover. The row is always there so hovering never shifts the
    /// conversation.
    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                copied = true
            } label: {
                Label(
                    copied ? L("Copied") : L("Copy"),
                    systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            if isLatest {
                Button(action: retry) {
                    Label(L("Try again"), systemImage: "arrow.clockwise")
                }
            }
        }
        .buttonStyle(.plain)
        .labelStyle(.titleAndIcon)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.tertiaryText)
        .frame(height: 14)
        .opacity(isHovering && !isWorking ? 1 : 0)
    }
}

// MARK: - Working

/// What Momo is doing right now, shimmering, with how long it has been working.
private struct WorkingStatus: View {
    var message: ChatMessage

    private var label: String {
        if let running = message.activities.last(where: { $0.state == .running }) {
            return running.label
        }
        return message.activities.isEmpty ? L("Thinking") : L("Putting it together")
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8) {
                PulseDot(time: time)
                ShimmerText(text: label + "…", time: time)
                    .contentTransition(.opacity)
                Text(verbatim: Self.elapsed(since: message.date, now: timeline.date))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .animation(Theme.quickSpring, value: label)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.minutes, .seconds], width: .narrow))
    }
}

/// A soft, breathing dot in Momo's colours.
private struct PulseDot: View {
    var time: TimeInterval

    var body: some View {
        let phase = (sin(time * 3.2) + 1) / 2
        ZStack {
            Circle()
                .fill(Theme.accent.opacity(0.25))
                .frame(width: 14 + phase * 6, height: 14 + phase * 6)
            Circle()
                .fill(
                    AngularGradient(
                        colors: [Theme.accent, Theme.subscription, Theme.accent],
                        center: .center, angle: .degrees(time * 120))
                )
                .frame(width: 9, height: 9)
        }
        .frame(width: 20, height: 20)
    }
}

/// Text with a light sweeping across it, like it is alive.
private struct ShimmerText: View {
    var text: String
    var time: TimeInterval

    var body: some View {
        let position = (time * 0.6).truncatingRemainder(dividingBy: 1.6) - 0.3
        Text(verbatim: text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: max(0, position - 0.2)),
                        .init(color: .white, location: min(1, max(0, position))),
                        .init(color: .clear, location: min(1, position + 0.2)),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .mask(Text(verbatim: text).font(.system(size: 13, weight: .semibold)))
            }
    }
}

// MARK: - Work

/// The work behind a finished answer, folded into one line that opens the steps: the step
/// itself when there was one, otherwise the steps' icons, how many and how long.
private struct WorkSummary: View {
    var message: ChatMessage
    @Binding var isExpanded: Bool

    private var failed: Int { message.activities.filter { $0.state == .failed }.count }

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 7) {
                icons
                Text(verbatim: summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.secondaryText)
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.05)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary)
    }

    /// Up to three step icons, overlapping like avatars.
    private var icons: some View {
        let shown = Array(message.activities.prefix(3))
        return HStack(spacing: -5) {
            ForEach(shown) { activity in
                let tint = activity.state == .failed ? Theme.danger : Theme.accent
                Image(
                    systemName: activity.state == .failed
                        ? (activity.missingPermission == nil ? "xmark" : "lock.fill")
                        : StepRow.symbol(for: activity.toolName)
                )
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color(red: 0.11, green: 0.115, blue: 0.14)))
                .background(Circle().fill(tint.opacity(0.2)).padding(-1.5))
            }
        }
    }

    private var summary: String {
        if message.activities.count == 1, let step = message.activities.first {
            return [step.label, step.detail].compactMap { $0 }.joined(separator: " · ")
        }
        let steps = String(format: L("%lld steps"), message.activities.count)
        guard let duration = message.duration, duration >= 1 else { return steps }
        let time = Duration.seconds(Int(duration.rounded())).formatted(
            .units(allowed: [.minutes, .seconds], width: .narrow))
        return steps + " · " + time
    }
}

/// The steps Momo took and what it said in between, on a rail that glows while Momo works.
private struct WorkTimeline: View {
    var message: ChatMessage
    var isLive: Bool

    /// While working, earlier steps fold away so the latest stay in view.
    private static let liveLimit = 5

    private var parts: [ReplyPart] {
        var parts = message.parts
        // The answer shows on its own once Momo is done; while working, text after the last
        // step is what Momo is saying right now and belongs on the rail.
        if !isLive, let lastStep = parts.lastIndex(where: Self.isStep) {
            parts = Array(parts[...lastStep])
        }
        if parts.isEmpty {
            // A reopened conversation keeps its steps but not their order.
            parts = message.activities.map { .step($0.id) }
        }
        guard isLive else { return parts }
        let steps = parts.indices.filter { Self.isStep(parts[$0]) }
        guard steps.count > Self.liveLimit else { return parts }
        return Array(parts[steps[steps.count - Self.liveLimit]...])
    }

    private var hiddenSteps: Int {
        guard isLive else { return 0 }
        return max(0, message.activities.count - Self.liveLimit)
    }

    private static func isStep(_ part: ReplyPart) -> Bool {
        if case .step = part { true } else { false }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rail(isLive: isLive)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 8) {
                if hiddenSteps > 0 {
                    Text(verbatim: String(format: L("%d earlier steps"), hiddenSteps))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.tertiaryText)
                }
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .step(let id):
                        if let activity = message.activities.first(where: { $0.id == id }) {
                            StepRow(activity: activity)
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    case .text(let text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            Text(MessageRow.markdown(trimmed))
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.secondaryText)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 9)
    }
}

/// The line beside the steps. While Momo works, light flows down it.
private struct Rail: View {
    var isLive: Bool

    var body: some View {
        if isLive {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let offset =
                    timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.4) / 1.4
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Theme.accent.opacity(0.15), location: 0),
                                .init(color: Theme.accent, location: offset),
                                .init(color: Theme.subscription.opacity(0.15), location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom))
            }
        } else {
            Capsule().fill(Color.white.opacity(0.1))
        }
    }
}

/// One step: what Momo did, on what, and how it went.
struct StepRow: View {
    var activity: ToolActivity
    @Environment(\.requestPermission) private var requestPermission

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon
                .frame(width: 20, height: 20)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: activity.label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(
                        activity.state == .failed ? Theme.danger : .white.opacity(0.85))
                if let detail = activity.detail {
                    Text(verbatim: detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if let seconds = duration {
                Text(verbatim: seconds)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var duration: String? {
        guard let finished = activity.finishedAt else { return nil }
        let seconds = finished.timeIntervalSince(activity.startedAt)
        guard seconds >= 0.5 else { return nil }
        return String(format: "%.1f s", seconds)
    }

    @ViewBuilder private var icon: some View {
        let symbol = Self.symbol(for: activity.toolName)
        ZStack {
            Circle().fill(tint.opacity(0.16))
            switch activity.state {
            case .running:
                Spinner(color: tint)
            case .succeeded:
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint)
            case .failed:
                Image(systemName: activity.missingPermission == nil ? "xmark" : "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.danger)
            }
        }
    }

    private var tint: Color { activity.state == .failed ? Theme.danger : Theme.accent }

    static func symbol(for tool: String) -> String {
        switch tool {
        case "run_command": "terminal"
        case "codex_skill": "sparkles"
        case "generate_image": "paintbrush.pointed.fill"
        case "web_search", "google_web_search": "globe"
        case "read_web_page": "safari"
        case "get_weather": "cloud.sun.fill"
        default: ToolGroup.group(for: tool)?.systemImage ?? "sparkle"
        }
    }
}

/// A small spinning arc, drawn by hand so it also shows in snapshots.
private struct Spinner: View {
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let angle = timeline.date.timeIntervalSinceReferenceDate * 360
            Circle()
                .trim(from: 0.1, to: 0.75)
                .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: 10, height: 10)
                .rotationEffect(.degrees(angle.truncatingRemainder(dividingBy: 360)))
        }
    }
}

// MARK: - Things Momo made

/// The images and files of an answer: images large enough to enjoy, files as tidy chips.
/// Everything opens with a click and can be revealed in Finder.
struct ArtifactGallery: View {
    var artifacts: [ChatArtifact]

    private var images: [ChatArtifact] { artifacts.filter { $0.kind == .image } }
    private var files: [ChatArtifact] { artifacts.filter { $0.kind == .file } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if images.count == 1, let image = images.first {
                ArtifactImageTile(artifact: image, height: 240)
            } else if !images.isEmpty {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                    ],
                    spacing: 8
                ) {
                    ForEach(images, id: \.url) { image in
                        ArtifactImageTile(artifact: image, height: 140)
                    }
                }
            }
            ForEach(files, id: \.url) { file in
                ArtifactFileChip(artifact: file)
            }
        }
    }
}

/// An image Momo made: click to open it, hover for more.
private struct ArtifactImageTile: View {
    var artifact: ChatArtifact
    var height: CGFloat
    @State private var isHovering = false

    var body: some View {
        let thumbnail = ArtifactThumbnails.image(for: artifact.url)
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Theme.card)
                        .overlay(
                            Image(systemName: "photo").font(.system(size: 22))
                                .foregroundStyle(Theme.tertiaryText))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .onTapGesture { ArtifactActions.open(artifact.url) }
            if isHovering {
                HStack(spacing: 4) {
                    ArtifactButton(systemImage: "arrow.up.forward.app", help: L("Open")) {
                        ArtifactActions.open(artifact.url)
                    }
                    ArtifactButton(systemImage: "doc.on.doc", help: L("Copy image")) {
                        ArtifactActions.copyImage(artifact.url)
                    }
                    ArtifactButton(systemImage: "arrow.down.circle", help: L("Save to Downloads")) {
                        ArtifactActions.saveToDownloads(artifact.url)
                    }
                    ArtifactButton(systemImage: "folder", help: L("Show in Finder")) {
                        ArtifactActions.reveal(artifact.url)
                    }
                }
                .padding(6)
                .transition(.opacity)
            }
        }
        .onHover { hovering in withAnimation(Theme.quickSpring) { isHovering = hovering } }
        .contextMenu {
            Button(L("Open")) { ArtifactActions.open(artifact.url) }
            Button(L("Copy image")) { ArtifactActions.copyImage(artifact.url) }
            Button(L("Save to Downloads")) { ArtifactActions.saveToDownloads(artifact.url) }
            Button(L("Show in Finder")) { ArtifactActions.reveal(artifact.url) }
        }
        .accessibilityElement()
        .accessibilityLabel(L("Image Momo made"))
        .accessibilityAddTraits(.isButton)
    }
}

private struct ArtifactButton: View {
    var systemImage: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.55), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A file Momo made or found: its icon, name and size.
private struct ArtifactFileChip: View {
    var artifact: ChatArtifact
    @State private var isHovering = false

    private var size: String? {
        guard
            let bytes = try? artifact.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: artifact.url.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: artifact.url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size {
                    Text(verbatim: size)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            Spacer(minLength: 8)
            Button {
                ArtifactActions.reveal(artifact.url)
            } label: {
                Image(systemName: "folder").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            .help(L("Show in Finder"))
            .accessibilityLabel(L("Show in Finder"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isHovering ? Theme.cardStrong : Theme.card,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { ArtifactActions.open(artifact.url) }
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(.isButton)
    }
}

/// What can be done with something Momo made.
@MainActor
enum ArtifactActions {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copyImage(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    static func saveToDownloads(_ url: URL) {
        guard
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
                .first
        else { return }
        var destination = downloads.appendingPathComponent(url.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = url.deletingPathExtension().lastPathComponent
            destination = downloads.appendingPathComponent(
                "\(base) \(counter).\(url.pathExtension)")
            counter += 1
        }
        if (try? FileManager.default.copyItem(at: url, to: destination)) != nil {
            reveal(destination)
        }
    }
}

/// Small, cached previews of images, made with Image I/O so large images stay cheap.
@MainActor
enum ArtifactThumbnails {
    private static var cache: [URL: NSImage] = [:]

    static func image(for url: URL) -> NSImage? {
        if let cached = cache[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1000,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
        else { return nil }
        let image = NSImage(
            cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        cache[url] = image
        return image
    }
}

// MARK: - Problems

/// Something went wrong, said plainly, with the buttons that fix it.
struct IssueCard: View {
    var issue: ChatIssue
    @State private var showsDetails = false
    @Environment(\.retryLastMessage) private var retry
    @Environment(\.openAISettings) private var openAISettings
    @Environment(\.requestPermission) private var requestPermission

    private var tint: Color {
        switch issue.kind {
        case .permission, .noBrain, .setup, .signIn: Theme.apiKey
        case .network, .rateLimit: Theme.subscription
        case .other: Theme.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: issue.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: issue.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: issue.message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                ForEach(Array(issue.actions.enumerated()), id: \.offset) { index, action in
                    IssueButton(title: title(for: action), isPrimary: index == 0, tint: tint) {
                        perform(action)
                    }
                }
                Spacer(minLength: 0)
                if issue.details != nil {
                    Button {
                        withAnimation(Theme.quickSpring) { showsDetails.toggle() }
                    } label: {
                        Text(verbatim: showsDetails ? L("Hide details") : L("Details"))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                }
            }
            if showsDetails, let details = issue.details {
                Text(verbatim: details)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [tint.opacity(0.13), tint.opacity(0.05)], startPoint: .topLeading,
                endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.22)))
    }

    private func title(for action: ChatIssue.Action) -> String {
        switch action {
        case .retry: L("Try again")
        case .openAISettings: L("Open AI settings")
        case .setUpAI: L("Set up AI")
        case .allow: L("Allow access")
        }
    }

    private func perform(_ action: ChatIssue.Action) {
        switch action {
        case .retry: retry()
        case .openAISettings, .setUpAI: openAISettings()
        case .allow(let permission): requestPermission(permission)
        }
    }
}

private struct IssueButton: View {
    var title: String
    var isPrimary: Bool
    var tint: Color
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isPrimary ? Color.black.opacity(0.82) : .white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    if isPrimary {
                        Capsule().fill(tint.opacity(isHovering ? 1 : 0.9))
                    } else {
                        Capsule().fill(Color.white.opacity(isHovering ? 0.14 : 0.08))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// An error in the conversation: Momo explains it and offers the way out.
struct ErrorReplyView: View {
    var message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MomoAvatar(isAnimated: false)
                .padding(.top, 1)
            IssueCard(issue: message.issue ?? ChatIssue(message: message.text))
        }
    }
}
