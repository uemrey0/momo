import MomoBrain
import ServiceManagement
import SwiftUI

/// The sections of the Settings window, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case ai, abilities, character, voice, reactions, routines, connections, permissions, privacy,
        general,
        about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ai: L("AI")
        case .abilities: L("Abilities")
        case .character: L("Character")
        case .voice: L("Voice")
        case .reactions: L("Reactions")
        case .routines: L("Routines")
        case .connections: L("Connections")
        case .permissions: L("Permissions")
        case .privacy: L("Privacy")
        case .general: L("General")
        case .about: L("About")
        }
    }

    var systemImage: String {
        switch self {
        case .ai: "sparkles"
        case .abilities: "wand.and.stars"
        case .character: "face.smiling"
        case .voice: "waveform"
        case .reactions: "bell.badge"
        case .routines: "clock.arrow.circlepath"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .permissions: "lock.shield.fill"
        case .privacy: "hand.raised.fill"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .ai: Color(red: 0.55, green: 0.42, blue: 0.98)
        case .abilities: Color(red: 0.95, green: 0.45, blue: 0.7)
        case .character: Color(red: 0.2, green: 0.74, blue: 0.62)
        case .voice: Color(red: 0.98, green: 0.36, blue: 0.47)
        case .reactions: Color(red: 1.0, green: 0.6, blue: 0.2)
        case .routines: Color(red: 0.36, green: 0.7, blue: 0.95)
        case .connections: Color(red: 0.25, green: 0.55, blue: 0.98)
        case .permissions: Color(red: 0.2, green: 0.62, blue: 0.4)
        case .privacy: Color(red: 0.3, green: 0.5, blue: 0.9)
        case .general: .gray
        case .about: Color(red: 0.45, green: 0.47, blue: 0.52)
        }
    }

    /// Words that find this pane in the sidebar search, besides its title.
    var keywords: String {
        switch self {
        case .ai:
            L(
                "brain, model, ChatGPT, Gemini, Claude, OpenAI, Ollama, LM Studio, Apple Intelligence, API key, subscription"
            )
        case .abilities:
            L(
                "tools, what Momo can do, turn off, always ask, confirm, tasks, notes, calendar, reminders, files, mail, messages, contacts, music, system, web search, weather, screen, AppleScript, shell, meetings, routines, MCP"
            )
        case .character: L("look, appearance, skin, theme, custom")
        case .voice: L("speech, microphone, read aloud, Hey Momo, wake word, dictation")
        case .reactions: L("calendar, meetings, music, battery, late night, sleep, doze")
        case .routines: L("schedule, automation, every day, morning brief, recurring prompt")
        case .connections: L("MCP, server, tools, agents, Claude Code, Claude Desktop")
        case .permissions:
            L(
                "access, allow, denied, privacy, microphone, calendar, reminders, contacts, screen recording, accessibility, automation, notifications, location, System Settings"
            )
        case .privacy: L("data, personal details, screen, log, erase, local only")
        case .general: L("personality, shortcut, login, updates, welcome tour")
        case .about: L("version, license, website, report a problem")
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(query)
            || keywords.localizedCaseInsensitiveContains(query)
    }
}

/// Which Settings pane is showing, so other parts of the app can open a specific one.
@MainActor
@Observable
final class SettingsNavigation {
    var pane: SettingsPane = .ai
    /// The AI option whose setup sheet is open.
    var setupOption: BrainOption?
    /// The setting that is briefly highlighted, by its ``View/settingsAnchor(_:)`` id.
    var highlight: String?
    /// Changes with every request to show a setting, so the same one can be shown again.
    private(set) var highlightRequest = 0

    /// Opens `pane`, scrolls to the setting with the anchor `id` and highlights it.
    func show(_ pane: SettingsPane, highlighting id: String?) {
        self.pane = pane
        highlight = id
        highlightRequest += 1
    }
}

/// The Settings window: a sidebar of panes, like System Settings.
struct SettingsView: View {
    var model: AppModel
    @Bindable var navigation: SettingsNavigation
    @State private var search = ""

    init(model: AppModel) {
        self.model = model
        self.navigation = model.settingsNavigation
    }

