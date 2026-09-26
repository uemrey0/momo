import MomoKit
import SwiftUI

/// Privacy controls, the outbound log and data management.
struct PrivacySettingsView: View {
    @Bindable var settings: AppSettings
    var model: AppModel
    @State private var confirmingErase = false

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        Form {
            Section {
                Toggle(
                    L("Keep everything on this Mac"), isOn: $settings.preferences.brains.localOnly)
                Toggle(
                    L("Hide personal details from remote brains"),
                    isOn: $settings.preferences.brains.masksPersonalData)
            } footer: {
                Text(
                    verbatim: L(
                        "When hiding is on, emails, phone numbers, IBANs, card numbers, ID numbers and names are replaced with placeholders before a message leaves your Mac, and put back in the answer."
                    ))
            }

            Section {
                LabeledContent(L("Screen reading")) {
                    if ScreenReader.hasPermission {
                        Text(verbatim: L("Allowed")).foregroundStyle(.secondary)
                    } else {
                        Button(L("Allow…")) { ScreenReader.requestPermission() }
                    }
                }
            } footer: {
                Text(
                    verbatim: L(
                        "Momo only looks at your screen when you ask it to, and always asks first. The text is read on your Mac."
                    ))
            }

            Section {
                if model.assistant.outboundLog.isEmpty {
                    Text(verbatim: L("Nothing has left this Mac yet."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.assistant.outboundLog.prefix(30)) { record in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(verbatim: record.brainName)
                                Text(record.date, format: .dateTime.day().month().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(
                                verbatim: String(format: L("%lld characters"), record.characters)
                            )
                            .font(.caption)
                            .monospacedDigit()
                            Image(systemName: record.masked ? "eye.slash" : "eye")
                                .foregroundStyle(record.masked ? .green : .orange)
                                .help(
                                    record.masked
                                        ? L("Personal details hidden") : L("Sent as written"))
                        }
                    }
                    Button(L("Clear log")) { model.assistant.clearOutboundLog() }
                }
            } header: {
                Text(verbatim: L("Sent to remote brains"))
            }

            Section {
                Button(L("Erase all of Momo's data…"), role: .destructive) {
                    confirmingErase = true
                }
                .confirmationDialog(
                    L("Erase all tasks, notes, habits and memories?"),
                    isPresented: $confirmingErase
                ) {
                    Button(L("Erase everything"), role: .destructive) {
                        Task {
                            try? await model.store.eraseAll()
                            model.assistant.clearOutboundLog()
                            model.assistant.newConversation()
                        }
                    }
                } message: {
                    Text(verbatim: L("This can't be undone."))
                }
            } footer: {
                Text(
                    verbatim: String(
                        format: L("Your data lives in %@."),
                        MomoStore.defaultFileURL.deletingLastPathComponent().path))
            }
        }
        .formStyle(.grouped)
    }
}

/// Connects Momo's MCP server to agents the user already has, with one click each.
struct MCPSetupView: View {
    @State private var linked: Set<AgentLink> = []
    @State private var working: AgentLink?
    @State private var failed: AgentLink?
    @State private var showsDetails = false

    private var serverPath: String? { AppSettings.mcpServerPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                verbatim: L(
                    "Agents you already use can read and update your tasks, notes, habits and memories through Momo."
                )
            )
            .foregroundStyle(.secondary)
            ForEach(AgentLink.allCases.filter(\.isInstalled)) { agent in
                HStack {
                    Text(verbatim: agent.name)
                    Spacer()
                    if linked.contains(agent) {
                        Label(L("Connected"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if working == agent {
                        ProgressView().controlSize(.small)
                    } else {
                        if failed == agent {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(
                                    L(
                                        "That didn't work. Use the details below to add Momo by hand."
                                    ))
                        }
                        Button(String(format: L("Add to %@"), agent.name)) { link(agent) }
                            .disabled(serverPath == nil)
                    }
                }
            }
            if linked.contains(.claudeDesktop) {
                Text(verbatim: L("Restart Claude Desktop to see Momo's tools."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if serverPath == nil {
                Text(verbatim: L("Available when Momo runs from the Applications folder."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: L("For other agents, add an MCP server with this command:"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    CommandSnippet(
                        command: serverPath ?? "/Applications/Momo.app/Contents/MacOS/momo-mcp")
                }
            } label: {
                Text(verbatim: L("Other agents")).font(.callout)
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        var result: Set<AgentLink> = []
        for agent in AgentLink.allCases where agent.isInstalled {
            if await agent.isLinked() { result.insert(agent) }
        }
        linked = result
    }

    private func link(_ agent: AgentLink) {
        guard let serverPath else { return }
        working = agent
        failed = nil
        Task {
            let succeeded = await agent.link(serverPath: serverPath)
            working = nil
            if succeeded { linked.insert(agent) } else { failed = agent }
        }
    }
}
