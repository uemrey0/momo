import Foundation
import Testing

@testable import MomoKit

@Suite("Meeting transcript")
struct MeetingTranscriptTests {
    @Test("merges both tracks by time and writes lines for a model")
    func linesAndOrder() {
        let segments = [
            MeetingSegment(source: .others, speaker: "1A", text: "Welcome", start: 1, end: 2),
            MeetingSegment(source: .you, text: "Hi", start: 0, end: 1),
            MeetingSegment(
                source: .others, speaker: "1B", speakerName: "Ayşe", text: "Hello", start: 65,
                end: 66),
            MeetingSegment(source: .others, text: "Bye", start: 3_725, end: 3_726),
        ]
        #expect(
            MeetingTranscript.lines(segments) == [
                "[00:00] You: Hi", "[00:01] Speaker 1A: Welcome", "[01:05] Ayşe: Hello",
                "[1:02:05] Others: Bye",
            ])
    }

    @Test("drops microphone segments that echo the call")
    func echo() {
        let others = MeetingSegment(
            source: .others, speaker: "1A", text: "We should ship the release on Friday.",
            start: 10, end: 14)
        let echo = MeetingSegment(
            source: .you, text: "we should ship the release on friday", start: 10.5, end: 14)
        let reply = MeetingSegment(
            source: .you, text: "Friday works for me, I will write the notes", start: 15, end: 18)
        let short = MeetingSegment(source: .you, text: "Yes", start: 11, end: 11.5)
        let later = MeetingSegment(
            source: .you, text: "We should ship the release on Friday", start: 60, end: 63)
        let result = MeetingTranscript.removingEcho([others, echo, reply, short, later])
        #expect(result == [others, reply, short, later])
    }

    @Test("applies names matched to speaker labels")
    func names() {
        let segments = [
            MeetingSegment(source: .others, speaker: "2A", text: "Hi", start: 0, end: 1),
            MeetingSegment(source: .others, speaker: "2B", text: "Hey", start: 1, end: 2),
            MeetingSegment(source: .you, text: "Hello", start: 2, end: 3),
        ]
        let named = MeetingTranscript.applying(
            names: ["Speaker 2a": "Ayşe", "2B": " "], to: segments)
        #expect(named[0].speakerName == "Ayşe")
        #expect(named[1].speakerName == nil)
        #expect(named[2].speakerName == nil)
    }
}

@Suite("Meeting participants")
struct MeetingParticipantsTests {
    private func other(_ label: String?, _ name: String? = nil) -> MeetingSegment {
        MeetingSegment(
            source: .others, speaker: label, speakerName: name, text: "x", start: 0, end: 1)
    }

    @Test("counts the most speakers heard in one chunk, since labels differ between chunks")
    func perChunk() {
        let segments = [other("1A"), other("1B"), other("2A"), other("2B"), other("2C")]
        #expect(MeetingParticipants.othersHeard(in: segments) == 3)
        #expect(MeetingParticipants.count(segments: segments) == 4)
    }

    @Test("named speakers and the brain's count raise the estimate")
    func namedAndInferred() {
        let segments = [other("1A", "Ayşe"), other("2A", "Can"), other("3A", "Ayşe")]
        #expect(MeetingParticipants.othersHeard(in: segments) == 2)
        #expect(MeetingParticipants.count(segments: segments, inferred: 5) == 5)
        #expect(MeetingParticipants.count(segments: segments, names: ["A", "B", "C"]) == 4)
        #expect(MeetingParticipants.count(segments: [other(nil)]) == 2)
        #expect(MeetingParticipants.count(segments: []) == 1)
    }

    @Test("lists the user, speakers and attendees who were not heard")
    func list() {
        let list = MeetingParticipants.list(
            userName: "You", userSpoke: true, spokenNames: ["Ayşe", "Can", "you", "ayşe"],
            attendees: ["Ayşe Yılmaz", "Deniz Kaya"])
        #expect(
            list == [
                MeetingParticipant(name: "You", isUser: true),
                MeetingParticipant(name: "Ayşe Yılmaz"), MeetingParticipant(name: "Can"),
                MeetingParticipant(name: "Deniz Kaya", spoke: false),
            ])
    }
}

@Suite("Meeting summarizer")
struct MeetingSummarizerTests {
    let context = MeetingContext(
        title: "Stand-up", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
        attendees: ["Ayşe Yılmaz"], language: "tr")

