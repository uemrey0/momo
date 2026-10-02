import AppKit
import MomoFace
import MomoKit
import Observation
import SwiftUI

/// The items of the menu shown when right-clicking the character.
enum CharacterMenuItem {
    case talk, today, notes, meetings, stopMeeting, setUpAI, settings, hide
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

    /// Whether meeting notes are being taken: a pulsing red dot shows next to the character,
    /// and Momo looks focused unless another mood is showing.
    var isRecordingMeeting = false {
        didSet {
            guard isRecordingMeeting != oldValue else { return }
            recordingIndicator.isOn = isRecordingMeeting
            if isRecordingMeeting, ambientMood == nil || ambientMood == .music {
                moodBeforeMeeting = ambientMood
                ambientMood = .focused
            } else if !isRecordingMeeting, let previous = moodBeforeMeeting {
                if ambientMood == .focused { ambientMood = previous }
                moodBeforeMeeting = nil
            }
        }
    }

    @ObservationIgnored let engine = FaceEngine()
    @ObservationIgnored private let recordingIndicator = RecordingIndicatorState()
    @ObservationIgnored private let playback = FacePlaybackState()
    @ObservationIgnored private var idleTime = IdleTimeSampler()
    @ObservationIgnored private var screensAreAsleep = false
    @ObservationIgnored private var sessionIsActive = true
    /// The ambient mood the meeting replaced, restored when it ends. `.some(nil)` means none.
    @ObservationIgnored private var moodBeforeMeeting: Mood??
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
        // Nobody sees Momo while the screens sleep or another user is logged in, so it stops
        // drawing until they come back.
        let workspaceEvents: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in workspaceEvents {
            observers.append(
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handleWorkspaceEvent(name) }
                })
        }
    }

    private func handleWorkspaceEvent(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.screensDidSleepNotification: screensAreAsleep = true
        case NSWorkspace.screensDidWakeNotification: screensAreAsleep = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionIsActive = false
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionIsActive = true
        default: return
        }
        updatePlayback()
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
        let panel = self.panel ?? makePanel()
        let hostingView = ClickThroughHostingView(rootView: makeFace(layout: layout))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        self.hostingView = hostingView
        panel.setFrame(geometry.panelFrame(for: layout), display: true)
        self.panel = panel
        updateVisibility()
    }

    /// Creates the panel and pauses the character whenever the panel is covered or hidden.
    private func makePanel() -> NotchPanel {
        let panel = NotchPanel()
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePlayback() }
            })
        return panel
    }

    private func updatePlayback() {
        let isOnScreen = panel?.occlusionState.contains(.visible) ?? false
        let isPaused = screensAreAsleep || !sessionIsActive || !isOnScreen
        if playback.isPaused != isPaused { playback.isPaused = isPaused }
    }

    private func makeFace(layout: FaceLayout) -> AnyView {
        let engine = engine
        let appearance = appearance
        let input: @MainActor () -> FaceEngine.Input = { [weak self] in
            self?.makeInput(layout: layout) ?? FaceEngine.Input()
        }
        let onTap: @MainActor () -> Void = { [weak self] in self?.onClick?() }
        return AnyView(
            PausableFace(playback: playback) { isPaused in
                FaceView(
                    engine: engine, layout: layout, appearance: appearance, input: input,
                    onTap: onTap, isPaused: isPaused)
            }
            .accessibilityLabel(Text("Momo", bundle: .module))
            .contextMenu { contextMenu }
            .overlay(alignment: .topLeading) {
                RecordingDot(state: recordingIndicator)
                    .position(
                        x: layout.anchor.x + (FaceGeometry.bodyWidth / 2 + 12) * layout.scale,
                        y: layout.anchor.y + 12 * layout.scale)
            })
    }

    /// The menu shown when the user right-clicks or Control-clicks Momo.
    @ViewBuilder
    private var contextMenu: some View {
        let pick: (CharacterMenuItem) -> Void = { [weak self] in self?.onMenuItem?($0) }
        Button(L("Talk to Momo")) { pick(.talk) }
        Button(L("Today")) { pick(.today) }
        Button(L("Notes")) { pick(.notes) }
        Button(L("Meetings")) { pick(.meetings) }
        if isRecordingMeeting {
            Button(L("Stop Meeting Notes")) { pick(.stopMeeting) }
        }
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
        updatePlayback()
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
        let idleSeconds = idleTime.idleSeconds(
            now: ProcessInfo.processInfo.systemUptime, read: SystemActivity.idleSeconds)
        return FaceEngine.Input(pointer: pointer, systemIdleTime: idleSeconds)
    }
}

/// Whether the notch character draws. Separate from the controller so the face's view
/// doesn't hold on to it.
@MainActor
@Observable
final class FacePlaybackState {
    var isPaused = false
}

/// Shows a face that stops drawing while `playback` is paused.
private struct PausableFace<Face: View>: View {
    var playback: FacePlaybackState
    @ViewBuilder var face: (_ isPaused: Bool) -> Face

    var body: some View {
        face(playback.isPaused)
    }
}

/// Whether the recording dot shows. Separate from the controller so the face's view doesn't
/// hold on to it.
@MainActor
@Observable
final class RecordingIndicatorState {
    var isOn = false
}

/// A small pulsing red dot shown next to Momo while it takes meeting notes, so recording is
/// always visible.
private struct RecordingDot: View {
    var state: RecordingIndicatorState
    @State private var isPulsing = false

    var body: some View {
        if state.isOn {
            Circle()
                .fill(Color(red: 1, green: 0.27, blue: 0.23))
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                .opacity(isPulsing ? 0.45 : 1)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing
                )
                .onAppear { isPulsing = true }
                .onDisappear { isPulsing = false }
                .help(L("Taking meeting notes"))
                .accessibilityLabel(L("Taking meeting notes"))
                .transition(.scale.combined(with: .opacity))
        }
    }
}
