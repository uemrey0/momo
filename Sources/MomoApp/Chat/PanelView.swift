import MomoBrain
import MomoKit
import SwiftUI

/// The whole panel: a small header with the sections, and the selected section. The panel
/// grows and shrinks with its content.
struct PanelView: View {
    @Bindable var assistant: AssistantController
    var today: TodayModel
    var notes: NotesModel
    @Bindable var state: PanelState
    var voice: VoiceController? = nil
    var openSettings: (SettingsPane?) -> Void
    var close: () -> Void
    /// Called with the height the panel would like, header included.
    var resize: (CGFloat) -> Void = { _ in }
    @Environment(\.snapshotMode) private var snapshotMode
    @State private var appeared = true

    static let headerHeight: CGFloat = 50

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                switch state.tab {
                case .chat:
                    ChatView(
                        assistant: assistant, state: state, voice: voice,
                        setUpAI: { openSettings(.ai) }
                    )
                    .transition(tabTransition)
                case .today:
                    TodayView(model: today).transition(tabTransition)
                case .notes:
                    NotesView(model: notes).transition(tabTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .frame(width: ChatPanelController.size.width)
        .frame(
            height: snapshotMode ? ChatPanelController.size.height : state.layoutHeight,
            alignment: .top
        )
        .background(
            ZStack {
                if snapshotMode {
                    Theme.panelBackground
                } else {
                    VisualEffectBackground()
                    Theme.panelBackground.opacity(0.74)
                }
            }
        )
        .clipShape(PanelShape(visibleHeight: state.visibleHeight))
        .overlay(
            PanelShape(visibleHeight: state.visibleHeight)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .scaleEffect(appeared ? 1 : 0.94, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .tint(Theme.accent)
        .animation(Theme.spring, value: state.tab)
        .onPreferenceChange(PanelHeightKey.self) { height in
            // Zero means the section hasn't measured itself yet.
            if height > 0 { resize(Self.headerHeight + height) }
        }
        .onChange(of: state.presentations) {
            // Drops out of the notch each time the panel opens.
            appeared = false
            withAnimation(Theme.spring) { appeared = true }
        }
    }

    private var tabTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity)
    }

    private var header: some View {
        HStack(spacing: 6) {
            TabSwitcher(selection: $state.tab)
            Spacer()
            if state.tab == .chat && !assistant.messages.isEmpty {
                IconButton(systemImage: "square.and.pencil", help: L("New conversation")) {
                    withAnimation(Theme.spring) { assistant.newConversation() }
                    state.focusRequest += 1
                }
                .transition(.scale.combined(with: .opacity))
            }
            PanelMenu(assistant: assistant, openSettings: { openSettings(nil) }, close: close)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.headerHeight)
        .animation(Theme.quickSpring, value: assistant.messages.isEmpty)
    }
}

/// The section switcher: icons with names and a sliding highlight.
private struct TabSwitcher: View {
    @Binding var selection: PanelTab
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                        Text(verbatim: tab.title)
                    }
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background {
                        if selection == tab {
                            Capsule()
                                .fill(Theme.cardStrong)
                                .matchedGeometryEffect(id: "tab", in: highlight)
                        }
                    }
                    .foregroundStyle(selection == tab ? .white : Theme.secondaryText)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.card, in: Capsule())
    }
}

/// Everything that isn't needed all the time: which brain answers, Settings and closing.
private struct PanelMenu: View {
    @Bindable var assistant: AssistantController
    var openSettings: () -> Void
    var close: () -> Void
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        if snapshotMode {
            icon
        } else {
            Menu {
                Picker(selection: $assistant.forcedProviderID) {
                    Text(verbatim: L("Automatic")).tag(String?.none)
                    ForEach(assistant.providerStatuses.filter(\.availability.isReady)) { status in
                        Text(verbatim: status.info.name).tag(Optional(status.id))
                    }
                } label: {
                    Text(verbatim: L("Who answers"))
                }
                .pickerStyle(.inline)
                Divider()
                Button(L("Settings…"), action: openSettings)
                Button(L("Close"), action: close)
            } label: {
                icon
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("More"))
        }
    }

    private var icon: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(assistant.forcedProviderID == nil ? Theme.secondaryText : Theme.accent)
            .frame(width: 28, height: 28)
            .background(Theme.card, in: Circle())
            .contentShape(Circle())
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