    @Test("parses the JSON answer, tolerating a code fence and loose values")
    func parse() throws {
        let answer = """
            Here are the notes:
            ```json
            {"language": "tr-TR", "summary": "Sürümü konuştuk.",
             "decisions": "Cuma çıkıyoruz",
             "action_items": [
               {"task": "Notları yaz", "owner": "You", "due": "2026-10-02"},
               {"text": "Oda ayarla", "assignee": "Ayşe", "deadline": "next week"},
               "Demo hazırla", {"owner": "Can"}, "none"],
             "open_questions": [],
             "participants": [{"name": "Ayşe"}, "You", "null"],
             "participant_count": "3",
             "speakers": {"Speaker 1A": "Ayşe", "1B": null}}
            ```
            """
        let notes = try #require(MeetingSummarizer.parse(answer))
        #expect(notes.language == "tr")
        #expect(notes.summary == "Sürümü konuştuk.")
        #expect(notes.decisions == ["Cuma çıkıyoruz"])
        #expect(notes.actionItems.map(\.text) == ["Notları yaz", "Oda ayarla", "Demo hazırla"])
        #expect(notes.actionItems[0].owner == "You")
        #expect(notes.actionItems[0].dueDate != nil)
        #expect(notes.actionItems[0].dueText == nil)
        #expect(notes.actionItems[1].owner == "Ayşe")
        #expect(notes.actionItems[1].dueText == "next week")
        #expect(notes.openQuestions.isEmpty)
        #expect(notes.participants == ["Ayşe"])
        #expect(notes.participantCount == 3)
        #expect(notes.speakerNames == ["1A": "Ayşe"])
    }

    @Test("an answer without JSON is not parsed")
    func notJSON() {
        #expect(MeetingSummarizer.parse("We talked about the release.") == nil)
    }

    @Test("prompts describe the meeting and ask for the meeting's language")
    func prompts() {
        let prompt = MeetingSummarizer.notesPrompt(
            ["[00:00] You: Merhaba"], context: context, part: 2, of: 3)
        #expect(prompt.contains("Meeting: Stand-up"))
        #expect(prompt.contains("Invited: Ayşe Yılmaz"))
        #expect(prompt.contains("part 2 of 3"))
        #expect(prompt.hasSuffix("Transcript:\n[00:00] You: Merhaba"))
        let instructions = MeetingSummarizer.instructions(language: "tr")
        #expect(instructions.contains("language with code tr"))
        #expect(instructions.contains("\"action_items\""))
    }

    @Test("splits long transcripts into parts that fit")
    func split() {
        let lines = (0..<10).map { String(repeating: "x", count: 99) + "\($0)" }
        let parts = MeetingSummarizer.split(lines, maxCharacters: 350)
        #expect(parts.map(\.count) == [3, 3, 3, 1])
        #expect(parts.flatMap { $0 } == lines)
        #expect(
            MeetingSummarizer.split([String(repeating: "y", count: 900)], maxCharacters: 350).count
                == 1)
    }

    @Test("summarises a short meeting in one request")
    func singleRequest() async throws {
        let calls = CallLog()
        let notes = try await MeetingSummarizer.summarize(
            lines: ["[00:00] You: Hi"], context: context
        ) { _, prompt in
            await calls.add(prompt)
            return #"{"summary": "Short.", "speakers": {"1A": "Ayşe"}}"#
        }
        #expect(notes.summary == "Short.")
        #expect(await calls.prompts.count == 1)
    }

    @Test("maps long transcripts in parts, then reduces the partial notes")
    func mapReduce() async throws {
        let calls = CallLog()
        let lines = (0..<40).map {
            "[00:\($0)] Speaker 1A: " + String(repeating: "word ", count: 20)
        }
        let notes = try await MeetingSummarizer.summarize(
            lines: lines, context: context, maxCharacters: 2_000
        ) { _, prompt in
            await calls.add(prompt)
            if prompt.contains("These are notes of consecutive parts") {
                return #"{"summary": "Whole meeting.", "decisions": ["A"], "action_items": []}"#
            }
            let index = await calls.prompts.count
            return """
                {"summary": "Part \(index).", "decisions": ["A"], "speakers": {"1A": "Name \(index)"}}
                """
        }
        let prompts = await calls.prompts
        let maps = prompts.filter { $0.contains("Transcript:") }
        let reduces = prompts.filter { $0.contains("These are notes of consecutive parts") }
        #expect(maps.count == MeetingSummarizer.split(lines, maxCharacters: 2_000).count)
        #expect(maps.count > 1)
        #expect(!reduces.isEmpty)
        #expect(notes.summary == "Whole meeting.")
        #expect(notes.decisions == ["A"])
        // Speaker names found in the parts survive the merge.
        #expect(notes.speakerNames["1A"] == "Name 1")
    }

    @Test("keeps the answer as the summary when it is not JSON")
    func fallback() async throws {
        let notes = try await MeetingSummarizer.summarize(
            lines: ["[00:00] You: Hi"], context: context
        ) { _, _ in "  Just prose.  " }
        #expect(notes.summary == "Just prose.")
        #expect(notes.actionItems.isEmpty)
    }

    @Test("the note body lists every section")
    func noteBody() {
        let meeting = Meeting(
            title: "Stand-up", status: .done,
            participants: [
                MeetingParticipant(name: "You", isUser: true), MeetingParticipant(name: "Ayşe"),
            ],
            participantCount: 2, summary: "Talked.", decisions: ["Ship"],
            actionItems: [MeetingActionItem(text: "Write notes", owner: "You", dueText: "Friday")],
            openQuestions: ["Who presents?"])
        let body = meeting.noteBody()
        #expect(body.hasPrefix("Talked."))
        #expect(body.contains("## Decisions\n- Ship"))
        #expect(body.contains("- Write notes (You, Friday)"))
        #expect(body.contains("## Open questions\n- Who presents?"))
        #expect(body.contains("## Participants (2)\n- You\n- Ayşe"))
    }
}

