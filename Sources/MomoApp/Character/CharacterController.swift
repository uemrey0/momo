import AppKit
import MomoFace
import Observation
import SwiftUI

/// Owns the character: its engine, the notch panel it lives in, and the settings the menu bar
/// exposes.
@MainActor
@Observable
final class CharacterController {
    /// The mood chosen in the menu.
    var mood: Mood = .idle {
        didSet { engine.setMood(mood) }
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

    @ObservationIgnored let engine = FaceEngine()
    @ObservationIgnored private var panel: NotchPanel?
    @ObservationIgnored private var geometry: NotchGeometry?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

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

    /// Plays Momo's reaction to an event, for trying reactions out from the menu.
    func simulate(_ event: FaceEvent) {
        engine.handle(event)
    }

    // MARK: - Panel

    private func layoutPanel() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        if geometry == self.geometry, panel != nil { return }
        self.geometry = geometry

        let layout = geometry.layout
        let panel = self.panel ?? NotchPanel()
        let face = FaceView(engine: engine, layout: layout) { [weak self] in
            self?.makeInput(layout: layout) ?? FaceEngine.Input()
        }
        .accessibilityLabel(Text("Momo", bundle: .module))

        let hostingView = ClickThroughHostingView(rootView: face)
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.setFrame(geometry.panelFrame(for: layout), display: true)
        self.panel = panel
        updateVisibility()
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
