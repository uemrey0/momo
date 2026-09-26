import MomoBrain
import MomoKit
import SwiftUI

/// The conversation with Momo.
struct ChatView: View {
    @Bindable var assistant: AssistantController
    @Bindable var state: PanelState
    var voice: VoiceController? = nil
    var setUpAI: () -> Void = {}
    @FocusState private var isComposerFocused: Bool

    /// Whether the brains were checked and none of them can answer yet.
    private var needsAISetup: Bool {
        !assistant.providerStatuses.isEmpty
            && !assistant.providerStatuses.contains { $0.availability.isReady }
    }
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        VStack(spacing: 0) {
            if assistant.messages.isEmpty && needsAISetup {
                SetUpAICard(setUp: setUpAI)
            } else if assistant.messages.isEmpty {
                EmptyChatView { suggestion in assistant.send(suggestion) }
            } else {
                messageList
            }
            if let prompt = assistant.consentPrompt {
                ConsentCard(prompt: prompt) { assistant.answerConsent($0) }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let prompt = assistant.confirmationPrompt {
                ConfirmationCard(prompt: prompt) { assistant.answerConfirmation($0) }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            composer
        }
        .animation(.spring(duration: 0.3), value: assistant.consentPrompt)
        .animation(.spring(duration: 0.3), value: assistant.confirmationPrompt)
        .onChange(of: state.focusRequest, initial: true) { isComposerFocused = true }
    }

    @ViewBuilder
    private var messageList: some View {
        if snapshotMode {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(assistant.messages) { MessageRow(message: $0) }
                Spacer(minLength: 0)
            }
            .padding(14)
        } else {
            scrollingMessageList
        }
    }

    private var scrollingMessageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(assistant.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
            .onChange(of: assistant.messages) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
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
                    .onSubmit { assistant.send() }
                }
            }
            .font(.system(size: 13.5))
            .padding(.vertical, 9)
            .padding(.leading, 12)

            if let voice, !assistant.isBusy {
                MicrophoneButton(voice: voice)
            }
            if assistant.isBusy {
                Button {
                    assistant.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Theme.cardStrong, in: Circle())
                }
                .buttonStyle(.plain)
                .help(L("Stop"))
                .accessibilityLabel(L("Stop"))
                .padding(4)
            } else {
                Button {
                    assistant.send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 28, height: 28)
                        .background(
                            assistant.draft.isEmpty ? Theme.tertiaryText : Theme.accent,
                            in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(assistant.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(L("Send"))
                .accessibilityLabel(L("Send"))
                .padding(4)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(isComposerFocused ? 0.16 : 0.06))
        )
        .padding(12)
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

/// What the chat shows before the first message.
/// Shown instead of suggestions until Momo has a brain to think with.
struct SetUpAICard: View {
    var setUp: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(verbatim: L("Let's give me a brain!"))
                .font(.system(size: 18, weight: .bold, design: .rounded))
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
                Label(L("Set up AI"), systemImage: "arrow.right.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

struct EmptyChatView: View {
    var send: (String) -> Void

    private var suggestions: [(icon: String, text: String)] {
        [
            ("sun.max", L("Plan my day")),
            ("checklist", L("What's on my list?")),
            ("bell", L("Remind me to drink water at 3 PM")),
            ("text.viewfinder", L("What's on my screen?")),
        ]
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            VStack(spacing: 6) {
                Text(verbatim: L("Hi! What can I do for you?"))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(
                    verbatim: L(
                        "I can keep your tasks, notes and habits, remember things and answer questions."
                    )
                )
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            }
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.text) { suggestion in
                    Button {
                        send(suggestion.text)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: suggestion.icon)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 18)
                            Text(verbatim: suggestion.text)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 320)
            Spacer()
            Text(verbatim: L("Press ⌥Space anywhere to open me."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

/// One message in the conversation.
struct MessageRow: View {
    var message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 50)
                Text(verbatim: message.text)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Theme.accent.opacity(0.22),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 7) {
                if let name = message.brainName {
                    Pill(text: name, color: Theme.color(for: message.brainKind))
                }
                ForEach(message.activities) { activity in
                    ToolActivityRow(activity: activity)
                }
                if message.text.isEmpty && message.isStreaming {
                    TypingIndicator()
                } else if !message.text.isEmpty {
                    Text(Self.markdown(message.text))
                        .font(.system(size: 13.5))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                Text(verbatim: message.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }

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

/// A tool Momo is using or used.
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
                    Circle()
                        .fill(Theme.secondaryText)
                        .frame(width: 6, height: 6)
                        .offset(y: -3 * max(0, sin(time * 6 - Double(index) * 0.7)))
                }
            }
            .padding(.vertical, 4)
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
