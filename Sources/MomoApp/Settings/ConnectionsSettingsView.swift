import MomoKit
import SwiftUI

/// Connects Momo with other agents in both directions over MCP.
struct ConnectionsSettingsView: View {
    @Bindable var settings: AppSettings
    var model: AppModel
    @State private var name = ""
    @State private var command = ""

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        Form {
            Section {
                MCPSetupView()
                    .settingsAnchor("connections.agents")
            } header: {
                Text(verbatim: L("Use Momo from Claude, Codex and other agents"))
            }

            Section {
                ForEach($settings.preferences.mcpServers) { $server in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Toggle(isOn: $server.isEnabled) {
                                Text(verbatim: server.name)
                            }
                            Spacer()
                            status(for: server.id)
                            Button(role: .destructive) {
                                settings.preferences.mcpServers.removeAll { $0.id == server.id }
                                refresh()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L("Remove"))
                        }
                        Text(verbatim: ([server.command] + server.arguments).joined(separator: " "))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Toggle(L("Ask before using its tools"), isOn: $server.asksBeforeUse)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L("Name"), text: $name, prompt: Text(verbatim: "github"))
                    TextField(
                        L("Command"), text: $command,
                        prompt: Text(verbatim: "npx -y @modelcontextprotocol/server-github"))
                    Button(L("Add server")) { add() }
                        .disabled(name.isEmpty || command.isEmpty)
                }
                .textFieldStyle(.roundedBorder)
                .settingsAnchor("connections.servers")
            } header: {
                Text(verbatim: L("MCP servers Momo can use"))
            } footer: {
                Text(
                    verbatim: L(
                        "Momo starts these servers on your Mac and offers their tools to its brains. Only add servers you trust."
                    ))
            }

            WebSearchSection(settings: settings)
        }
        .formStyle(.grouped)
        .onChange(of: settings.preferences.mcpServers) { refresh() }
    }

    @ViewBuilder
    private func status(for id: UUID) -> some View {
        switch model.connections.statuses[id] {
        case .connecting:
            ProgressView().controlSize(.small)
        case .connected(let count):
            Text(verbatim: String(format: L("%lld tools"), count))
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(message)
        case nil:
            EmptyView()
        }
    }

    private func add() {
        var parts = command.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return }
        let executable = parts.removeFirst()
        settings.preferences.mcpServers.append(
            MCPServerConfiguration(
                name: name.trimmingCharacters(in: .whitespaces), command: executable,
                arguments: parts))
        name = ""
        command = ""
    }

    private func refresh() {
        Task { await model.connections.refresh() }
    }
}

/// The optional Brave Search key for web searches.
struct WebSearchSection: View {
    var settings: AppSettings
    @State private var key = ""
    @State private var saved = false
    @State private var problem: String?

    private var storedKey: String { settings.keys.key(for: WebSearcher.braveKeyID) ?? "" }

    var body: some View {
        Section {
            HStack {
                SecureField(L("Brave Search API key"), text: $key)
                Button(saved ? L("Saved") : L("Save")) {
                    do {
                        try settings.keys.setKey(key, for: WebSearcher.braveKeyID)
                    } catch {
                        problem = error.localizedDescription
                        return
                    }
                    problem = nil
                    saved = true
                }
                .disabled(key == storedKey)
            }
            .settingsAnchor("connections.webSearch")
            if let problem {
                Text(verbatim: problem).foregroundStyle(.red).font(.caption)
            }
            if let url = URL(string: "https://api-dashboard.search.brave.com/") {
                Link(L("Get a Brave Search API key"), destination: url).font(.caption)
            }
        } header: {
            Text(verbatim: L("Web search"))
        } footer: {
            Text(
                verbatim: L(
                    "Momo searches the web with DuckDuckGo, no key needed. With a Brave Search API key it uses Brave instead. The key is stored in your macOS Keychain and only sent to Brave."
                ))
        }
        .onAppear { key = storedKey }
        .onChange(of: key) { saved = false }
    }
}

/// The things Momo reacts to, with a pointer to Permissions when calendar access is off.
struct ReactionsSection: View {
    @Bindable var settings: AppSettings
    var calendar: CalendarService
    var openPermissions: (MacPermission?) -> Void
    @State private var calendarAllowed = true

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(L("Remind me before meetings"), isOn: $settings.preferences.reactsToCalendar)
                if settings.preferences.reactsToCalendar && !calendarAllowed {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(verbatim: L("Calendar access is off."))
                            .foregroundStyle(.secondary)
                        Button(L("Open Permissions")) { openPermissions(.calendars) }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                }
            }
            .settingsAnchor("reactions.calendar")
            Toggle(L("Dance along when music plays"), isOn: $settings.preferences.reactsToMusic)
                .settingsAnchor("reactions.music")
            Toggle(L("Worry when the battery is low"), isOn: $settings.preferences.reactsToBattery)
                .settingsAnchor("reactions.battery")
            Toggle(L("Yawn when it gets very late"), isOn: $settings.preferences.reactsToLateNight)
                .settingsAnchor("reactions.lateNight")
        } header: {
            Text(verbatim: L("Reactions"))
        } footer: {
            Text(
                verbatim: L(
                    "Calendar access lets Momo plan your day and nudge you before events. Google and Outlook calendars work once added in System Settings → Internet Accounts."
                ))
        }
        .onAppear { calendarAllowed = calendar.isAuthorized }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            calendarAllowed = calendar.isAuthorized
        }
    }
}