/// Records prompts from concurrent test closures.
private actor CallLog {
    private(set) var prompts: [String] = []
    func add(_ prompt: String) { prompts.append(prompt) }
}

@Suite("Meeting detection")
struct MeetingDetectorTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(startsIn minutes: Double, lasting duration: Double = 30) -> CalendarMeeting {
        CalendarMeeting(
            id: "e1", title: "Stand-up", start: now.addingTimeInterval(minutes * 60),
            end: now.addingTimeInterval((minutes + duration) * 60))
    }

    @Test("a meeting app on the microphone during an event is offered once per event")
    func eventAndApp() throws {
        let signals = MeetingDetector.Signals(
            now: now, events: [event(startsIn: -3)], microphoneUsers: ["us.zoom.xos"])
        let offer = try #require(MeetingDetector.offer(for: signals))
        #expect(offer.app.name == "Zoom")
        #expect(offer.event?.title == "Stand-up")
        #expect(offer.key.hasPrefix("event-e1-"))
    }

    @Test("an event starting within a few minutes counts; a later or finished one does not")
    func leadTime() {
        let zoom = ["us.zoom.xos"]
        let soon = MeetingDetector.Signals(
            now: now, events: [event(startsIn: 4)], microphoneUsers: zoom)
        #expect(MeetingDetector.offer(for: soon)?.event != nil)
        let later = MeetingDetector.Signals(
            now: now, events: [event(startsIn: 20)], microphoneUsers: zoom)
        #expect(MeetingDetector.offer(for: later)?.event == nil)
        let over = MeetingDetector.Signals(
            now: now, events: [event(startsIn: -40)], microphoneUsers: zoom)
        #expect(MeetingDetector.offer(for: over)?.event == nil)
        var allDay = event(startsIn: -60, lasting: 24 * 60)
        allDay.isAllDay = true
        #expect(MeetingDetector.currentEvent(in: [allDay], at: now) == nil)
    }

    @Test("a dedicated call app is offered without an event, a browser is not")
    func withoutEvent() {
        let huddle = MeetingDetector.Signals(
            now: now, microphoneUsers: ["com.tinyspeck.slackmacgap"])
        #expect(MeetingDetector.offer(for: huddle)?.key == "app-com.tinyspeck.slackmacgap")
        let browser = MeetingDetector.Signals(
            now: now, microphoneUsers: ["com.google.Chrome.helper"])
        #expect(MeetingDetector.offer(for: browser) == nil)
        let meet = MeetingDetector.Signals(
            now: now, events: [event(startsIn: 0)], microphoneUsers: ["com.google.Chrome.helper"])
        #expect(MeetingDetector.offer(for: meet)?.app.name == "Google Chrome")
    }

    @Test("nothing is offered without a meeting app on the microphone")
    func noMicrophone() {
        let quiet = MeetingDetector.Signals(
            now: now, events: [event(startsIn: -3)], microphoneUsers: [],
            runningApps: ["us.zoom.xos"], frontmostApp: "us.zoom.xos")
        #expect(MeetingDetector.offer(for: quiet) == nil)
        let dictation = MeetingDetector.Signals(
            now: now, events: [event(startsIn: -3)], microphoneUsers: ["com.apple.VoiceMemos"])
        #expect(MeetingDetector.offer(for: dictation) == nil)
    }

    @Test("without the process list, the microphone plus an event and a running meeting app count")
    func fallback() {
        let unknown = MeetingDetector.Signals(
            now: now, events: [event(startsIn: -1)], microphoneUsers: nil, microphoneInUse: true,
            runningApps: ["com.apple.Safari", "com.microsoft.teams2"],
            frontmostApp: "com.apple.finder")
        #expect(MeetingDetector.offer(for: unknown)?.app.name == "Microsoft Teams")
        var noEvent = unknown
        noEvent.events = []
        noEvent.frontmostApp = "us.zoom.xos"
        #expect(MeetingDetector.offer(for: noEvent) == nil)
        var micOff = unknown
        micOff.microphoneInUse = false
        #expect(MeetingDetector.offer(for: micOff) == nil)
    }
}
