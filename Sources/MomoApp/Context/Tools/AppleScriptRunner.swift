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
        guard result.status == 0 else { throw error(from: output) }
        return output
    }

    /// Turns an `osascript` failure into an error the model can explain to the user.
    static func error(from output: String) -> ToolError {
        let (message, code) = AppleScriptText.parseError(output)
        switch code {
        case -1743:
            return ToolError(
                "Momo isn't allowed to control that app. The user can allow it in System Settings → Privacy & Security → Automation → Momo."
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

    /// Whether an app with this bundle identifier is running. Scripts must check this before
    /// talking to an app they should not launch.
    static func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
