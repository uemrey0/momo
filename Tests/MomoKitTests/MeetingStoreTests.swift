import Foundation
import Testing

@testable import MomoKit

@Suite("Meeting store")
struct MeetingStoreTests {
    /// A data.json written by Momo before meetings existed.
    static let versionTwo = """
        {
          "memories" : [],
          "notes" : [ { "body" : "B", "createdAt" : "2026-09-01T08:00:00Z", "id" : "n1",
                        "title" : "T", "updatedAt" : "2026-09-01T08:00:00Z" } ],
          "routines" : [],
          "tasks" : [ { "createdAt" : "2026-09-01T08:00:00Z", "id" : "t1", "isDone" : false,
                        "priority" : "normal", "tags" : [], "title" : "Pay rent" } ],
          "habits" : [],
          "version" : 2
        }
        """

    private func decode(_ json: String) throws -> MomoData {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MomoData.self, from: Data(json.utf8))
    }

    private func sampleMeeting(title: String = "Stand-up", startedAt: Date = Date()) -> Meeting {
        Meeting(
            title: title, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(900),
            calendarEventID: "event-1", language: "en", status: .done,
            participants: [
                MeetingParticipant(name: "You", isUser: true),
                MeetingParticipant(name: "Ayşe"),
            ],
            participantCount: 2,
            segments: [
                MeetingSegment(source: .you, text: "Hi all", start: 0, end: 2),
                MeetingSegment(
                    source: .others, speaker: "0A", speakerName: "Ayşe", text: "Hello",
                    start: 2, end: 3),
            ],
            summary: "We planned the launch.", decisions: ["Ship on Friday"],
            actionItems: [
                MeetingActionItem(id: "a1", text: "Write release notes", owner: "You"),
                MeetingActionItem(
                    id: "a2", text: "Book a room", owner: "Ayşe", dueText: "next week"),
            ],
            openQuestions: ["Who presents?"])
    }

    @Test("a version 2 file loads with no meetings")
    func versionTwoFile() throws {
        let data = try decode(Self.versionTwo)
        #expect(data.version == MomoData.currentVersion)
        #expect(data.meetings.isEmpty)
        #expect(data.tasks.first?.title == "Pay rent")
        #expect(data.notes.count == 1)
    }

    @Test("a damaged meeting is skipped and missing fields get defaults")
    func lenientMeetings() throws {
        let data = try decode(
            """
            {
              "meetings" : [
                { "title" : "No ID" },
                { "id" : "m2", "title" : "Retro", "status" : "someday",
                  "segments" : [ { "text" : "Hi", "source" : "robot" }, { "start" : 3 } ],
                  "actionItems" : [ { "text" : "Fix CI" } ] }
              ]
            }
            """)
        #expect(data.meetings.count == 1)
        let meeting = try #require(data.meetings.first)
        #expect(meeting.status == .done)
        #expect(meeting.segments == [MeetingSegment(source: .others, text: "Hi", start: 0, end: 0)])
        #expect(meeting.actionItems.first?.text == "Fix CI")
        #expect(meeting.actionItems.first?.id.isEmpty == false)
        #expect(meeting.participants.isEmpty)
    }

    @Test("meetings persist and round-trip through the file")
    func persistence() async throws {
        let store = temporaryStore()
        // Whole seconds, since the file stores dates without fractions.
        let meeting = sampleMeeting(startedAt: Date(timeIntervalSince1970: 1_790_000_000))
        try await store.saveMeeting(meeting)
        let reopened = MomoStore(fileURL: store.fileURL)
        #expect(await reopened.meeting(id: meeting.id) == meeting)

        var changed = meeting
        changed.summary = "Updated"
        try await reopened.saveMeeting(changed)
        #expect(await reopened.meetings().count == 1)
        #expect(await reopened.meetings().first?.summary == "Updated")
    }

    @Test("finds the newest meeting by title, ID or 'latest'")
    func findMeeting() async throws {
        let store = temporaryStore()
        let old = sampleMeeting(startedAt: Date(timeIntervalSinceNow: -86_400 * 2))
        let new = sampleMeeting(startedAt: Date(timeIntervalSinceNow: -3600))
        let retro = sampleMeeting(title: "Retro", startedAt: Date(timeIntervalSinceNow: -86_400))
        for meeting in [old, new, retro] { try await store.saveMeeting(meeting) }
        #expect(try await store.findMeeting("stand-up").id == new.id)
        #expect(try await store.findMeeting("stand").id == new.id)
        #expect(try await store.findMeeting(old.id).id == old.id)
        #expect(try await store.findMeeting("latest").id == new.id)
        await #expect(throws: ToolError.self) { try await store.findMeeting("board meeting") }
    }

    @Test("action items become tasks once, with owner, deadline and origin")
    func actionItemsToTasks() async throws {
        let store = temporaryStore()
        let meeting = sampleMeeting()
        try await store.saveMeeting(meeting)

        let first = try await store.addActionItemsAsTasks(meetingID: meeting.id, itemIDs: ["a2"])
        #expect(first.map(\.title) == ["Book a room"])
        #expect(first.first?.notes?.contains("Owner: Ayşe") == true)
        #expect(first.first?.notes?.contains("Due: next week") == true)
        #expect(first.first?.notes?.contains("Stand-up") == true)
        #expect(first.first?.tags == ["meeting"])

        let rest = try await store.addActionItemsAsTasks(meetingID: meeting.id)
        #expect(rest.map(\.title) == ["Write release notes"])
        #expect(try await store.addActionItemsAsTasks(meetingID: meeting.id).isEmpty)
        #expect(await store.tasks().count == 2)
        let saved = try #require(await store.meeting(id: meeting.id))
        #expect(saved.actionItems.allSatisfy { $0.taskID != nil })
    }

    @Test("the note title names the meeting and its day")
    func noteTitle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 10))
        let meeting = sampleMeeting(startedAt: start ?? Date())
        #expect(meeting.noteTitle == "Meeting: Stand-up — 2026-09-25")
    }
}
