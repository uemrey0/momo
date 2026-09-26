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
    ///   - canDraw: Whether the `generate_image` and `edit_image` tools are offered.
    ///   - isSpoken: The reply is read aloud in a live voice conversation, so it must be short
    ///     and sound natural when spoken. The full text still lands in the chat.
    ///   - ranker: Ranks memories against the message.
    ///   - now: The current date, injectable for tests.
    public static func make(
        memories: [Memory], languageName: String, personality: String? = nil,
        message: String = "", canDraw: Bool = false, isSpoken: Bool = false,
        ranker: MemoryRanker = MemoryRanker(),
        now: Date = Date(),
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
            "For anything current or that you are unsure about, search the web and read pages instead of guessing, and cite the links you used briefly.",
            "When the user says \"this\" (\"summarise this\", \"translate this\") without giving the text, call get_context first to see their selection, window and browser tab.",
            "When the user shares a lasting fact or preference about themselves, save it with the remember tool and pick its category.",
            "For dates and times, use ISO 8601 local time. Resolve words like 'tomorrow' from the current time below.",
            isSpoken
                ? spokenStyle
                : "Use Markdown sparingly: short lists are fine, avoid headings and tables in casual replies.",
            "",
            "Current time: \(FlexibleDate.format(now, timeZone: timeZone)) (\(weekday.string(from: now)), \(timeZone.identifier)).",
        ]
        if canDraw {
            lines.insert(drawingInstruction, at: 5)
        }
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

    /// How to make pictures, the same way with every brain.
    static let drawingInstruction =
        "When the user asks for a picture (draw, paint, sketch, illustrate, make an image), call generate_image, and edit_image to change one, instead of drawing with text or another tool. The pictures appear in the chat, so just add a short line about them."

    /// How to answer in a live voice conversation, where the reply is heard, not read.
    static let spokenStyle = [
        "The user is talking to you by voice and hears your reply read aloud as you write it.",
        "Reply in one to three short, natural spoken sentences unless they ask for detail.",
        "Never use Markdown, lists, tables, code blocks or emoji.",
        "Never read out URLs, file paths or long IDs; name the site or source instead.",
        "Write times, dates and numbers the way people say them (\"half past three\", \"about two thousand\"), not as digits with symbols.",
        "When the full answer is long (steps, a list, code, a table), give the gist and offer to show the details in the chat.",
        "Start with the answer itself, not with filler like \"Sure\" or \"Great question\".",
    ].joined(separator: " ")
}
