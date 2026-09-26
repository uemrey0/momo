import Foundation

/// What the summary step made of a meeting.
public struct MeetingNotes: Sendable, Equatable {
    public var summary: String
    public var decisions: [String]
    public var actionItems: [MeetingActionItem]
    public var openQuestions: [String]
    /// Names of the other people who spoke.
    public var participants: [String]
    /// How many people took part, the user included, when the model could tell.
    public var participantCount: Int?
    /// Names matched to speaker labels, keyed by label without the "Speaker " prefix ("3A").
    public var speakerNames: [String: String]
    /// The language the meeting was held in, as an ISO 639-1 code.
    public var language: String?

    public init(
        summary: String = "", decisions: [String] = [], actionItems: [MeetingActionItem] = [],
        openQuestions: [String] = [], participants: [String] = [], participantCount: Int? = nil,
        speakerNames: [String: String] = [:], language: String? = nil
    ) {
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.participants = participants
        self.participantCount = participantCount
        self.speakerNames = speakerNames
        self.language = language
    }
}

/// What the summary step knows about a meeting besides its transcript.
public struct MeetingContext: Sendable, Equatable {
    public var title: String
    public var startedAt: Date
    /// Names of the people invited in the calendar, without the user.
    public var attendees: [String]
    /// The language the meeting is probably held in, as an ISO 639-1 code, when known.
    public var language: String?

    public init(title: String, startedAt: Date, attendees: [String] = [], language: String? = nil) {
        self.title = title
        self.startedAt = startedAt
        self.attendees = attendees
        self.language = language
    }
}

/// Writes a meeting's notes with a brain: a summary, decisions, action items with owners and
/// deadlines, open questions and who took part.
///
/// The brain is asked for JSON, and its answer is read defensively (code fences, prose around
/// the object, strings where lists were asked for). Long transcripts are summarised in parts
/// that fit the brain (map), and the partial notes are then merged (reduce), repeatedly if
/// needed, so small on-device brains can handle long meetings.
///
/// The brain itself is injected: the app runs each request through the assistant, so routing,
/// consent and personal data masking apply.
public enum MeetingSummarizer {
    /// Sends one request to a brain: instructions and a prompt in, the answer out.
    public typealias Complete =
        @Sendable (_ instructions: String, _ prompt: String) async throws
        -> String

