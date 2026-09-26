import AppKit
import MomoKit
import SwiftUI

/// What Momo can do: every group of tools, with switches to turn it off or have Momo ask
/// first, and the permissions each group needs.
struct AbilitiesSettingsView: View {
    @Bindable var settings: AppSettings
    var model: AppModel

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        Form {
            Section {
                ForEach(ToolGroup.visible) { group in
                    AbilityRow(group: group, settings: settings, model: model)
                }
            } footer: {
                Text(
                    verbatim: L(
                        "Momo never offers a turned-off ability to any brain. With “Always ask first”, it asks you before each use. Tap a permission to check it."
                    ))
            }
            MCPAbilitiesSection(settings: settings, model: model)
        }
        .formStyle(.grouped)
        .task { await model.permissions.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await model.permissions.refresh() }
        }
    }
}

/// One group of tools.
private struct AbilityRow: View {
    var group: ToolGroup
    @Bindable var settings: AppSettings
    var model: AppModel

    private var isEnabled: Binding<Bool> {
        Binding {
            settings.preferences.abilities.isEnabled(group)
        } set: {
            settings.preferences.abilities.setEnabled(group, $0)
        }
    }

    private var alwaysAsks: Binding<Bool> {
        Binding {
            settings.preferences.abilities.alwaysAsks(group)
        } set: {
            settings.preferences.abilities.setAlwaysAsks(group, $0)
        }
    }

    /// The permissions to show: Automation only for apps that are installed.
    private var permissions: [MacPermission] {
        let installed = Set(model.permissions.automationTargets.map(\.bundleIdentifier))
        return group.permissions.filter { permission in
            guard case .automation(let bundleIdentifier?) = permission else { return true }
            return installed.contains(bundleIdentifier)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: isEnabled) {
                HStack(spacing: 10) {
                    Image(systemName: group.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(group.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: group.title)
                        Text(verbatim: group.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if settings.preferences.abilities.isEnabled(group) {
                HStack(spacing: 6) {
                    Toggle(L("Always ask first"), isOn: alwaysAsks)
                        .toggleStyle(.checkbox)
                        .disabled(group.alwaysAsks)
                    Spacer(minLength: 8)
                    ForEach(permissions, id: \.self) { permission in
                        PermissionChip(permission: permission, model: model)
                    }
                }
                .controlSize(.small)
                .padding(.leading, 34)
            }
        }
        .padding(.vertical, 2)
        .settingsAnchor("abilities." + group.id)
    }
}

/// A permission a group needs, with its status; opens it in the Permissions pane.
private struct PermissionChip: View {
    var permission: MacPermission
    var model: AppModel

    private var name: String {
        if case .automation(let bundleIdentifier?) = permission,
            let target = AutomationTarget.all.first(where: { $0.id == bundleIdentifier })
        {
            return target.name
        }
        return permission.title
    }

    var body: some View {
        let status = model.permissions.status(permission)
        Button {
            model.openPermissions(permission)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: status.chipImage)
                    .foregroundStyle(status.chipColor)
                Text(verbatim: name)
            }
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(String(format: L("Needs %@. Click to check it in Permissions."), permission.title))
    }
}

extension PermissionStatus {
    fileprivate var chipImage: String {
        switch self {
        case .allowed: "checkmark.circle.fill"
        case .denied: "exclamationmark.triangle.fill"
        case .notDetermined, .unknown: "lock.fill"
        }
    }

    fileprivate var chipColor: Color {
        switch self {
        case .allowed: .green
        case .denied: .orange
        case .notDetermined, .unknown: .secondary
        }
    }
}

/// Each connected MCP server counts as one ability, with the switches it already has in
/// Connections.
private struct MCPAbilitiesSection: View {
    @Bindable var settings: AppSettings
    var model: AppModel

    var body: some View {
        Section {
            if settings.preferences.mcpServers.isEmpty {
                HStack {
                    Text(verbatim: L("No MCP servers yet."))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Open Connections")) { model.settingsNavigation.pane = .connections }
                }
            }
            ForEach($settings.preferences.mcpServers) { $server in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $server.isEnabled) {
                        HStack(spacing: 10) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(
                                    SettingsPane.connections.tint.gradient,
                                    in: RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: server.name)
                                Text(verbatim: status(for: server.id))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if server.isEnabled {
                        Toggle(L("Always ask first"), isOn: $server.asksBeforeUse)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .padding(.leading, 34)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(verbatim: L("MCP servers"))
        } footer: {
            Text(verbatim: L("Add or remove servers in Connections."))
        }
        .onChange(of: settings.preferences.mcpServers) {
            Task { await model.connections.refresh() }
        }
    }

    private func status(for id: UUID) -> String {
        switch model.connections.statuses[id] {
        case .connected(let count): String(format: L("%lld tools"), count)
        case .connecting: L("Connecting…")
        case .failed: L("Couldn't connect")
        case nil: L("Off")
        }
    }
}
