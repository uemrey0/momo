import AppKit
import Carbon.HIToolbox
import MomoBrain
import MomoVoice
import SwiftUI

/// A borderless panel for the caption bubble. Like the character's panel it never becomes key
/// or main, so it never takes focus from the app the user is in, but it accepts clicks.
final class VoiceBubbleWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: VoiceBubbleController.width, height: 80),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .mainMenu + 2
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        CapturePrivacy.register(self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Shows the caption bubble just below the notch during a spoken request: the live
/// transcript, then the answer while it is spoken, and consent or confirmation questions as
/// compact buttons.
///
/// While it shows, Escape cancels the spoken request. The key is claimed with a temporary
/// hot key, because the bubble never becomes key and so never receives key events.
@MainActor
final class VoiceBubbleController {
    static let width: CGFloat = 380

    private let window = VoiceBubbleWindow()
    private weak var character: CharacterController?
    private var escapeKey: GlobalHotKey?
    private var hideTask: Task<Void, Never>?
    private var height: CGFloat = 80
    private var isResizeScheduled = false
    /// Called when the user presses Escape.
    var onCancel: (() -> Void)?

    var isVisible: Bool { window.isVisible }

    init(
        voice: VoiceController, assistant: AssistantController, character: CharacterController,
        openChat: @escaping () -> Void
    ) {
        self.character = character
        let root = VoiceBubbleView(
            voice: voice, assistant: assistant, open: openChat,
            resize: { [weak self] in self?.requestResize(to: $0) })
        let host = ClickThroughHostingView(rootView: root)
        host.sizingOptions = []
        window.contentView = host
    }

    /// Shows the bubble, or keeps it showing and cancels a pending fade.
    func show() {
        hideTask?.cancel()
        hideTask = nil
        position()
        if escapeKey == nil {
            escapeKey = GlobalHotKey(keyCode: kVK_Escape, modifiers: 0) { [weak self] in
                self?.onCancel?()
            }
        }
        guard !window.isVisible || window.alphaValue < 1 else { return }
        if !window.isVisible { window.alphaValue = 0 }
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().alphaValue = 1
        }
    }

    /// Fades the bubble out after `delay`, unless ``show()`` is called first.
    func hide(after delay: Duration = .zero, completion: (() -> Void)? = nil) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            self.fadeOut()
            completion?()
        }
    }

    private func fadeOut() {
        escapeKey?.unregister()
        escapeKey = nil
        guard window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            window.animator().alphaValue = 0
        } completionHandler: { [window] in
            MainActor.assumeIsolated {
                if window.alphaValue == 0 { window.orderOut(nil) }
            }
        }
    }

    // MARK: - Layout

    private var currentScreen: NSScreen? {
        character?.geometry.flatMap { geometry in
            NSScreen.screens.first { $0.frame == geometry.screenFrame }
        } ?? NSScreen.main
    }

    /// Centred just below the character, which sits in the notch of its screen.
    private func position() {
        guard let frame = currentScreen?.frame else { return }
        let top = (character?.characterBottom ?? frame.maxY - 60) - 10
        let size = CGSize(width: Self.width, height: height)
        window.setFrame(
            NSRect(
                origin: NSPoint(x: frame.midX - size.width / 2, y: top - size.height),
                size: size),
            display: true)
        window.invalidateShadow()
    }

    /// Resizes on the next turn of the run loop, never during a SwiftUI layout pass.
    private func requestResize(to preferred: CGFloat) {
        height = max(44, ceil(preferred))
        guard !isResizeScheduled else { return }
        isResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isResizeScheduled = false
            if abs(self.window.frame.height - self.height) > 0.5 { self.position() }
        }
    }
}

/// The caption bubble's content.
struct VoiceBubbleView: View {
    var voice: VoiceController
    var assistant: AssistantController
    var open: () -> Void
    var resize: (CGFloat) -> Void

    /// The reply to the spoken request, once it started.
    private var reply: ChatMessage? {
        guard let id = voice.session?.messageID,
            let index = assistant.messages.firstIndex(where: { $0.id == id })
        else { return nil }
        return assistant.messages[(index + 1)...].first { $0.role != .user }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let request = voice.realtimeConsent {
                realtimeConsent(request)
            } else if let prompt = assistant.consentPrompt {
                consent(prompt)
            } else if let prompt = assistant.confirmationPrompt {
                confirmation(prompt)
            } else {
                caption
            }
            if let notice = voice.errorMessage {
                Text(verbatim: notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = voice.errorAction {
                    Button(action.title) { voice.performNoticeAction() }
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: VoiceBubbleController.width, alignment: .leading)
        .background(Theme.panelBackground.opacity(0.96), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.08))
        )
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture(perform: open)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            resize($0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .top)
        .help(L("Open the chat"))
        .animation(Theme.quickSpring, value: voice.isListening)
        .animation(Theme.quickSpring, value: voice.liveState)
        .animation(Theme.quickSpring, value: voice.isRealtimeWorking)
    }

    // MARK: - Caption

