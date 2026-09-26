import MomoKit
import SwiftUI

/// Past conversations, newest first, with search. Opening one continues it.
struct HistoryView: View {
    @Bindable var assistant: AssistantController
    @Bindable var state: PanelState
    @State private var query = ""
    @State private var conversations: [Conversation] = []
    @State private var hasLoaded = false
    @State private var searchHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0
    @FocusState private var isSearchFocused: Bool

    private var preferredHeight: CGFloat {
        guard searchHeight > 0, listHeight > 0 else { return 0 }
        return searchHeight + listHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .fixedSize(horizontal: false, vertical: true)
                .measureHeight($searchHeight)
            PanelScroll {
                list
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                    .measureHeight($listHeight)
            }
        }
        .preference(key: PanelHeightKey.self, value: preferredHeight)
        .task(id: "\(query)\u{0}\(assistant.conversationsVersion)") {
            // Waits a moment while the user is typing, then searches.
            if hasLoaded { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let found = await assistant.conversations(matching: query)
            guard !Task.isCancelled else { return }
            withAnimation(hasLoaded ? Theme.quickSpring : nil) { conversations = found }
            hasLoaded = true
        }
        .onAppear { isSearchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                TextField(
                    text: $query, prompt: Text(verbatim: L("Search conversations"))
                ) {
                    Text(verbatim: L("Search conversations"))
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)
                .onSubmit {
                    if let first = conversations.first { open(first) }
                }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help(L("Clear"))
                    .accessibilityLabel(L("Clear"))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button {
                withAnimation(Theme.spring) {
                    assistant.newConversation()
                    state.showsHistory = false
                }
                state.focusRequest += 1
            } label: {
                Label(L("New"), systemImage: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.8))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Theme.userBubble, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(L("New conversation"))
        }
    }

    @ViewBuilder
    private var list: some View {
        if !hasLoaded {
            Color.clear.frame(height: 120)
        } else if conversations.isEmpty {
            VStack(spacing: 8) {
                Image(
                    systemName: query.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass"
                )
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                Text(
                    verbatim: query.isEmpty
                        ? L("Your conversations will show up here.")
                        : L("No conversation matches your search.")
                )
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        } else {
            LazyVStack(spacing: 2) {
                ForEach(conversations) { conversation in
                    ConversationRow(
                        conversation: conversation,
                        isCurrent: conversation.id == assistant.conversationID,
                        open: { open(conversation) },
                        delete: {
                            withAnimation(Theme.quickSpring) {
                                conversations.removeAll { $0.id == conversation.id }
                            }
                            assistant.deleteConversation(id: conversation.id)
                        })
                }
            }
        }
    }

    private func open(_ conversation: Conversation) {
        withAnimation(Theme.spring) {
            assistant.openConversation(conversation)
            state.showsHistory = false
        }
        state.focusRequest += 1
    }
}

/// One past conversation: its title, how it ended and when. Deleting asks once more.
private struct ConversationRow: View {
    var conversation: Conversation
    var isCurrent: Bool
    var open: () -> Void
    var delete: () -> Void
    @State private var isHovering = false
    @State private var confirmingDelete = false

    /// The last thing said, on one line.
    private var snippet: String {
        let last = conversation.messages.last { $0.role != .error }?.text ?? ""
        return last.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.pastel(for: conversation.id))
                        .frame(width: 26, height: 26)
                        .background(
                            Theme.pastel(for: conversation.id).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: conversation.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Text(verbatim: snippet)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if !isHovering && !confirmingDelete {
                        Text(conversation.updatedAt, format: .relative(presentation: .named))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isHovering || confirmingDelete {
                deleteButton.transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            isCurrent ? Theme.cardStrong : (isHovering ? Theme.card : .clear),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .onHover { hovering in
            withAnimation(Theme.quickSpring) {
                isHovering = hovering
                if !hovering { confirmingDelete = false }
            }
        }
        .contextMenu {
            Button(L("Open"), action: open)
            Button(L("Delete"), role: .destructive, action: delete)
        }
    }

    @ViewBuilder
    private var deleteButton: some View {
        if confirmingDelete {
            Button(action: delete) {
                Text(verbatim: L("Delete"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.danger.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(L("Delete this conversation"))
        } else {
            IconButton(systemImage: "trash", help: L("Delete this conversation")) {
                withAnimation(Theme.quickSpring) { confirmingDelete = true }
            }
        }
    }
}
