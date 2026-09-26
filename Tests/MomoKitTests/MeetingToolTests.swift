import Foundation
import Testing

@testable import MomoKit

@Suite("Meeting tools")
struct MeetingToolTests {
    private func storeWithMeetings() async throws -> MomoStore {
        let store = temporaryStore()
        try await store.saveMeeting(
            Meeting(
                id: "m1", title: "Stand-up", startedAt: Date(timeIntervalSinceNow: -86_400),
                endedAt: Date(timeIntervalSinceNow: -86_400 + 900), status: .done,
                participants: [
                    MeetingParticipant(name: "You", isUser: true),
                    MeetingParticipant(name: "Ayşe"),
                    MeetingParticipant(name: "Deniz", spoke: false),
                ],
                participantCount: 2,
                segments: [
                    MeetingSegment(source: .you, text: "Let's ship on Friday", start: 0, end: 3)
                ],
                summary: "We agreed on the release date.", decisions: ["Ship on Friday"],
                actionItems: [
                    MeetingActionItem(id: "a1", text: "Write release notes", owner: "You"),
                    MeetingActionItem(id: "a2", text: "Book a room", owner: "Ayşe"),
                ]))
        try await store.saveMeeting(
            Meeting(
                id: "m2", title: "Retro", startedAt: Date(timeIntervalSinceNow: -86_400 * 10),
                status: .done, summary: "Looked back."))
        return store
    }

    @Test("list_meetings filters by words and days")
    func list() async throws {
        let box = Toolbox(StoreTools.all(store: try await storeWithMeetings()))
        let all = await box.execute(ToolCall(id: "1", name: "list_meetings", arguments: "{}"))
        #expect(all.output.contains("[m1]"))
        #expect(all.output.contains("[m2]"))
        #expect(all.output.contains("2 participants"))
        let recent = await box.execute(
            ToolCall(id: "2", name: "list_meetings", arguments: #"{"days": 3}"#))
        #expect(recent.output.contains("Stand-up"))
        #expect(!recent.output.contains("Retro"))
        let search = await box.execute(
            ToolCall(id: "3", name: "list_meetings", arguments: #"{"query": "ayşe"}"#))
        #expect(search.output.contains("Stand-up"))
        #expect(!search.output.contains("Retro"))
    }

    @Test("get_meeting returns the notes and, when asked, the transcript")
    func get() async throws {
        let box = Toolbox(StoreTools.all(store: try await storeWithMeetings()))
        let result = await box.execute(
            ToolCall(id: "1", name: "get_meeting", arguments: #"{"meeting": "stand-up"}"#))
        #expect(!result.isError)
        #expect(result.output.contains("Decisions:\n- Ship on Friday"))
        #expect(result.output.contains("[a2] Book a room — owner: Ayşe"))
        #expect(result.output.contains("Deniz (invited)"))
        #expect(!result.output.contains("Transcript"))
        let withTranscript = await box.execute(
            ToolCall(
                id: "2", name: "get_meeting",
                arguments: #"{"meeting": "latest", "include_transcript": true}"#))
        #expect(withTranscript.output.contains("[00:00] You: Let's ship on Friday"))
    }

    @Test("meeting_action_items_to_tasks adds the chosen items once")
    func toTasks() async throws {
        let store = try await storeWithMeetings()
        let box = Toolbox(StoreTools.all(store: store))
        let one = await box.execute(
            ToolCall(
                id: "1", name: "meeting_action_items_to_tasks",
                arguments: #"{"meeting": "m1", "items": "a2"}"#))
        #expect(one.output.contains("Book a room"))
        #expect(!one.output.contains("Write release notes"))
        let rest = await box.execute(
            ToolCall(
                id: "2", name: "meeting_action_items_to_tasks", arguments: #"{"meeting": "m1"}"#))
        #expect(rest.output.contains("Write release notes"))
        let again = await box.execute(
            ToolCall(
                id: "3", name: "meeting_action_items_to_tasks", arguments: #"{"meeting": "m1"}"#))
        #expect(again.output.contains("already tasks"))
        #expect(await store.tasks().count == 2)
        let none = await box.execute(
            ToolCall(
                id: "4", name: "meeting_action_items_to_tasks", arguments: #"{"meeting": "Retro"}"#)
        )
        #expect(none.output.contains("no action items"))
    }
}
