import Foundation
import MomoKit

/// Controls playback in Music or Spotify. Only apps that are already running are controlled,
/// so a request never launches a player the user doesn't use.
enum MusicTools {
    /// A player Momo can control, with the name its AppleScript dictionary answers to.
    struct Player: Sendable {
        var name: String
        var bundleIdentifier: String
    }

    static let players = [
        Player(name: "Spotify", bundleIdentifier: "com.spotify.client"),
        Player(name: "Music", bundleIdentifier: "com.apple.Music"),
    ]

    static let commands = [
        "play": "play", "pause": "pause", "toggle": "playpause", "next": "next track",
        "previous": "previous track",
    ]

    static func all() -> [any MomoTool] {
        [controlMusic()]
    }

    static func controlMusic() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "control_music",
                description:
                    "Control music playback in Spotify or Apple Music (whichever is running), or tell what's playing. Use now_playing to answer “what song is this?”.",
                parameters: JSONSchema.object(
                    [
                        "action": JSONSchema.oneOf(
                            ["play", "pause", "toggle", "next", "previous", "now_playing"],
                            description: "What to do"),
                        "app": JSONSchema.oneOf(
                            ["Spotify", "Music"],
                            description: "Which player; omit to use the one that's running"),
                    ], required: ["action"]),
                activityLabel: L("Controlling music"))
        ) { arguments in
            let action = arguments["action"]?.stringValue ?? "now_playing"
            let player = try await choosePlayer(named: arguments["app"]?.stringValue)
            if let command = commands[action] {
                _ = try await AppleScriptRunner.run(
                    "tell application \(AppleScriptText.literal(player.name)) to \(command)")
                // Give the player a moment to switch tracks before reading them.
                try? await Task.sleep(for: .milliseconds(400))
            } else if action != "now_playing" {
                throw ToolError("Unknown action \(action).")
            }
            return "\(player.name): \(try await nowPlaying(player))"
        }
    }

    /// The requested player, or the one that's playing, or any running one.
    private static func choosePlayer(named name: String?) async throws -> Player {
        let running = players.filter { AppleScriptRunner.isRunning($0.bundleIdentifier) }
        if let name {
            guard
                let player = running.first(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                })
            else {
                throw ToolError("\(name) isn't running. The user can open it first.")
            }
            return player
        }
        guard !running.isEmpty else {
            throw ToolError("Neither Spotify nor Music is running.")
        }
        for player in running {
            let state = try? await AppleScriptRunner.run(
                "tell application \(AppleScriptText.literal(player.name)) to player state as string"
            )
            if state == "playing" { return player }
        }
        return running[0]
    }

    private static func nowPlaying(_ player: Player) async throws -> String {
        let script = """
            tell application \(AppleScriptText.literal(player.name))
                set theState to player state as string
                if theState is "stopped" then return theState
                set theTrack to current track
                return theState & tab & (name of theTrack) & tab & (artist of theTrack) & tab & (album of theTrack)
            end tell
            """
        let parts = try await AppleScriptRunner.run(script).components(separatedBy: "\t")
        guard parts.count == 4 else { return "stopped" }
        return "\(parts[0]) — “\(parts[1])” by \(parts[2]) (album: \(parts[3]))"
    }
}
