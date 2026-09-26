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
}

/// UI state shared by the panel's views.
@MainActor
@Observable
final class PanelState {
    var tab: PanelTab = .chat
    /// Bumped to move keyboard focus into the message field.
    var focusRequest = 0
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
    static let size = CGSize(width: 440, height: 580)

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
            openSettings: openSettings, close: { [weak self] in self?.hide() })
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
        position()
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
        let screen =
            character?.geometry.flatMap { geometry in
                NSScreen.screens.first { $0.frame == geometry.screenFrame }
            } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let top = (character?.characterBottom ?? frame.maxY - 110) - 14
        let size = Self.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2, y: max(frame.minY + 20, top - size.height))
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
