import Foundation
import MomoKit

/// Builds Momo's instructions for a conversation.
public enum SystemPrompt {
    /// The most memories one prompt carries.
    public static let memoryLimit = 15

    /// - Parameters:
    ///   - memories: Facts Momo remembers about the user, oldest first.
    ///   - languageName: The user's preferred language in English, e.g. "Turkish".
    ///   - personality: An optional extra line describing the chosen personality.
    ///   - message: The message being answered. When there are more memories than fit, the
    ///     prompt keeps a few core ones and those most related to this message.
    ///   - ranker: Ranks memories against the message.
    ///   - now: The current date, injectable for tests.
    public static func make(
        memories: [Memory], languageName: String, personality: String? = nil,
        message: String = "", ranker: MemoryRanker = MemoryRanker(), now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "en_US_POSIX")
        weekday.timeZone = timeZone
        weekday.dateFormat = "EEEE"

        var lines = [
            "You are Momo, a small, warm and very capable assistant who lives in the notch of the user's Mac.",
            "Be friendly and a little playful, but get to the point: short answers by default, detail only when asked.",
            "Always reply in the language the user writes in. If unsure, use \(languageName).",
            "Use your tools to actually do things (tasks, reminders, notes, habits, memory, calendar, apps). Never claim you did something unless a tool confirmed it.",
            "When the user shares a lasting fact or preference about themselves, save it with the remember tool and pick its category.",
            "For dates and times, use ISO 8601 local time. Resolve words like 'tomorrow' from the current time below.",
            "Use Markdown sparingly: short lists are fine, avoid headings and tables in casual replies.",
            "",
            "Current time: \(FlexibleDate.format(now, timeZone: timeZone)) (\(weekday.string(from: now)), \(timeZone.identifier)).",
        ]
        if let personality, !personality.isEmpty {
            lines.append("Personality: \(personality)")
        }
        if !memories.isEmpty {
            lines.append("")
            let selected = ranker.promptMemories(
                from: memories, message: message, limit: memoryLimit)
            lines.append("What you remember about the user:")
            lines += selected.map { "- \($0.text)" }
            if selected.count < memories.count {
                lines.append(
                    "(Only the memories most related to this message are listed. Use list_memories for the rest.)"
                )
            }
        }
        return lines.joined(separator: "\n")
    }
}
