import MomoBrain
import MomoFace
import MomoKit
import SwiftUI

/// The conversation with Momo.
struct ChatView: View {
    @Bindable var assistant: AssistantController
    @Bindable var state: PanelState
    var voice: VoiceController? = nil
    var setUpAI: () -> Void = {}
    @FocusState private var isComposerFocused: Bool
    @Environment(\.snapshotMode) private var snapshotMode
    @State private var messagesHeight: CGFloat = 0
    @State private var welcomeHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    /// Whether the brains were checked and none of them can answer yet.
    private var needsAISetup: Bool {
        !assistant.providerStatuses.isEmpty
            && !assistant.providerStatuses.contains { $0.availability.isReady }
    }

    /// The height the chat would like: its messages and the composer, or a comfortable
    /// size for the welcome screen.
    private var preferredHeight: CGFloat {
        let content = assistant.messages.isEmpty ? welcomeHeight : messagesHeight
        // Nothing to report until the content has been measured.
        guard content > 0, footerHeight > 0 else { return 0 }
        return content + footerHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            if assistant.messages.isEmpty && needsAISetup {
                SetUpAICard(setUp: setUpAI, height: $welcomeHeight)
                    .transition(.opacity)
            } else if assistant.messages.isEmpty {
                EmptyChatView(height: $welcomeHeight) { suggestion in
                    withAnimation(Theme.spring) { assistant.send(suggestion) }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                messageList
            }
            VStack(spacing: 8) {
                if let prompt = assistant.consentPrompt {
                    ConsentCard(prompt: prompt) { assistant.answerConsent($0) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let prompt = assistant.confirmationPrompt {
                    ConfirmationCard(prompt: prompt) { assistant.answerConfirmation($0) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                composer
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 6)
            // Always at its natural height, so measuring it can't feed back into layout.
            .fixedSize(horizontal: false, vertical: true)
            .measureHeight($footerHeight)
        }
        .preference(key: PanelHeightKey.self, value: preferredHeight)
        .animation(Theme.spring, value: assistant.consentPrompt)
        .animation(Theme.spring, value: assistant.confirmationPrompt)
        .animation(Theme.spring, value: assistant.messages.isEmpty)
        .onChange(of: state.focusRequest, initial: true) { isComposerFocused = true }
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(assistant.messages.enumerated()), id: \.element.id) { index, message in
                MessageRow(
                    message: message, isLatest: index == assistant.messages.count - 1
                )
                .id(message.id)
                .transition(
                    .asymmetric(
                        insertion: .opacity
                            .combined(with: .offset(y: 14))
                            .combined(with: .scale(scale: 0.96, anchor: anchor(for: message))),
                        removal: .opacity))
            }
            Color.clear.frame(height: 1).id("bottom")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .animation(Theme.spring, value: assistant.messages.count)
    }

    private func anchor(for message: ChatMessage) -> UnitPoint {
        message.role == .user ? .bottomTrailing : .bottomLeading
    }

    @ViewBuilder
    private var messageList: some View {
        if snapshotMode {
            VStack(spacing: 0) {
                messages
                Spacer(minLength: 0)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    messages.measureHeight($messagesHeight)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.bottom)
                .onChange(of: assistant.messages) {
                    withAnimation(Theme.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var canSend: Bool {
        !assistant.draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Group {
                if snapshotMode {
                    Text(verbatim: L("Ask Momo anything…"))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(
                        text: $assistant.draft, prompt: Text(verbatim: L("Ask Momo anything…")),
                        axis: .vertical
                    ) {
                        Text(verbatim: L("Message"))
                    }
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($isComposerFocused)
                    .onSubmit { send() }
                }
            }
            .font(.system(size: 13.5))
            .padding(.vertical, 10)
            .padding(.leading, 14)

            if let voice, !assistant.isBusy {
                MicrophoneButton(voice: voice)
            }
            if assistant.isBusy {
                Button {
                    assistant.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Theme.cardStrong, in: Circle())
                }
                .buttonStyle(.plain)
                .help(L("Stop"))
                .accessibilityLabel(L("Stop"))
                .padding(4)
                .transition(.scale.combined(with: .opacity))
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canSend ? Color.black.opacity(0.8) : Theme.tertiaryText)
                        .frame(width: 30, height: 30)
                        .background {
                            if canSend {
                                Circle().fill(Theme.userBubble)
                            } else {
                                Circle().fill(Theme.cardStrong)
                            }
                        }
                        .scaleEffect(canSend ? 1 : 0.88)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!canSend)
                .help(L("Send"))
                .accessibilityLabel(L("Send"))
                .padding(4)
                .animation(Theme.quickSpring, value: canSend)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isComposerFocused ? Theme.accent.opacity(0.45) : Color.white.opacity(0.07))
        )
        .animation(Theme.quickSpring, value: isComposerFocused)
        .animation(Theme.quickSpring, value: assistant.isBusy)
    }

    private func send() {
        guard canSend else { return }
        withAnimation(Theme.spring) { assistant.send() }
    }
}

/// Starts and stops dictation, pulsing with the input level while listening.
struct MicrophoneButton: View {
    var voice: VoiceController

    var body: some View {
        Button {
            voice.toggleDictation()
        } label: {
            ZStack {
                if voice.isListening {
                    Circle()
                        .fill(Theme.danger.opacity(0.25))
                        .frame(width: 28 + voice.level * 14, height: 28 + voice.level * 14)
                        .animation(.easeOut(duration: 0.08), value: voice.level)
                }
                Image(systemName: voice.isListening ? "mic.fill" : "mic")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(voice.isListening ? Theme.danger : Theme.secondaryText)
                    .frame(width: 28, height: 28)
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .help(voice.isListening ? L("Stop listening") : L("Speak (⌥⇧Space)"))
        .accessibilityLabel(voice.isListening ? L("Stop listening") : L("Speak"))
        .padding(.vertical, 2)
    }
}

/// Shown instead of suggestions until Momo has a brain to think with.
struct SetUpAICard: View {
    var setUp: () -> Void
    /// Receives the card's natural height, so the panel can fit it.
    @Binding var height: CGFloat
    @State private var engine = FaceEngine()

    var body: some View {
        VStack(spacing: 12) {
            FaceView(engine: engine, layout: FaceLayout(scale: 0.42))
                .frame(height: 70)
                .clipped()
                .allowsHitTesting(false)
                .onAppear { engine.setMood(.sleepy) }
            Text(verbatim: L("Let's give me a brain!"))
                .font(.system(size: 19, weight: .bold, design: .rounded))
            Text(
                verbatim: L(
                    "Connect ChatGPT, Gemini, Claude or a free model on this Mac. It takes about a minute, no Terminal needed."
                )
            )
            .font(.system(size: 13))
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: 300)
            Button(action: setUp) {
                Label(L("Set up AI"), systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.8))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.userBubble, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
        .measureHeight($height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the chat shows before the first message: Momo says hello and offers ideas.
struct EmptyChatView: View {
    /// Receives the view's natural height, so the panel can fit it.
    @Binding var height: CGFloat
    var send: (String) -> Void
    @State private var engine = FaceEngine()

    private var suggestions: [(icon: String, text: String, color: Color)] {
        [
            ("sun.max.fill", L("Plan my day"), Theme.pastels[0]),
            ("checklist", L("What's on my list?"), Theme.pastels[1]),
            ("bell.fill", L("Remind me to drink water at 3 PM"), Theme.pastels[2]),
            ("text.viewfinder", L("What's on my screen?"), Theme.pastels[4]),
        ]
    }

    var body: some View {
        VStack(spacing: 14) {
            FaceView(engine: engine, layout: FaceLayout(scale: 0.42))
                .frame(height: 70)
                .clipped()
                .allowsHitTesting(false)
                .onAppear { engine.flashMood(.happy, for: 1.6) }
            VStack(spacing: 5) {
                Text(verbatim: greeting())
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text(verbatim: L("What can I do for you?"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(suggestions, id: \.text) { suggestion in
                    SuggestionCard(
                        icon: suggestion.icon, text: suggestion.text, color: suggestion.color
                    ) {
                        send(suggestion.text)
                    }
                }
            }
            .padding(.top, 4)
            Text(verbatim: L("Press ⌥Space anywhere to open me."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .measureHeight($height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SuggestionCard: View {
    var icon: String
    var text: String
    var color: Color
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                Text(verbatim: text)
                    .font(.system(size: 12.5, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .padding(11)
            .background(
                isHovering ? Theme.cardStrong : Theme.card,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .scaleEffect(isHovering ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quickSpring) { isHovering = hovering } }
    }
}

/// One message in the conversation. Where an answer came from stays out of the way: it
/// shows when the pointer rests on the answer.
struct MessageRow: View {
    var message: ChatMessage
    var isLatest = false
    @State private var isHovering = false
    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(verbatim: message.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.black.opacity(0.85))
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(
                        Theme.userBubble,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6,
                            topTrailingRadius: 18, style: .continuous))
            }
        case .assistant:
            HStack(alignment: .bottom, spacing: 8) {
                MomoAvatar(isAnimated: isLatest)
                    .padding(.bottom, Self.detailsHeight + 3)
                VStack(alignment: .leading, spacing: 3) {
                    bubble
                    // The line is always there, so pointing at an answer never changes the
                    // conversation's height; its contents just fade in.
                    details
                        .frame(height: Self.detailsHeight)
                        .opacity(isHovering && !message.isStreaming ? 1 : 0)
                }
                Spacer(minLength: 30)
            }
            .onHover { hovering in withAnimation(Theme.quickSpring) { isHovering = hovering } }
        case .error:
            HStack(alignment: .bottom, spacing: 8) {
                MomoAvatar(isAnimated: false)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                    Text(verbatim: message.text)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Theme.danger.opacity(0.14), in: assistantShape)
                Spacer(minLength: 30)
            }
        }
    }

    private var assistantShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18,
            topTrailingRadius: 18, style: .continuous)
    }

    private var runningTools: [ToolActivity] {
        message.activities.filter { $0.state == .running }
    }

    private var failedTools: [ToolActivity] {
        message.activities.filter { $0.state == .failed }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(runningTools + failedTools) { activity in
                ToolActivityRow(activity: activity)
            }
            if message.text.isEmpty && message.isStreaming {
                if runningTools.isEmpty { TypingIndicator() }
            } else if !message.text.isEmpty {
                Text(Self.markdown(message.text))
                    .font(.system(size: 13.5))
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(Theme.card, in: assistantShape)
        .overlay(assistantShape.strokeBorder(Color.white.opacity(0.05)))
    }

    /// Who answered and what Momo did, for the curious.
    private var details: some View {
        HStack(spacing: 6) {
            if let name = message.brainName {
                Circle().fill(Theme.color(for: message.brainKind)).frame(width: 5, height: 5)
                Text(verbatim: name)
            }
            let done = message.activities.filter { $0.state == .succeeded }.map(\.label)
            if !done.isEmpty {
                Text(verbatim: "·")
                Text(verbatim: done.joined(separator: ", ")).lineLimit(1)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help(L("Copy"))
            .accessibilityLabel(L("Copy"))
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(Theme.tertiaryText)
        .padding(.leading, 6)
    }

    /// Room kept under each answer for who answered and what Momo did.
    static let detailsHeight: CGFloat = 14

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
    }
}

/// A tool Momo is using, or one that failed.
struct ToolActivityRow: View {
    var activity: ToolActivity

    var body: some View {
        HStack(spacing: 6) {
            switch activity.state {
            case .running:
                ProgressView().controlSize(.mini)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
            }
            Text(verbatim: activity.label)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Theme.secondaryText)
    }
}

/// Three bouncing dots.
struct TypingIndicator: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    let phase = max(0, sin(time * 6 - Double(index) * 0.7))
                    Circle()
                        .fill(Theme.accent.opacity(0.5 + 0.5 * phase))
                        .frame(width: 6, height: 6)
                        .offset(y: -3 * phase)
                }
            }
            .padding(.vertical, 5)
        }
        .accessibilityLabel(L("Momo is thinking"))
    }
}

/// Asks before a message leaves the Mac.
struct ConsentCard: View {
    var prompt: ConsentPrompt
    var answer: (RemoteConsent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cloud")
                    .foregroundStyle(Theme.color(for: prompt.brain.kind))
                Text(verbatim: String(format: L("Ask %@?"), prompt.brain.name))
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(
                verbatim: prompt.explanation + " "
                    + (prompt.masksData
                        ? L(
                            "Personal details like emails, phone numbers and IDs will be hidden first."
                        )
                        : L("Your message will be sent as written."))
            )
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(L("Ask once")) { answer(.allowOnce) }
                    .buttonStyle(.borderedProminent)
                Button(L("Always in this chat")) { answer(.allowForConversation) }
                Button(L("Stay on this Mac")) { answer(.useLocal) }
                Spacer()
                Button(L("Cancel")) { answer(.cancel) }
                    .buttonStyle(.borderless)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Theme.cardStrong, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Asks before an action that changes something important.
struct ConfirmationCard: View {
    var prompt: ConfirmationPrompt
    var answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised").foregroundStyle(Theme.apiKey)
                Text(verbatim: L("Should I do this?"))
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(verbatim: prompt.summary)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("Allow")) { answer(true) }
                    .buttonStyle(.borderedProminent)
                Button(L("Don't allow")) { answer(false) }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Theme.cardStrong, in: RoundedRectangle(cornerRadius: 14))
    }
}
