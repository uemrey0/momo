import Foundation
import MomoKit

/// A short sentence Momo says in a live conversation while the real brain works on the
/// turn ("Takvimine bakıyorum."), written by the fastest ready on-device brain.
public enum LiveAcknowledgement {
    /// Instructions for the fast brain.
    public static let instructions = """
        You write the first few words Momo, a friendly assistant, says out loud while it works on the user's request.
        Reply with one short sentence of at most seven words, in the same language as the request, saying what you are about to do.
        Examples: "Let me check the weather." "Takvimine bakıyorum." "Hemen not alıyorum." "Looking that up for you."
        Never answer the request, never make up facts, never ask a question, no emoji, no quotes.
        """

    /// The acknowledgement in the brain's `reply`, or `nil` when it isn't usable: too long,
    /// a question, several sentences or empty.
    public static func clean(_ reply: String) -> String? {
        guard
            var text = reply.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces)
        else { return nil }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*_` "))
        guard !text.isEmpty, !text.contains("?"), text.count <= 60 else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count <= 9 else { return nil }
        // Keep only the first sentence.
        if let end = text.firstIndex(where: { ".!…".contains($0) }) {
            text = String(text[...end])
        } else {
            text += "."
        }
        return text.contains(where: \.isLetter) ? text : nil
    }

    /// Asks `provider` for an acknowledgement of `turn`, giving up after `timeout`.
    public static func make(
        for turn: String, with provider: any ChatProvider, timeout: Duration = .seconds(1.5)
    ) async -> String? {
        let request = ChatRequest(
            systemPrompt: instructions, turns: [ChatTurn(role: .user, text: turn)])
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var reply = ""
                do {
                    let noTools: ToolRunner = { call in
                        ToolResult(callID: call.id, name: call.name, output: "", isError: true)
                    }
                    for try await event in provider.respond(to: request, runTool: noTools) {
                        guard case .text(let chunk) = event else { continue }
                        reply += chunk
                        if reply.count > 160 || reply.contains(where: \.isNewline) { break }
                    }
                } catch {
                    return nil
                }
                return clean(reply)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
