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

/// Explains how to connect Momo's MCP server to other agents.
struct MCPSetupView: View {
    private var serverPath: String {
        AppSettings.mcpServerPath ?? "/Applications/Momo.app/Contents/MacOS/momo-mcp"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                verbatim: L(
                    "Momo includes an MCP server, so agents you already use can read and update your tasks, notes, habits and memories. Claude Code:"
                )
            )
            .foregroundStyle(.secondary)
            CommandSnippet(command: "claude mcp add momo -- \"\(serverPath)\"")
            Text(
                verbatim: L(
                    "Claude Desktop: add this to claude_desktop_config.json under “mcpServers”:")
            )
            .foregroundStyle(.secondary)
            CommandSnippet(command: "\"momo\": { \"command\": \"\(serverPath)\" }")
        }
    }
}
