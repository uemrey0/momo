import MomoBrain
import MomoKit
import SwiftUI

/// The whole panel: tabs, brain picker and the selected section.
struct PanelView: View {
    @Bindable var assistant: AssistantController
    var today: TodayModel
    var notes: NotesModel
    @Bindable var state: PanelState
    var openSettings: () -> Void
    var close: () -> Void
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.06))
            Group {
                switch state.tab {
                case .chat: ChatView(assistant: assistant, state: state)
                case .today: TodayView(model: today)
                case .notes: NotesView(model: notes)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: ChatPanelController.size.width, height: ChatPanelController.size.height)
        .background(
            ZStack {
                if snapshotMode {
                    Theme.panelBackground
                } else {
                    VisualEffectBackground()
                    Theme.panelBackground.opacity(0.72)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        )
        .environment(\.colorScheme, .dark)
        .tint(Theme.accent)
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(PanelTab.allCases) { tab in
                    Button {
                        state.tab = tab
                    } label: {
                        Text(verbatim: tab.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(
                                state.tab == tab ? Theme.cardStrong : .clear, in: Capsule()
                            )
                            .foregroundStyle(state.tab == tab ? .white : Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            if state.tab == .chat {
                BrainMenu(assistant: assistant)
                IconButton(systemImage: "square.and.pencil", help: L("New conversation")) {
                    assistant.newConversation()
                    state.focusRequest += 1
                }
            }
            IconButton(systemImage: "gearshape", help: L("Settings")) { openSettings() }
            IconButton(systemImage: "xmark", help: L("Close")) { close() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// Lets the user pick a brain for the conversation or leave it automatic.
struct BrainMenu: View {
    @Bindable var assistant: AssistantController
    @Environment(\.snapshotMode) private var snapshotMode

    private var current: ProviderStatus? {
        assistant.providerStatuses.first { $0.id == assistant.forcedProviderID }
    }

    var body: some View {
        if snapshotMode {
            label
        } else {
            menu
        }
    }

    private var label: some View {
        Pill(
            text: current?.info.name ?? L("Automatic"),
            color: Theme.color(for: current?.info.kind), systemImage: "brain")
    }

    private var menu: some View {
        Menu {
            Button {
                assistant.forcedProviderID = nil
            } label: {
                if assistant.forcedProviderID == nil {
                    Label(L("Automatic"), systemImage: "checkmark")
                } else {
                    Text(verbatim: L("Automatic"))
                }
            }
            Divider()
            ForEach(assistant.providerStatuses) { status in
                Button {
                    assistant.forcedProviderID = status.id
                } label: {
                    if assistant.forcedProviderID == status.id {
                        Label(status.info.name, systemImage: "checkmark")
                    } else {
                        Text(verbatim: status.info.name)
                    }
                }
                .disabled(!status.availability.isReady)
            }
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Choose which brain answers"))
    }
}

/// The frosted glass behind the panel.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
