import Foundation

/// A macOS privacy permission Momo can use.
public enum MacPermission: Hashable, Sendable {
    case microphone
    case speechRecognition
    case calendars
    case reminders
    case contacts
    /// Screen & System Audio Recording: reading the screen and hearing a call's audio.
    case screenRecording
    case accessibility
    /// Automation of one app by its bundle identifier, or of apps in general when `nil`.
    case automation(String?)
    case notifications
    /// Location, which macOS requires before it tells apps the Wi-Fi network's name.
    case location

    /// A stable identifier, such as `calendars` or `automation:com.apple.Music`.
    public var id: String {
        switch self {
        case .microphone: "microphone"
        case .speechRecognition: "speechRecognition"
        case .calendars: "calendars"
        case .reminders: "reminders"
        case .contacts: "contacts"
        case .screenRecording: "screenRecording"
        case .accessibility: "accessibility"
        case .automation(let bundleIdentifier):
            bundleIdentifier.map { "automation:\($0)" } ?? "automation"
        case .notifications: "notifications"
        case .location: "location"
        }
    }

    public init?(id: String) {
        switch id {
        case "microphone": self = .microphone
        case "speechRecognition": self = .speechRecognition
        case "calendars": self = .calendars
        case "reminders": self = .reminders
        case "contacts": self = .contacts
        case "screenRecording": self = .screenRecording
        case "accessibility": self = .accessibility
        case "automation": self = .automation(nil)
        case "notifications": self = .notifications
        case "location": self = .location
        default:
            let prefix = "automation:"
            guard id.hasPrefix(prefix), id.count > prefix.count else { return nil }
            self = .automation(String(id.dropFirst(prefix.count)))
        }
    }
}

/// Thrown by a tool that can't work because a macOS permission is missing.
///
/// The model reads what is missing and where the user can allow it; the chat shows a button
/// that opens the permission in Momo's Settings.
public struct PermissionRequired: LocalizedError, Sendable, Hashable {
    public var permission: MacPermission
    /// What Momo couldn't do, written for the model ("Momo can't read Contacts.").
    public var message: String

    public init(_ permission: MacPermission, _ message: String) {
        self.permission = permission
        self.message = message
    }

    public var errorDescription: String? {
        message
            + " The user can allow it in Momo Settings → Permissions (or System Settings → Privacy & Security), then try again."
    }
}