    @ViewBuilder
    private var caption: some View {
        let transcript = voice.session?.transcript ?? ""
        if voice.isRealtime {
            realtimeCaption(transcript: transcript)
        } else if voice.isListening || voice.isTranscribing || reply == nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusIcon
                Text(verbatim: transcript.isEmpty ? statusText : transcript)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(transcript.isEmpty ? Theme.secondaryText : .white)
                    .lineLimit(4)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let reply {
            if !transcript.isEmpty {
                Text(verbatim: transcript)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: reply.role == .error ? "exclamationmark.triangle" : "waveform")
                    .foregroundStyle(reply.role == .error ? Theme.danger : Theme.accent)
                    .symbolEffect(.variableColor.iterative, isActive: voice.isSpeaking)
                Text(verbatim: replyText(reply))
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white)
                    .lineLimit(6)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if voice.isListeningForFollowUp {
                Label(L("Listening for a follow-up…"), systemImage: "mic")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .scaleEffect(1 + voice.level * 0.08, anchor: .leading)
                    .animation(.easeOut(duration: 0.08), value: voice.level)
            }
        }
    }

    /// The caption of a cloud realtime conversation: what the user said, then what the model
    /// says, or what Momo's assistant is doing for it.
    @ViewBuilder
    private func realtimeCaption(transcript: String) -> some View {
        let reply = voice.realtimeReply.trimmingCharacters(in: .whitespacesAndNewlines)
        if voice.isRealtimeWorking || !reply.isEmpty {
            if !transcript.isEmpty {
                Text(verbatim: transcript)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if voice.isRealtimeWorking && !voice.isSpeaking {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "gearshape.2")
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.pulse, isActive: true)
                        .frame(width: 16)
                    Text(verbatim: voice.realtimeActivity ?? L("Working on it…"))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.variableColor.iterative, isActive: voice.isSpeaking)
                    Text(verbatim: reply)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white)
                        .lineLimit(6)
                        .truncationMode(.head)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if voice.isListeningForFollowUp {
                Label(L("Listening for a follow-up…"), systemImage: "mic")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .scaleEffect(1 + voice.level * 0.08, anchor: .leading)
                    .animation(.easeOut(duration: 0.08), value: voice.level)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusIcon
                Text(verbatim: transcript.isEmpty ? statusText : transcript)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(transcript.isEmpty ? Theme.secondaryText : .white)
                    .lineLimit(4)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func replyText(_ reply: ChatMessage) -> String {
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        if let running = reply.activities.last(where: { $0.state == .running }) {
            return running.label
        }
        // Say which brain works on it, so a slow answer isn't a mystery.
        guard let brain = reply.brainName, !brain.isEmpty else { return L("Thinking…") }
        return String(format: L("%@ is thinking…"), AssistantLiveBrain.spokenName(brain))
    }

    private var statusText: String {
        if voice.liveState == .starting { return L("Getting ready…") }
        if voice.showsListening {
            return voice.isHoldingToTalk ? L("Listening… let go to send") : L("Listening…")
        }
        if voice.isTranscribing { return L("Writing down what you said…") }
        return L("Thinking…")
    }

    private var statusIcon: some View {
        Image(systemName: voice.showsListening ? "mic.fill" : "ellipsis")
            .foregroundStyle(voice.showsListening ? Theme.danger : Theme.secondaryText)
            .scaleEffect(voice.showsListening ? 1 + voice.level * 0.35 : 1)
            .animation(.easeOut(duration: 0.08), value: voice.level)
            .frame(width: 16)
    }

    // MARK: - Questions

    /// Asks before the first cloud realtime conversation with a provider: the audio leaves
    /// the Mac.
    private func realtimeConsent(_ request: RealtimeConsentRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.mic").foregroundStyle(Theme.accent)
                Text(verbatim: String(format: L("Talk live with %@?"), request.providerName))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Text(verbatim: RealtimeVoicePrivacy.localizedNotice)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button(L("Allow")) { voice.answerRealtimeConsent(true) }
                    .buttonStyle(.borderedProminent)
                Button(L("Stay on this Mac")) { voice.answerRealtimeConsent(false) }
                Spacer()
                Button(L("Cancel")) { voice.cancelVoiceSession() }
                    .buttonStyle(.borderless)
            }
            .controlSize(.small)
        }
    }

    private func consent(_ prompt: ConsentPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cloud").foregroundStyle(Theme.color(for: prompt.brain.kind))
                Text(verbatim: String(format: L("Ask %@?"), prompt.brain.name))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                answerHint
            }
            HStack(spacing: 6) {
                Button(L("Ask once")) { assistant.answerConsent(.allowOnce) }
                    .buttonStyle(.borderedProminent)
                Button(L("Stay on this Mac")) { assistant.answerConsent(.useLocal) }
                Spacer()
                Button(L("Cancel")) { assistant.answerConsent(.cancel) }
                    .buttonStyle(.borderless)
            }
            .controlSize(.small)
        }
    }

    private func confirmation(_ prompt: ConfirmationPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised").foregroundStyle(Theme.apiKey)
                Text(verbatim: L("Should I do this?"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                answerHint
            }
            Text(verbatim: prompt.summary)
                .font(.system(size: 12.5))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button(L("Allow")) { assistant.answerConfirmation(true) }
                    .buttonStyle(.borderedProminent)
                Button(L("Don't allow")) { assistant.answerConfirmation(false) }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    /// Shown while Momo listens for a spoken yes or no.
    @ViewBuilder
    private var answerHint: some View {
        if voice.isAwaitingAnswer {
            Label(L("Say yes or no"), systemImage: "mic.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}