    private var selection: Binding<SettingsPane?> {
        Binding {
            navigation.pane
        } set: {
            if let pane = $0 { navigation.pane = pane }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(SettingsPane.allCases.filter { $0.matches(search) }) { pane in
                    NavigationLink(value: pane) {
                        SettingsPaneLabel(pane: pane, badge: badge(for: pane))
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: Text(verbatim: L("Search")))
            .onSubmit(of: .search) {
                if let first = SettingsPane.allCases.first(where: { $0.matches(search) }) {
                    navigation.pane = first
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            ScrollViewReader { proxy in
                detail
                    .navigationTitle(navigation.pane.title)
                    .environment(navigation)
                    .task(id: navigation.highlightRequest) { await reveal(with: proxy) }
            }
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.pane {
        case .ai: AISettingsView(model: model)
        case .abilities: AbilitiesSettingsView(model: model)
        case .character: CharacterSettingsView(model: model)
        case .voice: VoiceSettingsView(model: model)
        case .reactions: ReactionsSettingsView(model: model)
        case .routines: RoutinesSettingsView(model: model)
        case .connections: ConnectionsSettingsView(model: model)
        case .permissions: PermissionsSettingsView(model: model)
        case .privacy: PrivacySettingsView(model: model)
        case .general: GeneralSettingsView(model: model)
        case .about: AboutView()
        }
    }

    /// Scrolls to the highlighted setting once its pane is laid out, then lets the highlight
    /// fade.
    private func reveal(with proxy: ScrollViewProxy) async {
        guard let id = navigation.highlight else { return }
        try? await Task.sleep(for: .milliseconds(250))
        withAnimation { proxy.scrollTo(id, anchor: .center) }
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, navigation.highlight == id else { return }
        navigation.highlight = nil
    }

    /// A reminder in the sidebar when something needs attention.
    private func badge(for pane: SettingsPane) -> String? {
        guard pane == .ai, !model.assistant.providerStatuses.isEmpty,
            !model.assistant.providerStatuses.contains(where: { $0.availability.isReady })
        else { return nil }
        return L("Set up")
    }
}

/// A sidebar row with a coloured icon, like System Settings.
private struct SettingsPaneLabel: View {
    var pane: SettingsPane
    var badge: String?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: pane.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
            Text(verbatim: pane.title)
            Spacer(minLength: 0)
            if let badge {
                Text(verbatim: badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
            }
        }
    }
}

/// When Momo dozes off and what it reacts to.
struct ReactionsSettingsView: View {
    @Bindable var settings: AppSettings
    var model: AppModel

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        Form {
            ReactionsSection(settings: settings, calendar: model.calendar)
            Section {
                LabeledContent(L("Doze off after")) {
                    HStack {
                        Slider(value: $settings.preferences.sleepDelayMinutes, in: 1...15, step: 1)
                            .frame(width: 180)
                        Text(
                            verbatim: String(
                                format: L("%lld min"), Int(settings.preferences.sleepDelayMinutes))
                        )
                        .monospacedDigit()
                        .frame(width: 60, alignment: .leading)
                    }
                }
                .onChange(of: settings.preferences.sleepDelayMinutes) { model.applyPreferences() }
            } header: {
                Text(verbatim: L("Sleep"))
            } footer: {
                Text(
                    verbatim: L(
                        "Momo falls asleep when you step away and wakes up when you're back."))
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings
    var model: AppModel
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        Form {
            Section {
                Picker(L("Personality"), selection: $settings.preferences.personality) {
                    ForEach(Personality.allCases) { personality in
                        Text(verbatim: personality.displayName).tag(personality)
                    }
                }
            }
            Section {
                LabeledContent(L("Open Momo")) {
                    Text(verbatim: "⌥ Space").font(.system(.body, design: .monospaced))
                }
                Toggle(L("Open at login"), isOn: $launchesAtLogin)
                    .onChange(of: launchesAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchesAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section {
                Toggle(
                    L("Check for updates automatically"),
                    isOn: $settings.preferences.checksForUpdates)
                Button(L("Check now")) { Task { await model.updates.check() } }
                if let update = model.updates.availableUpdate {
                    Button(String(format: L("Update to Momo %@…"), update.version)) {
                        model.updates.openReleasePage()
                    }
                }
            } footer: {
                Text(
                    verbatim: L(
                        "Momo asks GitHub once a day whether a new version is out. Nothing else is sent."
                    ))
            }
            Section {
                Button(L("Show the welcome tour again")) { model.showOnboarding() }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "face.smiling.inverse")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
            Text(verbatim: "Momo").font(.system(size: 28, weight: .bold, design: .rounded))
            Text(verbatim: String(format: L("Version %@"), version)).foregroundStyle(.secondary)
            Text(verbatim: L("A tiny, living companion for your Mac. Free and open source."))
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link(L("Website"), destination: URL(literal: "https://github.com/uemrey0/momo"))
                Link(
                    L("Report a problem"),
                    destination: URL(literal: "https://github.com/uemrey0/momo/issues/new/choose"))
            }
            Spacer()
            Text(verbatim: L("Licensed under the Apache License 2.0."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

extension URL {
    /// Creates a URL from a literal that is known to be valid.
    init(literal: StaticString) {
        guard let url = URL(string: "\(literal)") else {
            preconditionFailure("Invalid URL literal: \(literal)")
        }
        self = url
    }
}
