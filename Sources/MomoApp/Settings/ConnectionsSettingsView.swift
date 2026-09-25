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
            } header: {
                Text(verbatim: L("MCP servers Momo can use"))
            } footer: {
                Text(
                    verbatim: L(
                        "Momo starts these servers on your Mac and offers their tools to its brains. Only add servers you trust."
                    ))
            }
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

/// Calendar access and the things Momo reacts to.
struct ReactionsSection: View {
    @Bindable var settings: AppSettings
    var calendar: CalendarService
    @State private var calendarAllowed = false

    var body: some View {
        Section {
            HStack {
                Toggle(L("Remind me before meetings"), isOn: $settings.preferences.reactsToCalendar)
                Spacer()
                if !calendarAllowed {
                    Button(L("Allow calendar access")) {
                        Task { calendarAllowed = await calendar.requestAccess() }
                    }
                    .controlSize(.small)
                }
            }
            Toggle(L("Dance along when music plays"), isOn: $settings.preferences.reactsToMusic)
            Toggle(L("Worry when the battery is low"), isOn: $settings.preferences.reactsToBattery)
            Toggle(L("Yawn when it gets very late"), isOn: $settings.preferences.reactsToLateNight)
        } header: {
            Text(verbatim: L("Reactions"))
        } footer: {
            Text(
                verbatim: L(
                    "Calendar access lets Momo plan your day and nudge you before events. Google and Outlook calendars work once added in System Settings → Internet Accounts."
                ))
        }
        .onAppear { calendarAllowed = calendar.isAuthorized }
    }
}
