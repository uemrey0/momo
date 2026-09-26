import AppKit
import MomoFace
import MomoKit
import Observation
import SwiftUI

/// The items of the menu shown when right-clicking the character.
enum CharacterMenuItem {
    case talk, today, notes, setUpAI, settings, hide
}

/// Owns the character: its engine, the notch panel it lives in, and the settings the menu bar
/// exposes.
@MainActor
@Observable
final class CharacterController {
    /// The mood chosen in the menu.
    var mood: Mood = .idle {
        didSet { applyRestingMood() }
    }

    /// A mood that comes from what is happening, such as music playing or a focus session.
    /// Shown whenever the user has not picked a mood and no conversation is running.
    var ambientMood: Mood? {
        didSet { applyRestingMood() }
    }

    /// The brain whose colour the eyes show.
    var brain: BrainSource = .local {
        didSet { engine.brain = brain }
    }

    /// Whether Momo plays idle behaviours and falls asleep on its own.
    var isLifeEnabled = true {
        didSet { engine.isLifeEnabled = isLifeEnabled }
    }

    /// Whether the character is on screen.
    var isVisible = true {
        didSet { updateVisibility() }
    }

    /// How the character looks.
    var appearance: CharacterAppearance = .classic {
        didSet {
            guard appearance != oldValue, let geometry else { return }
            hostingView?.rootView = makeFace(layout: geometry.layout)
        }
    }

    @ObservationIgnored let engine = FaceEngine()
    /// Called when the user clicks the character.
    @ObservationIgnored var onClick: (() -> Void)?
    /// Called when the user picks an item from the character's right-click menu.
    @ObservationIgnored var onMenuItem: ((CharacterMenuItem) -> Void)?
    /// Whether the right-click menu should offer to set up AI.
    @ObservationIgnored var needsAISetup: () -> Bool = { false }
    @ObservationIgnored private var panel: NotchPanel?
    @ObservationIgnored private var hostingView: ClickThroughHostingView<AnyView>?
    @ObservationIgnored private(set) var geometry: NotchGeometry?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var brainReset: Task<Void, Never>?
    @ObservationIgnored private var isInConversation = false

    /// The mood Momo returns to between conversations.
    private var restingMood: Mood {
        mood == .idle ? (ambientMood ?? .idle) : mood
    }

    private func applyRestingMood() {
        guard !isInConversation else { return }
        engine.setMood(restingMood)
    }

    init() {
        engine.reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Shows the character and starts following screen and accessibility changes.
    func start() {
        layoutPanel()
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutPanel() }
            })
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.engine.reducesMotion =
                        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                }
            })
    }

    /// Plays Momo's reaction to an event.
    func simulate(_ event: FaceEvent) {
        engine.handle(event)
    }

    /// Seconds of inactivity before Momo dozes off.
    func setSleepDelay(minutes: Double) {
        engine.sleepDelay = max(30, minutes * 60)
    }

    /// Where the bottom of the character is, in screen coordinates, for placing the chat.
    var characterBottom: CGFloat? {
        guard let panel, let geometry else { return nil }
        return panel.frame.maxY - geometry.layout.anchor.y - FaceGeometry.bodyHeight
    }

    // MARK: - Conversation states

    /// Momo is thinking about a request.
    func showWorking() {
        isInConversation = true
        engine.setMood(.thinking)
    }

    /// Momo is answering.
    func showSpeaking() {
        isInConversation = true
        engine.setMood(.speaking)
    }

    /// Momo is listening to the user.
    func showListening() {
        isInConversation = true
        engine.setMood(.listening)
    }

    /// Momo is waiting for the user to decide something.
    func showCurious() {
        engine.setMood(.listening)
        engine.flashMood(.surprised, for: 0.6)
    }

    /// Momo finished answering.
    func showDone() {
        isInConversation = false
        engine.setMood(restingMood)
        engine.flashMood(.happy, for: 1.4)
        resetBrainSoon()
    }

    /// Momo went back to its normal self without answering.
    func showIdle() {
        isInConversation = false
        engine.setMood(restingMood)
        resetBrainSoon()
    }

    /// Something went wrong.
    func showTrouble() {
        isInConversation = false
        engine.setMood(restingMood)
        engine.flashMood(.sad, for: 2.2)
        resetBrainSoon()
    }

    /// A small celebration, for example when a task was added or completed.
    func celebrate() {
        engine.handle(.taskCompleted)
    }

    /// Tints the eyes with the colour of the brain that is thinking.
    func showBrain(_ kind: BrainKind) {
        brainReset?.cancel()
        engine.brain =
            switch kind {
            case .local: .local
            case .subscription: .subscription
            case .apiKey: .apiKey
            }
    }

    private func resetBrainSoon() {
        brainReset?.cancel()
        brainReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self else { return }
            self.engine.brain = self.brain
        }
    }

    // MARK: - Panel

    private func layoutPanel() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        if geometry == self.geometry, panel != nil { return }
        self.geometry = geometry

        let layout = geometry.layout
        let panel = self.panel ?? NotchPanel()
        let hostingView = ClickThroughHostingView(rootView: makeFace(layout: layout))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        self.hostingView = hostingView
        panel.setFrame(geometry.panelFrame(for: layout), display: true)
        self.panel = panel
        updateVisibility()
    }

    private func makeFace(layout: FaceLayout) -> AnyView {
        AnyView(
            FaceView(
                engine: engine, layout: layout, appearance: appearance,
                input: { [weak self] in self?.makeInput(layout: layout) ?? FaceEngine.Input() },
                onTap: { [weak self] in self?.onClick?() }
            )
            .accessibilityLabel(Text("Momo", bundle: .module))
            .contextMenu { contextMenu })
    }

    /// The menu shown when the user right-clicks or Control-clicks Momo.
    @ViewBuilder
    private var contextMenu: some View {
        let pick: (CharacterMenuItem) -> Void = { [weak self] in self?.onMenuItem?($0) }
        Button(L("Talk to Momo")) { pick(.talk) }
        Button(L("Today")) { pick(.today) }
        Button(L("Notes")) { pick(.notes) }
        Divider()
        if needsAISetup() {
            Button(L("Set Up AI…")) { pick(.setUpAI) }
        }
        Button(L("Settings…")) { pick(.settings) }
        Divider()
        Button(L("Hide Momo")) { pick(.hide) }
    }

    private func updateVisibility() {
        guard let panel else { return }
        if isVisible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Reads the cursor position relative to the anchor and lets clicks through everywhere
    /// except on the body.
    private func makeInput(layout: FaceLayout) -> FaceEngine.Input {
        guard let panel else { return FaceEngine.Input() }
        let mouse = NSEvent.mouseLocation
        let anchorX = panel.frame.minX + layout.anchor.x
        let anchorY = panel.frame.maxY - layout.anchor.y
        let pointer = SIMD2(
            (mouse.x - anchorX) / layout.scale, (anchorY - mouse.y) / layout.scale)

        let wantsClicks = engine.hitTest(pointer)
        if panel.ignoresMouseEvents == wantsClicks {
            panel.ignoresMouseEvents = !wantsClicks
        }
        return FaceEngine.Input(pointer: pointer, systemIdleTime: SystemActivity.idleSeconds())
    }
}
