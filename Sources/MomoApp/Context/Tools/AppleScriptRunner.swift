import AppKit
import Foundation
import MomoKit

/// Runs AppleScript through `osascript`, off the main thread and with a timeout.
///
/// macOS attributes the Apple events to Momo, so the Automation prompt names Momo and uses its
/// `NSAppleEventsUsageDescription`. Build scripts with ``AppleScriptText/literal(_:)`` for
/// every value that comes from a model or the user.
enum AppleScriptRunner {
    /// Runs `source` and returns what it printed, trimmed.
    static func run(_ source: String, timeout: TimeInterval = 30) async throws -> String {
        let result = try await ProcessRunner.run(
            "/usr/bin/osascript", arguments: ["-e", source], timeout: timeout)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.timedOut {
            throw ToolError("The script took longer than \(Int(timeout)) seconds and was stopped.")
        }
        guard result.status == 0 else { throw error(from: output, source: source) }
        return output
    }

    /// Turns an `osascript` failure into an error the model can explain to the user. A missing
    /// Automation permission becomes ``PermissionRequired`` for the app the script talks to.
    static func error(from output: String, source: String = "") -> any Error {
        let (message, code) = AppleScriptText.parseError(output)
        switch code {
        case -1743:
            let target = automationTarget(message: message, source: source)
            return PermissionRequired(
                .automation(target?.bundleIdentifier),
                "Momo isn't allowed to control \(target?.name ?? "that app") (Automation permission)."
            )
        case -1728, -1719:
            return ToolError("The app couldn't find that item: \(message)")
        case -600:
            return ToolError("The app isn't running.")
        case -128:
            return ToolError("The user cancelled.")
        default:
            return ToolError(message.isEmpty ? "The script failed." : message)
        }
    }

    /// The app a denied script wanted to control: named in the error ("Not authorized to send
    /// Apple events to Music."), or else the first app the script tells.
    static func automationTarget(message: String, source: String) -> AutomationTarget? {
        if let range = message.range(of: "Apple events to ") {
            let name = message[range.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
            if let target = AutomationTarget.named(name) { return target }
        }
        let patterns = [#"tell application id "([^"]+)""#, #"tell application "([^"]+)""#]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(
                    in: source, range: NSRange(source.startIndex..., in: source)),
                let range = Range(match.range(at: 1), in: source)
            else { continue }
            let value = String(source[range])
            if index == 0 {
                return AutomationTarget.all.first { $0.bundleIdentifier == value }
                    ?? AutomationTarget(name: value, bundleIdentifier: value)
            }
            if let target = AutomationTarget.named(value) { return target }
        }
        return nil
    }

    /// Whether an app with this bundle identifier is running. Scripts must check this before
    /// talking to an app they should not launch.
    static func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
