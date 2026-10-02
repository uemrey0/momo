import Foundation

/// A meeting Momo took notes of: who was there, what was said and what came out of it.
///
/// The transcript is kept as text only. Audio is never part of the store; when the user asks
/// Momo to keep it, ``audioFiles`` names the files kept next to the store.
public struct Meeting: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var startedAt: Date
    /// When recording stopped, or `nil` while it is still running.
    public var endedAt: Date?
    /// The calendar event the meeting belongs to, if Momo found one.
    public var calendarEventID: String?
    /// The language the meeting was held in, as an ISO 639-1 code, when known.
    public var language: String?
    public var status: MeetingStatus
    /// Everyone known to have taken part, the user first.
    public var participants: [MeetingParticipant]
    /// How many people spoke, including the user. It may be larger than ``participants``
    /// when some speakers could not be named.
    public var participantCount: Int
    /// What was said, in order.
    public var segments: [MeetingSegment]
    /// A short summary in the meeting's language.
    public var summary: String
    public var decisions: [String]
    public var actionItems: [MeetingActionItem]
    public var openQuestions: [String]
    /// The note the summary was saved to.
    public var noteID: String?
    /// Audio files kept when the user keeps meeting audio, as paths relative to the meetings
    /// folder ("<meeting id>/microphone.wav").
    public var audioFiles: [String]
    /// Why the meeting has no summary, when summarising failed.
    public var failureReason: String?

    public init(
        id: String = ShortID.make(), title: String, startedAt: Date = Date(),
        endedAt: Date? = nil, calendarEventID: String? = nil, language: String? = nil,
        status: MeetingStatus = .recording, participants: [MeetingParticipant] = [],
        participantCount: Int = 0, segments: [MeetingSegment] = [], summary: String = "",
        decisions: [String] = [], actionItems: [MeetingActionItem] = [],
        openQuestions: [String] = [], noteID: String? = nil, audioFiles: [String] = [],
        failureReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.calendarEventID = calendarEventID
        self.language = language
        self.status = status
        self.participants = participants
        self.participantCount = participantCount
        self.segments = segments
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.noteID = noteID
        self.audioFiles = audioFiles
        self.failureReason = failureReason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = container.lenient(String.self, .title) ?? ""
        startedAt = container.lenient(Date.self, .startedAt) ?? Date()
        endedAt = container.lenient(Date.self, .endedAt)
        calendarEventID = container.lenient(String.self, .calendarEventID)
        language = container.lenient(String.self, .language)
        status = container.lenient(MeetingStatus.self, .status) ?? .done
        participants = container.lossy(MeetingParticipant.self, .participants)
        participantCount = container.lenient(Int.self, .participantCount) ?? participants.count
        segments = container.lossy(MeetingSegment.self, .segments)
        summary = container.lenient(String.self, .summary) ?? ""
        decisions = container.lenient([String].self, .decisions) ?? []
        actionItems = container.lossy(MeetingActionItem.self, .actionItems)
        openQuestions = container.lenient([String].self, .openQuestions) ?? []
        noteID = container.lenient(String.self, .noteID)
        audioFiles = container.lenient([String].self, .audioFiles) ?? []
        failureReason = container.lenient(String.self, .failureReason)
    }

    /// How long the meeting lasted, or has lasted until `now` while recording.
    public func duration(now: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// The title of the note the summary is saved to: "Meeting: Stand-up — 2026-09-26".
    public var noteTitle: String {
        "Meeting: \(title) — \(DayKey.string(for: startedAt))"
    }
}

/// Where a meeting is in its life.
public enum MeetingStatus: String, Codable, Sendable, CaseIterable {
    /// Momo is listening.
    case recording
    /// Recording ended and the summary is being written.
    case summarizing
    /// The summary is ready.
    case done
    /// Recording ended but no summary could be written; it can be tried again.
    case failed

    /// Reads unknown values as `.done`, so newer files still load.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MeetingStatus(rawValue: raw) ?? .done
    }
}

/// Someone who took part in a meeting.
public struct MeetingParticipant: Codable, Sendable, Hashable {
    public var name: String
    /// Whether this is the user.
    public var isUser: Bool
    /// Whether they were heard speaking, rather than only invited in the calendar.
    public var spoke: Bool

    public init(name: String, isUser: Bool = false, spoke: Bool = true) {
        self.name = name
        self.isUser = isUser
        self.spoke = spoke
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        isUser = container.lenient(Bool.self, .isUser) ?? false
        spoke = container.lenient(Bool.self, .spoke) ?? true
    }
}

/// Which audio a piece of the transcript came from.
public enum MeetingSource: String, Codable, Sendable, CaseIterable {
    /// The microphone: the user.
    case you
    /// The Mac's audio output: everyone else in the call.
    case others

    /// Reads unknown values as `.others`.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MeetingSource(rawValue: raw) ?? .others
    }
}

/// A piece of what was said.
public struct MeetingSegment: Codable, Sendable, Hashable {
    public var source: MeetingSource
    /// A label telling other speakers apart, such as "3A" (speaker A of the third chunk of
    /// audio). Labels come from the transcription service and are only consistent within one
    /// chunk; ``speakerName`` holds the name the summary step matched to the label.
    public var speaker: String?
    /// The speaker's name, when it is known.
    public var speakerName: String?
    public var text: String
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    /// Seconds from the start of the meeting.
    public var end: TimeInterval

    public init(
        source: MeetingSource, speaker: String? = nil, speakerName: String? = nil, text: String,
        start: TimeInterval, end: TimeInterval
    ) {
        self.source = source
        self.speaker = speaker
        self.speakerName = speakerName
        self.text = text
        self.start = start
        self.end = end
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        source = container.lenient(MeetingSource.self, .source) ?? .others
        speaker = container.lenient(String.self, .speaker)
        speakerName = container.lenient(String.self, .speakerName)
        start = container.lenient(Double.self, .start) ?? 0
        end = container.lenient(Double.self, .end) ?? start
    }
}

/// Something someone agreed to do in a meeting.
public struct MeetingActionItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    /// Who does it, when it was said.
    public var owner: String?
    /// The deadline, when it was said and could be read as a date.
    public var dueDate: Date?
    /// The deadline as it was said ("by Friday"), when it could not be read as a date.
    public var dueText: String?
    /// The task created from this item, once the user added it to their tasks.
    public var taskID: String?

    public init(
        id: String = ShortID.make(), text: String, owner: String? = nil, dueDate: Date? = nil,
        dueText: String? = nil, taskID: String? = nil
    ) {
        self.id = id
        self.text = text
        self.owner = owner
        self.dueDate = dueDate
        self.dueText = dueText
        self.taskID = taskID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        id = container.lenient(String.self, .id) ?? ShortID.make()
        owner = container.lenient(String.self, .owner)
        dueDate = container.lenient(Date.self, .dueDate)
        dueText = container.lenient(String.self, .dueText)
        taskID = container.lenient(String.self, .taskID)
    }
}
