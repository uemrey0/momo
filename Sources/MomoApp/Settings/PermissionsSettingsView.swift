import AppKit
import MomoKit
import SwiftUI

extension MacPermission {
    /// The permission's name as System Settings shows it.
    var title: String {
        switch self {
        case .microphone: L("Microphone", comment: "Permission")
        case .calendars: L("Calendars", comment: "Permission")
        case .reminders: L("Reminders", comment: "Permission")
        case .contacts: L("Contacts", comment: "Permission")
        case .screenRecording: L("Screen & System Audio Recording", comment: "Permission")
        case .accessibility: L("Accessibility", comment: "Permission")
        case .automation(let bundleIdentifier):
            bundleIdentifier.flatMap { id in AutomationTarget.all.first { $0.id == id } }.map {
                String(format: L("Automation: %@", comment: "Permission"), $0.name)
            } ?? L("Automation", comment: "Permission")
        case .notifications: L("Notifications", comment: "Permission")
        case .location: L("Location", comment: "Permission")
        }
    }

    /// What the permission lets Momo do, in plain words.
    var purpose: String {
        switch self {
        case .microphone: L("Talk to Momo, “Hey Momo” and meeting notes.")
        case .calendars: L("Plan your day, add events and remind you before meetings.")
        case .reminders: L("Read and add reminders in the Reminders app.")
        case .contacts: L("Find people's numbers and addresses to message or email them.")
        case .screenRecording:
            L("Read your screen when you ask, and hear the call for meeting notes.")
        case .accessibility: L("Read the text you select and the front window's title.")
        case .notifications: L("Let you know about routines, reminders and meetings.")
        case .location: L("Optional: only to tell you the Wi-Fi network's name.")
        case .automation(let bundleIdentifier):
            switch bundleIdentifier {
            case "com.apple.mail": L("Write email drafts for you to send.")
            case "com.apple.MobileSMS": L("Send the messages you confirm.")
            case "com.apple.Music", "com.spotify.client": L("Play, pause and skip songs.")
            case "com.apple.systemevents":
                L("Dark mode, locking the screen and other system controls.")
            case nil: L("Control other apps when you ask.")
            default: L("See the current tab when you say “this”.")
            }
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: "mic.fill"
        case .calendars: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        case .automation: "gearshape.2.fill"
        case .notifications: "bell.badge.fill"
        case .location: "location.fill"
        }
    }

    var tint: Color {
        switch self {
        case .microphone: Color(red: 0.98, green: 0.36, blue: 0.47)
        case .calendars, .reminders: Color(red: 1.0, green: 0.45, blue: 0.3)
        case .contacts: Color(red: 0.6, green: 0.55, blue: 0.5)
        case .screenRecording: Color(red: 0.55, green: 0.42, blue: 0.98)
        case .accessibility, .location: Color(red: 0.25, green: 0.55, blue: 0.98)
        case .automation: .gray
        case .notifications: Color(red: 0.95, green: 0.3, blue: 0.3)
        }
    }

    /// The Settings anchor of the permission's row.
    var anchor: String { "permission." + id }
}

/// Every macOS permission Momo uses, with its status and one button to fix it.
struct PermissionsSettingsView: View {
    var model: AppModel
    var permissions: PermissionCenter

    init(model: AppModel) {
        self.model = model
        self.permissions = model.permissions
    }

    var body: some View {
        Form {
            Section {
                ForEach(PermissionCenter.basics, id: \.self) { permission in
                    PermissionRow(permission: permission, permissions: permissions)
                }
            } footer: {
                Text(
                    verbatim: L(
                        "Momo only uses a permission when you ask for something that needs it. Changes in System Settings show up here when you come back."
                    ))
            }
            Section {
                if permissions.automationTargets.isEmpty {
                    PermissionRow(permission: .automation(nil), permissions: permissions)
                }
                ForEach(permissions.automationTargets) { target in
                    PermissionRow(
                        permission: target.permission, permissions: permissions,
                        title: target.name)
                }
            } header: {
                Text(verbatim: L("Automation"))
            } footer: {
                Text(
                    verbatim: L(
                        "Momo controls these apps only when you ask, and asks before sending anything. An app that isn't open can't be checked until you open it."
                    ))
            }
        }
        .formStyle(.grouped)
        .task { await permissions.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await permissions.refresh() }
        }
    }
}

/// One permission: what it's for, whether Momo has it and a button to change that.
private struct PermissionRow: View {
    var permission: MacPermission
    var permissions: PermissionCenter
    var title: String?

    private var status: PermissionStatus { permissions.status(permission) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(permission.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title ?? permission.title)
                Text(verbatim: permission.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PermissionStatusLabel(status: status)
            button
        }
        .padding(.vertical, 2)
        .settingsAnchor(permission.anchor)
    }

    @ViewBuilder
    private var button: some View {
        switch status {
        case .notDetermined:
            Button(L("Allow…")) { Task { await permissions.request(permission) } }
        case .denied:
            Button(L("Open System Settings")) { permissions.openSystemSettings(for: permission) }
        case .allowed, .unknown:
            Button {
                permissions.openSystemSettings(for: permission)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help(L("Open in System Settings"))
            .accessibilityLabel(L("Open in System Settings"))
        }
    }
}

/// "Allowed", "Not asked yet", "Not allowed" or "Unknown", coloured.
struct PermissionStatusLabel: View {
    var status: PermissionStatus

    var body: some View {
        switch status {
        case .allowed:
            Label(L("Allowed"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
                .font(.callout)
        case .notDetermined:
            Text(verbatim: L("Not asked yet")).font(.callout).foregroundStyle(.secondary)
        case .denied:
            Label(L("Not allowed"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .font(.callout)
        case .unknown:
            Text(verbatim: L("Open the app to check")).font(.callout).foregroundStyle(
                .secondary)
        }
    }
}
