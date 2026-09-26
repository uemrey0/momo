import AVFoundation
import AppKit
import ApplicationServices
@preconcurrency import Contacts
import CoreLocation
import EventKit
import MomoKit
import Observation
import Speech
import UserNotifications

/// Whether Momo has a macOS permission.
enum PermissionStatus: Equatable {
    case allowed
    /// macOS hasn't asked yet; asking shows its prompt.
    case notDetermined
    /// The user said no, or it is off in System Settings.
    case denied
    /// macOS can't tell right now, for example for an app that isn't running.
    case unknown
}

/// An app Momo controls with Apple events.
struct AutomationTarget: Identifiable, Hashable {
    var name: String
    var bundleIdentifier: String
    var id: String { bundleIdentifier }

    var permission: MacPermission { .automation(bundleIdentifier) }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    static let all = [
        AutomationTarget(name: "Mail", bundleIdentifier: "com.apple.mail"),
        AutomationTarget(name: "Messages", bundleIdentifier: "com.apple.MobileSMS"),
        AutomationTarget(name: "Music", bundleIdentifier: "com.apple.Music"),
        AutomationTarget(name: "Spotify", bundleIdentifier: "com.spotify.client"),
        AutomationTarget(name: "System Events", bundleIdentifier: "com.apple.systemevents"),
        AutomationTarget(name: "Safari", bundleIdentifier: "com.apple.Safari"),
        AutomationTarget(name: "Google Chrome", bundleIdentifier: "com.google.Chrome"),
        AutomationTarget(name: "Arc", bundleIdentifier: "company.thebrowser.Browser"),
        AutomationTarget(name: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac"),
        AutomationTarget(name: "Brave Browser", bundleIdentifier: "com.brave.Browser"),
    ]

    /// The target with this name, as AppleScript and `osascript` errors spell it.
    static func named(_ name: String) -> AutomationTarget? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Reads and requests the macOS permissions Momo uses, in one place.
///
/// Status checks never show a prompt. ``request(_:)`` asks macOS when it hasn't asked yet, and
/// otherwise opens the permission's page in System Settings.
@MainActor
@Observable
final class PermissionCenter {
    private(set) var statuses: [MacPermission: PermissionStatus] = [:]
    /// Automation targets installed on this Mac.
    private(set) var automationTargets: [AutomationTarget] = []
    @ObservationIgnored private var locationManager: CLLocationManager?
    @ObservationIgnored private let locationDelegate = LocationDelegate()
    @ObservationIgnored private let defaults: UserDefaults

    /// The permissions besides Automation, in the order Settings lists them.
    nonisolated static let basics: [MacPermission] = [
        .microphone, .speechRecognition, .calendars, .reminders, .contacts, .screenRecording,
        .accessibility, .notifications, .location,
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        locationDelegate.onChange = { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func status(_ permission: MacPermission) -> PermissionStatus {
        statuses[permission] ?? .unknown
    }

    /// Reads every status again, for example when Momo becomes active after the user changed
    /// something in System Settings.
    func refresh() async {
        var result: [MacPermission: PermissionStatus] = [:]
        for permission in Self.basics {
            result[permission] = await currentStatus(permission)
        }
        let targets = AutomationTarget.all.filter(\.isInstalled)
        for target in targets {
            result[target.permission] = await Self.automationStatus(target.bundleIdentifier)
        }
        automationTargets = targets
        statuses = result
    }

    /// Asks for `permission` when macOS hasn't asked yet; otherwise opens its page in
    /// System Settings, where the user can change their answer.
    func request(_ permission: MacPermission) async {
        if status(permission) == .notDetermined {
            await ask(permission)
            await refresh()
        } else {
            openSystemSettings(for: permission)
        }
    }

    func openSystemSettings(for permission: MacPermission) {
        if let url = Self.settingsURL(for: permission) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Status

    private func currentStatus(_ permission: MacPermission) async -> PermissionStatus {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .allowed
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .allowed
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .calendars:
            return Self.eventKitStatus(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return Self.eventKitStatus(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            // Full access, or limited access (macOS 15) to the contacts the user shared.
            default: return .allowed
            }
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() { return .allowed }
            return hasAsked(permission) ? .denied : .notDetermined
        case .accessibility:
            if AXIsProcessTrusted() { return .allowed }
            return hasAsked(permission) ? .denied : .notDetermined
        case .automation(let bundleIdentifier):
            guard let bundleIdentifier else { return .unknown }
            return await Self.automationStatus(bundleIdentifier)
        case .notifications:
            // Notifications need an app bundle; `swift run` builds have none.
            guard Bundle.main.bundleIdentifier != nil else { return .unknown }
            switch await Self.notificationStatus() {
            case .authorized, .provisional: return .allowed
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .location:
            switch (locationManager ?? CLLocationManager()).authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: return .allowed
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        }
    }

    private static func eventKitStatus(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .fullAccess: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Screen Recording and Accessibility can't tell "not asked" from "denied", so Momo
    /// remembers whether it asked.
    private func hasAsked(_ permission: MacPermission) -> Bool {
        defaults.bool(forKey: "permissionAsked." + permission.id)
    }

    private func markAsked(_ permission: MacPermission) {
        defaults.set(true, forKey: "permissionAsked." + permission.id)
    }

    // MARK: - Asking

    private func ask(_ permission: MacPermission) async {
        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speechRecognition:
            await Self.requestSpeechRecognition()
        case .calendars:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case .reminders:
            _ = try? await EKEventStore().requestFullAccessToReminders()
        case .contacts:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .screenRecording:
            markAsked(permission)
            if !CGRequestScreenCaptureAccess() { openSystemSettings(for: permission) }
        case .accessibility:
            markAsked(permission)
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .automation(let bundleIdentifier):
            guard let bundleIdentifier else { return }
            _ = await Self.automationStatus(bundleIdentifier, ask: true)
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound])
        case .location:
            let manager = locationManager ?? CLLocationManager()
            manager.delegate = locationDelegate
            locationManager = manager
            manager.requestWhenInUseAuthorization()
        }
    }

    // MARK: - Helpers that run off the main actor

    /// Whether Momo may send Apple events to an app. Without `ask`, never prompts; an app that
    /// isn't running can't be checked.
    nonisolated private static func automationStatus(
        _ bundleIdentifier: String, ask: Bool = false
    ) async -> PermissionStatus {
        await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
            guard let descriptor = target.aeDesc else { return PermissionStatus.unknown }
            let status = AEDeterminePermissionToAutomateTarget(
                descriptor, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
            switch status {
            case noErr: return .allowed
            case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
            case OSStatus(errAEEventNotPermitted): return .denied
            default: return .unknown
            }
        }.value
    }

    nonisolated private static func requestSpeechRecognition() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }

    nonisolated private static func notificationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings {
                continuation.resume(returning: $0.authorizationStatus)
            }
        }
    }

    /// The permission's page in System Settings → Privacy & Security.
    static func settingsURL(for permission: MacPermission) -> URL? {
        let anchor: String
        switch permission {
        case .microphone: anchor = "Privacy_Microphone"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .calendars: anchor = "Privacy_Calendars"
        case .reminders: anchor = "Privacy_Reminders"
        case .contacts: anchor = "Privacy_Contacts"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .automation: anchor = "Privacy_Automation"
        case .location: anchor = "Privacy_LocationServices"
        case .notifications:
            let id = Bundle.main.bundleIdentifier.map { "?id=\($0)" } ?? ""
            return URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension\(id)")
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

/// Tells the permission center when the Location answer changes. macOS calls it on the main
/// thread, where the manager was created.
private final class LocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    var onChange: (@Sendable () -> Void)?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onChange?()
    }
}
