import AppKit
import CoreWLAN
import Foundation
import IOKit.ps
import MomoKit

/// Everyday Mac controls: volume, appearance, display sleep, locking, quitting apps, and the
/// battery and Wi-Fi status.
enum SystemControlTools {
    static func all() -> [any MomoTool] {
        [volume(), darkMode(), sleepDisplay(), lockScreen(), quitApp(), systemStatus()]
    }

    // MARK: - Volume

    static func volume() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "system_volume",
                description:
                    "Read or change the Mac's output volume. Omit both arguments to only read it.",
                parameters: JSONSchema.object([
                    "level": JSONSchema.integer("New volume from 0 to 100"),
                    "muted": JSONSchema.boolean("true to mute, false to unmute"),
                ]),
                activityLabel: L("Adjusting the volume"))
        ) { arguments in
            var commands: [String] = []
            if let level = arguments["level"]?.intValue {
                commands.append("set volume output volume \(min(100, max(0, level)))")
                // Changing the level of a muted Mac should be heard.
                if arguments["muted"] == nil { commands.append("set volume output muted false") }
            }
            if let muted = arguments["muted"]?.boolValue {
                commands.append("set volume output muted \(muted)")
            }
            commands += [
                "set theSettings to get volume settings",
                "return (output volume of theSettings as string) & \",\" & (output muted of theSettings as string)",
            ]
            let output = try await AppleScriptRunner.run(commands.joined(separator: "\n"))
            let parts = output.split(separator: ",").map(String.init)
            guard parts.count == 2, let level = Int(parts[0]) else {
                return "This output device doesn't have an adjustable volume."
            }
            return parts[1] == "true" ? "Volume \(level)%, muted." : "Volume \(level)%."
        }
    }

    // MARK: - Appearance and display

    static func darkMode() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "set_dark_mode",
                description:
                    "Switch the Mac between dark and light appearance. Omit enabled to toggle.",
                parameters: JSONSchema.object([
                    "enabled": JSONSchema.boolean("true for dark, false for light")
                ]),
                activityLabel: L("Switching the appearance"))
        ) { arguments in
            let value = arguments["enabled"]?.boolValue.map { String($0) } ?? "not dark mode"
            let script = """
                tell application "System Events"
                    tell appearance preferences
                        set dark mode to \(value)
                        return dark mode
                    end tell
                end tell
                """
            let isDark = try await AppleScriptRunner.run(script) == "true"
            return isDark ? "Dark mode is on." : "Light mode is on."
        }
    }

    static func sleepDisplay() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "sleep_display",
                description: "Turn the display off now (the Mac keeps running).",
                activityLabel: L("Turning off the display"))
        ) { _ in
            let result = try await ProcessRunner.run(
                "/usr/bin/pmset", arguments: ["displaysleepnow"], timeout: 10)
            guard result.status == 0 else { throw ToolError("The display didn't go to sleep.") }
            return "The display is asleep."
        }
    }

    static func lockScreen() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "lock_screen",
                description: "Lock the Mac's screen right away.",
                activityLabel: L("Locking the screen"))
        ) { _ in
            if lockWithLoginFramework() { return "The screen is locked." }
            // Fallback: the system shortcut, which needs Accessibility for System Events.
            _ = try await AppleScriptRunner.run(
                "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"
            )
            return "The screen is locked."
        }
    }

    /// Calls `SACLockScreenImmediate` from the login framework, which is what the Lock Screen
    /// menu item uses. Returns `false` if it isn't available.
    private static func lockWithLoginFramework() -> Bool {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_LAZY) else { return false }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFunction = @convention(c) () -> Int32
        let lock = unsafeBitCast(symbol, to: LockFunction.self)
        return lock() == 0
    }

    // MARK: - Apps

    static func quitApp() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "quit_app",
                description:
                    "Quit a running app by name, as if the user chose Quit. The app may ask to save changes.",
                parameters: JSONSchema.object(
                    ["name": JSONSchema.string("The app's name, e.g. Safari")],
                    required: ["name"]),
                requiresConfirmation: true, activityLabel: L("Quitting an app")),
            summary: { String(format: L("Quit %@"), $0["name"]?.stringValue ?? "") }
        ) { arguments in
            guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
                throw ToolError("An app name is required.")
            }
            let (appName, requested) = try await MainActor.run {
                () throws -> (String, Bool) in
                guard let app = runningApp(named: name) else {
                    throw ToolError("No running app is called \(name).")
                }
                return (app.localizedName ?? name, app.terminate())
            }
            guard requested else {
                throw ToolError("\(appName) didn't accept the request to quit.")
            }
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(300))
                let stillRunning = await MainActor.run { runningApp(named: appName) != nil }
                if !stillRunning { return "Quit \(appName)." }
            }
            return
                "Asked \(appName) to quit. It's still open, probably waiting for the user to save or confirm."
        }
    }

    /// The regular (Dock) app with this name, never Momo itself.
    @MainActor
    private static func runningApp(named name: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        return apps.first { $0.localizedName?.lowercased() == wanted }
            ?? apps.first { $0.localizedName?.lowercased().contains(wanted) == true }
    }

    // MARK: - Status

    static func systemStatus() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "system_status",
                description:
                    "Report the battery level, charging state and time remaining, and the Wi-Fi network.",
                activityLabel: L("Checking your Mac"))
        ) { _ in
            [batteryStatus(), wifiStatus()].joined(separator: "\n")
        }
    }

    static func batteryStatus() -> String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return "Battery: unknown." }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let capacity = description[kIOPSCurrentCapacityKey] as? Int
            else { continue }
            let maximum = max(1, description[kIOPSMaxCapacityKey] as? Int ?? 100)
            let percent = Int((Double(capacity) / Double(maximum) * 100).rounded())
            let onBattery =
                description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            var text = "Battery: \(percent)%"
            if onBattery {
                text += ", on battery"
                if let minutes = description[kIOPSTimeToEmptyKey] as? Int, minutes > 0 {
                    text += ", about \(duration(minutes)) left"
                }
            } else if charging {
                text += ", charging"
                if let minutes = description[kIOPSTimeToFullChargeKey] as? Int, minutes > 0 {
                    text += ", full in about \(duration(minutes))"
                }
            } else {
                text += ", plugged in"
            }
            return text + "."
        }
        return "Battery: none (this Mac runs on mains power)."
    }

    private static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    static func wifiStatus() -> String {
        guard let interface = CWWiFiClient.shared().interface() else { return "Wi-Fi: no adapter." }
        guard interface.powerOn() else { return "Wi-Fi: off." }
        if let network = interface.ssid() {
            return "Wi-Fi: connected to “\(network)” (signal \(interface.rssiValue()) dBm)."
        }
        if interface.rssiValue() != 0 {
            return
                "Wi-Fi: connected (macOS only shares the network name with apps that have Location access, which the user can allow in Momo Settings → Permissions)."
        }
        return "Wi-Fi: on, not connected."
    }
}
