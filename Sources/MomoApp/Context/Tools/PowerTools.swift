import Foundation
import MomoKit

/// AppleScript and shell commands for anything the other tools can't do. The user always sees
/// the whole script or command and approves it before it runs.
enum PowerTools {
    /// How much output goes back to the model.
    static let outputLimit = 10_000

    static func all() -> [any MomoTool] {
        [runAppleScript(), runShellCommand()]
    }

    static func runAppleScript() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "run_applescript",
                description:
                    "Run an AppleScript to automate a Mac app when no other tool can do it (for example Finder, Notes, Keynote or System Events). The user sees the full script and must approve it. Keep scripts short and explain what they do. Times out after 60 seconds.",
                parameters: JSONSchema.object(
                    ["script": JSONSchema.string("The AppleScript source")],
                    required: ["script"]),
                requiresConfirmation: true, activityLabel: L("Running AppleScript")),
            summary: { arguments in
                String(
                    format: L("Run this AppleScript:\n\n%@"),
                    arguments["script"]?.stringValue ?? "")
            }
        ) { arguments in
            guard let script = arguments["script"]?.stringValue, !script.isEmpty else {
                throw ToolError("The script is empty.")
            }
            let output = try await AppleScriptRunner.run(script, timeout: 60)
            return output.isEmpty
                ? "The script ran and returned nothing."
                : OutputText.truncate(output, limit: outputLimit)
        }
    }

    static func runShellCommand() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "run_shell_command",
                description:
                    "Run a zsh command in the user's home folder when no other tool can do it (for example checking disk usage, converting a file or using a command line tool the user has). The user sees the full command and must approve it. Prefer read-only commands, never use sudo, and explain what the command does. Times out after 60 seconds; output is truncated.",
                parameters: JSONSchema.object(
                    ["command": JSONSchema.string("The command line, run with zsh -lc")],
                    required: ["command"]),
                requiresConfirmation: true, activityLabel: L("Running a command")),
            summary: { arguments in
                String(
                    format: L("Run this shell command:\n\n%@"),
                    arguments["command"]?.stringValue ?? "")
            }
        ) { arguments in
            guard let command = arguments["command"]?.stringValue, !command.isEmpty else {
                throw ToolError("The command is empty.")
            }
            let result = try await ProcessRunner.run(
                "/bin/zsh", arguments: ["-lc", command],
                currentDirectory: URL(fileURLWithPath: NSHomeDirectory()), timeout: 60)
            var text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            text = text.isEmpty ? "(no output)" : OutputText.truncate(text, limit: outputLimit)
            if result.truncated { text += "\n(output was cut off)" }
            if result.timedOut {
                return "The command ran longer than 60 seconds and was stopped.\n\(text)"
            }
            return "Exit code \(result.status).\n\(text)"
        }
    }
}
