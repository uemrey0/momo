import AppKit
import SwiftUI

/// The sections of the panel.
enum PanelTab: String, CaseIterable, Identifiable {
    case chat
    case today
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: L("Chat", comment: "Panel tab")
        case .today: L("Today", comment: "Panel tab")
        case .notes: L("Notes", comment: "Panel tab")
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right.fill"
        case .today: "sun.max.fill"
        case .notes: "note.text"
        }
    }
}

/// UI state shared by the panel's views.
@MainActor
@Observable
final class PanelState {
    var tab: PanelTab = .chat
    /// Bumped to move keyboard focus into the message field.
    var focusRequest = 0
    /// Bumped each time the panel opens, to play its entrance.
    var presentations = 0
    /// The height the panel's content is laid out at. Changes without animation.
    var layoutHeight: CGFloat = 420
    /// How much of the panel shows, from the top. Animates when the panel grows or shrinks.
    var visibleHeight = CGFloat.greatestFiniteMagnitude
}

/// A floating panel that can take keyboard input without activating the app, like Spotlight.
final class ChatWindow: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 580),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .mainMenu + 2
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Shows and hides the chat panel below the character.
@MainActor
final class ChatPanelController {
    /// The panel's width and its height in snapshots. On screen the height follows the content.
    static let size = CGSize(width: 440, height: 580)
    static let minimumHeight: CGFloat = 240
    private var height: CGFloat = 420
    private var isResizeScheduled = false
    private var shrink: DispatchWorkItem?

    private let window = ChatWindow()
    private let assistant: AssistantController
    private let state: PanelState
    private weak var character: CharacterController?
    private var resignObserver: (any NSObjectProtocol)?

    var isVisible: Bool { window.isVisible }

    init(
        assistant: AssistantController, today: TodayModel, notes: NotesModel,
        state: PanelState, voice: VoiceController?, character: CharacterController,
        openSettings: @escaping (SettingsPane?) -> Void
    ) {
        self.assistant = assistant
        self.state = state
        self.character = character
        let root = PanelView(
            assistant: assistant, today: today, notes: notes, state: state, voice: voice,
            openSettings: openSettings, close: { [weak self] in self?.hide() },
            resize: { [weak self] in self?.requestResize(to: $0) })
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        window.contentView = host
        window.onCancel = { [weak self] in self?.hide() }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideIfIdle() }
        }
    }

    func toggle(tab: PanelTab? = nil) {
        if window.isVisible, tab == nil || tab == state.tab {
            hide()
        } else {
            show(tab: tab)
        }
    }

    func show(tab: PanelTab? = nil) {
        if let tab { state.tab = tab }
        // Only a panel that is opening plays its entrance; an open one just switches tabs.
        guard !window.isVisible else {
            window.makeKey()
            state.focusRequest += 1
            return
        }
        position()
        state.presentations += 1
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                window.animator().alphaValue = 1
            }
        }
        window.makeKey()
        state.focusRequest += 1
        Task { await assistant.refreshProviders() }
    }

    func hide() {
        guard window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            window.animator().alphaValue = 0
        } completionHandler: { [window] in
            MainActor.assumeIsolated { window.orderOut(nil) }
        }
    }

    /// Hides when the user clicks elsewhere, unless Momo is waiting for an answer.
    private func hideIfIdle() {
        guard assistant.consentPrompt == nil, assistant.confirmationPrompt == nil else { return }
        hide()
    }

    private func position() {
        guard let frame = currentScreen?.frame else { return }
        let target = clamped(height, on: frame)
        shrink?.cancel()
        withTransaction(Self.still) {
            state.layoutHeight = target
            state.visibleHeight = target
        }
        setWindowHeight(target, on: frame)
    }

    private var currentScreen: NSScreen? {
        character?.geometry.flatMap { geometry in
            NSScreen.screens.first { $0.frame == geometry.screenFrame }
        } ?? window.screen ?? NSScreen.main
    }

    /// Where the top of the panel goes: just below the character.
    private func top(on frame: NSRect) -> CGFloat {
        (character?.characterBottom ?? frame.maxY - 110) - 14
    }

    private func clamped(_ height: CGFloat, on frame: NSRect) -> CGFloat {
        let available = top(on: frame) - frame.minY - 40
        return min(max(Self.minimumHeight, height), min(720, available))
    }

    /// Sizes the transparent window, keeping its top edge just below the character.
    private func setWindowHeight(_ height: CGFloat, on frame: NSRect) {
        let size = CGSize(width: Self.size.width, height: height)
        let origin = NSPoint(
            x: frame.midX - size.width / 2, y: max(frame.minY + 20, top(on: frame) - size.height))
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.invalidateShadow()
    }

    /// Remembers the height the content wants and resizes on the next turn of the run loop.
    /// Resizing the window while SwiftUI is still laying out would start another layout pass
    /// from inside this one, which AppKit stops with an exception.
    private func requestResize(to preferred: CGFloat) {
        height = preferred
        guard !isResizeScheduled else { return }
        isResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isResizeScheduled = false
            self.resize(to: self.height)
        }
    }

    private static var still: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }

    /// Grows or shrinks the panel to fit its content, keeping its top edge in place.
    ///
    /// Only the panel's visible outline animates. Growing lays the content out at the new
    /// size and enlarges the window at once, then unrolls the outline; shrinking rolls the
    /// outline up first and makes the window smaller afterwards. Nothing is re-laid out
    /// during the animation, so nothing slides. (Animating the window lets the content lag
    /// behind it, and animating SwiftUI layout in this window trips AppKit's constraint
    /// pass limit.)
    private func resize(to preferred: CGFloat) {
        guard let screen = currentScreen?.frame else { return }
        let target = clamped(preferred, on: screen)
        guard abs(state.layoutHeight - target) > 1 || abs(state.visibleHeight - target) > 1
        else { return }
        shrink?.cancel()
        guard window.isVisible else {
            withTransaction(Self.still) {
                state.layoutHeight = target
                state.visibleHeight = target
            }
            setWindowHeight(target, on: screen)
            return
        }
        if target > window.frame.height {
            let shown = min(state.visibleHeight, window.frame.height)
            withTransaction(Self.still) {
                state.visibleHeight = shown
                state.layoutHeight = target
            }
            setWindowHeight(target, on: screen)
            DispatchQueue.main.async { [weak self] in
                withAnimation(Theme.spring) { self?.state.visibleHeight = target }
            }
        } else {
            withAnimation(Theme.spring) { state.visibleHeight = target }
            let finish = DispatchWorkItem { [weak self] in
                guard let self else { return }
                withTransaction(Self.still) { self.state.layoutHeight = target }
                self.setWindowHeight(target, on: screen)
            }
            shrink = finish
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: finish)
        }
    }
}