    /// Summarises the transcript `lines` (from ``MeetingTranscript/lines(_:)``), keeping each
    /// request under about `maxCharacters`.
    public static func summarize(
        lines: [String], context: MeetingContext, maxCharacters: Int = 12_000,
        complete: Complete
    ) async throws -> MeetingNotes {
        let budget = max(2_000, maxCharacters)
        let parts = split(lines, maxCharacters: budget)
        let instructions = instructions(language: context.language)
        guard parts.count > 1 else {
            let answer = try await complete(
                instructions, notesPrompt(parts.first ?? [], context: context))
            return parse(answer, meetingDate: context.startedAt) ?? fallback(answer)
        }

        var partials: [MeetingNotes] = []
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            let answer = try await complete(
                instructions,
                notesPrompt(part, context: context, part: index + 1, of: parts.count))
            partials.append(parse(answer, meetingDate: context.startedAt) ?? fallback(answer))
        }
        let names = partials.reduce(into: [String: String]()) {
            $0.merge($1.speakerNames) { first, _ in first }
        }
        // Merge in groups that fit, until one set of notes is left.
        while partials.count > 1 {
            try Task.checkCancellation()
            var merged: [MeetingNotes] = []
            for group in groups(partials, maxCharacters: budget) {
                guard group.count > 1 else {
                    merged.append(contentsOf: group)
                    continue
                }
                let answer = try await complete(
                    instructions, combinePrompt(group, context: context))
                merged.append(
                    parse(answer, meetingDate: context.startedAt) ?? fallback(answer, from: group))
            }
            // Always make progress, even if every group held a single set of notes.
            if merged.count == partials.count {
                let answer = try await complete(
                    instructions, combinePrompt(merged, context: context))
                merged = [
                    parse(answer, meetingDate: context.startedAt)
                        ?? fallback(answer, from: merged)
                ]
            }
            partials = merged
        }
        var notes = partials[0]
        notes.speakerNames.merge(names) { current, _ in current }
        return notes
    }

    // MARK: - Prompts

    /// The model-facing instructions for every request.
    public static func instructions(language: String?) -> String {
        let languageRule =
            language.map {
                "Write every text value in the language the meeting was held in (probably the "
                    + "language with code \($0)); keep names as they are."
            } ?? "Write every text value in the language the meeting was held in."
        return """
            You take meeting notes for the user. You get an automatic transcript: each line \
            starts with the time from the start of the meeting and the speaker. "You" is the \
            user. Other speakers are "Speaker" plus a label such as 3A: the number is the part \
            of the recording and the letter tells speakers apart within that part only, so \
            Speaker 2A and Speaker 3A may or may not be the same person. Work out who is who \
            from introductions, names people call each other and the invited attendees. The \
            transcript may contain recognition errors; fix obvious ones silently.

            Answer with one JSON object and nothing else, in this shape:
            {
              "language": "ISO 639-1 code of the language the meeting was held in",
              "summary": "a short summary, 2 to 6 sentences",
              "decisions": ["each decision that was made"],
              "action_items": [{"task": "what to do", "owner": "who does it, You, or null", \
            "due": "YYYY-MM-DD when the date is clear, otherwise the words used, or null"}],
              "open_questions": ["questions left open"],
              "participants": ["names of the other people who spoke"],
              "participant_count": 3,
              "speakers": {"3A": "the name of Speaker 3A, only when you are sure"}
            }
            participant_count counts everyone who spoke, the user included. Use empty lists \
            when there is nothing to report and never invent content. \(languageRule)
            """
    }

    /// Asks for the notes of one transcript part (or of the whole meeting when `count` is 1).
    public static func notesPrompt(
        _ lines: [String], context: MeetingContext, part: Int = 1, of count: Int = 1
    ) -> String {
        var header = describe(context)
        if count > 1 {
            header +=
                "\nThis is part \(part) of \(count) of the transcript. Take notes of this part "
                + "only; they will be merged with the notes of the other parts."
        }
        let transcript = lines.isEmpty ? "(nothing was transcribed)" : lines.joined(separator: "\n")
        return "\(header)\n\nTranscript:\n\(transcript)"
    }

    /// Asks to merge notes of consecutive parts of one meeting into notes for the whole.
    public static func combinePrompt(_ partials: [MeetingNotes], context: MeetingContext) -> String
    {
        let items = partials.enumerated().map { index, notes in
            "Part \(index + 1):\n\(json(notes))"
        }
        return """
            \(describe(context))
            These are notes of consecutive parts of this meeting. Merge them into notes for \
            the whole meeting, in the same JSON shape: one summary of the whole meeting, \
            decisions and action items without duplicates, open questions that were not \
            answered in a later part, and speakers that are the same person under one name.

            \(items.joined(separator: "\n\n"))
            """
    }

    private static func describe(_ context: MeetingContext) -> String {
        var lines = [
            "Meeting: \(context.title)", "Date: \(FlexibleDate.format(context.startedAt))",
        ]
        if !context.attendees.isEmpty {
            lines.append("Invited: \(context.attendees.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    /// Notes as the JSON the brain is asked for, to feed partial notes back in.
    public static func json(_ notes: MeetingNotes) -> String {
        var object: [String: Any] = [
            "summary": notes.summary, "decisions": notes.decisions,
            "open_questions": notes.openQuestions, "participants": notes.participants,
            "speakers": notes.speakerNames,
            "action_items": notes.actionItems.map { item -> [String: Any] in
                var entry: [String: Any] = ["task": item.text]
                if let owner = item.owner { entry["owner"] = owner }
                if let due = item.dueDate.map({ DayKey.string(for: $0) }) ?? item.dueText {
                    entry["due"] = due
                }
                return entry
            },
        ]
        if let count = notes.participantCount { object["participant_count"] = count }
        if let language = notes.language { object["language"] = language }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: - Splitting

    /// Groups transcript lines into parts of at most `maxCharacters` each. A single longer
    /// line gets a part of its own.
    public static func split(_ lines: [String], maxCharacters: Int) -> [[String]] {
        var parts: [[String]] = []
        var current: [String] = []
        var size = 0
        for line in lines {
            if !current.isEmpty, size + line.count + 1 > maxCharacters {
                parts.append(current)
                current = []
                size = 0
            }
            current.append(line)
            size += line.count + 1
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Groups partial notes for merging, each group fitting `maxCharacters`.
    static func groups(_ partials: [MeetingNotes], maxCharacters: Int) -> [[MeetingNotes]] {
        var groups: [[MeetingNotes]] = []
        var current: [MeetingNotes] = []
        var size = 0
        for notes in partials {
            let length = json(notes).count
            if !current.isEmpty, size + length > maxCharacters {
                groups.append(current)
                current = []
                size = 0
            }
            current.append(notes)
            size += length
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    // MARK: - Reading the answer

    /// Reads the brain's JSON answer. Returns `nil` when there is no JSON object in it.
    public static func parse(_ text: String, meetingDate: Date = Date()) -> MeetingNotes? {
        guard let object = jsonObject(in: text) else { return nil }
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = object[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, !isNone(trimmed) { return trimmed }
                }
            }
            return nil
        }
        func list(_ keys: String...) -> [Any] {
            for key in keys {
                if let array = object[key] as? [Any] { return array }
                if let single = object[key] as? String { return [single] }
            }
            return []
        }
        func strings(_ keys: String...) -> [String] {
            var result: [String] = []
            for key in keys {
                let values: [Any] =
                    (object[key] as? [Any]) ?? (object[key] as? String).map { [$0] } ?? []
                for value in values {
                    let text =
                        (value as? String) ?? ((value as? [String: Any])?["name"] as? String)
                        ?? ((value as? [String: Any])?["text"] as? String)
                    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !text.isEmpty, !isNone(text)
                    else { continue }
                    result.append(text)
                }
                if !result.isEmpty { break }
            }
            return result
        }

        var notes = MeetingNotes()
        notes.summary = string("summary", "overview") ?? ""
        notes.decisions = strings("decisions", "decisions_made")
        notes.openQuestions = strings("open_questions", "openQuestions", "questions")
        notes.participants = strings("participants", "people", "attendees")
            .filter { $0.lowercased() != "you" }
        notes.actionItems = list("action_items", "actionItems", "actions", "tasks")
            .compactMap { actionItem(from: $0, meetingDate: meetingDate) }
        let count = object["participant_count"] ?? object["participantCount"]
        notes.participantCount =
            (count as? Int) ?? (count as? Double).map { Int($0) }
            ?? (count as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if let speakers = object["speakers"] as? [String: Any] {
            for (label, value) in speakers {
                guard let name = (value as? String)?.trimmingCharacters(in: .whitespaces),
                    !name.isEmpty, !isNone(name)
                else { continue }
                notes.speakerNames[MeetingTranscript.normalizedLabel(label)] = name
            }
        }
        notes.language = string("language").flatMap { code in
            let short = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
                .map { $0.lowercased() }
            return short?.count == 2 ? short : nil
        }
        return notes
    }

    private static func actionItem(from value: Any, meetingDate: Date) -> MeetingActionItem? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || isNone(trimmed) ? nil : MeetingActionItem(text: trimmed)
        }
        guard let entry = value as? [String: Any] else { return nil }
        func field(_ keys: String...) -> String? {
            for key in keys {
                if let text = (entry[key] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                    !isNone(text)
                {
                    return text
                }
            }
            return nil
        }
        guard let text = field("task", "text", "title", "description", "item", "action") else {
            return nil
        }
        let due = field("due", "due_date", "dueDate", "deadline", "when")
        let date = due.flatMap { FlexibleDate.parse($0) }
        return MeetingActionItem(
            text: text, owner: field("owner", "assignee", "who", "responsible"), dueDate: date,
            dueText: date == nil ? due : nil)
    }

    private static func isNone(_ text: String) -> Bool {
        ["null", "none", "n/a", "-", "unknown", "nil"].contains(text.lowercased())
    }

    /// The first JSON object in `text`: the whole answer, the inside of a code fence, or the
    /// span from the first `{` to the last `}`.
    static func jsonObject(in text: String) -> [String: Any]? {
        func object(_ candidate: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) as? [String: Any]
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = object(trimmed) { return direct }
        guard let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}"),
            open < close
        else { return nil }
        return object(String(trimmed[open...close]))
    }

    /// Notes from an answer that was not JSON: the answer becomes the summary, and anything
    /// the merged parts already found is kept.
    static func fallback(_ answer: String, from parts: [MeetingNotes] = []) -> MeetingNotes {
        var notes = MeetingNotes(summary: answer.trimmingCharacters(in: .whitespacesAndNewlines))
        for part in parts {
            notes.decisions += part.decisions
            notes.actionItems += part.actionItems
            notes.openQuestions += part.openQuestions
            notes.participants += part.participants.filter { !notes.participants.contains($0) }
            notes.speakerNames.merge(part.speakerNames) { current, _ in current }
            notes.language = notes.language ?? part.language
        }
        return notes
    }
}

extension Meeting {
    /// The meeting's notes as Markdown, for the note they are saved to. The headings are
    /// passed in so the app can localise them.
    public func noteBody(headings: MeetingNoteHeadings = MeetingNoteHeadings()) -> String {
        var sections: [String] = []
        if !summary.isEmpty { sections.append(summary) }
        func list(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            sections.append("## \(title)\n" + items.map { "- \($0)" }.joined(separator: "\n"))
        }
        list(headings.decisions, decisions)
        list(
            headings.actionItems,
            actionItems.map { item in
                var line = item.text
                var details: [String] = []
                if let owner = item.owner { details.append(owner) }
                if let due = item.dueDate.map({ DayKey.string(for: $0) }) ?? item.dueText {
                    details.append(due)
                }
                if !details.isEmpty { line += " (\(details.joined(separator: ", ")))" }
                return line
            })
        list(headings.openQuestions, openQuestions)
        list(
            String(format: headings.participantsFormat, participantCount),
            participants.map { $0.name })
        return sections.joined(separator: "\n\n")
    }
}

/// Section headings of a meeting note.
public struct MeetingNoteHeadings: Sendable {
    public var decisions: String
    public var actionItems: String
    public var openQuestions: String
    /// A format with one integer, the number of participants.
    public var participantsFormat: String

    public init(
        decisions: String = "Decisions", actionItems: String = "Action items",
        openQuestions: String = "Open questions", participantsFormat: String = "Participants (%ld)"
    ) {
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.participantsFormat = participantsFormat
    }
}
