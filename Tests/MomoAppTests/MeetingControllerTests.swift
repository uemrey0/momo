import Foundation
import MomoKit
import Testing

@testable import MomoApp

@MainActor
@Suite("Meeting controller")
struct MeetingControllerTests {
    private typealias Start = MeetingController.PendingStart

    // MARK: - Starting

    @Test("asks for the Screen Recording permission before recording the call")
    func asksForSystemAudio() {
        let start = Start(title: "Standup")
        #expect(
            start.nextStep(hasSystemAudioPermission: false, engineIsRemote: true)
                == .askSystemAudioPermission)
        #expect(
            start.nextStep(hasSystemAudioPermission: false, engineIsRemote: false)
                == .askSystemAudioPermission)
    }

    @Test("recording only the microphone needs no Screen Recording permission")
    func microphoneOnlySkipsPermission() {
        var start = Start(title: "Standup")
        start.microphoneOnly = true
        #expect(
            start.nextStep(hasSystemAudioPermission: false, engineIsRemote: false)
                == .checkVoiceModels)
    }

    @Test("cloud transcription waits for the user's yes")
    func cloudNeedsConsent() {
        var start = Start(title: "Standup")
        #expect(
            start.nextStep(hasSystemAudioPermission: true, engineIsRemote: true)
                == .askCloudTranscription)
        start.approvedCloud = true
        #expect(start.nextStep(hasSystemAudioPermission: true, engineIsRemote: true) == .begin)
    }

    @Test("on-device transcription never asks about the cloud, only checks the models")
    func onDeviceChecksModels() {
        let start = Start(title: "Standup")
        #expect(
            start.nextStep(hasSystemAudioPermission: true, engineIsRemote: false)
                == .checkVoiceModels)
    }

    @Test("answering each question moves the start on to the next one")
    func answersAdvanceTheStart() {
        // No permission, a cloud engine: the user picks microphone only, then allows the cloud.
        var start = Start(title: "Standup")
        var step = start.nextStep(hasSystemAudioPermission: false, engineIsRemote: true)
        #expect(step == .askSystemAudioPermission)
        start.microphoneOnly = true
        step = start.nextStep(hasSystemAudioPermission: false, engineIsRemote: true)
        #expect(step == .askCloudTranscription)
        start.approvedCloud = true
        step = start.nextStep(hasSystemAudioPermission: false, engineIsRemote: true)
        #expect(step == .begin)
    }

    @Test("names a meeting after the request, the calendar event or the call app")
    func titles() {
        #expect(
            MeetingController.title(requested: "1:1", eventTitle: "Standup", offerAppName: "Zoom")
                == "1:1")
        #expect(
            MeetingController.title(requested: "  ", eventTitle: "Standup", offerAppName: "Zoom")
                == "Standup")
        let call = MeetingController.title(requested: nil, eventTitle: nil, offerAppName: "Zoom")
        #expect(call.contains("Zoom"))
        let plain = MeetingController.title(requested: nil, eventTitle: nil, offerAppName: nil)
        #expect(!plain.isEmpty)
        #expect(plain != call)
    }

    // MARK: - Interrupted meetings

    @Test("a meeting interrupted while recording fails, ending with its transcript")
    func interruptedWhileRecording() throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let meeting = Meeting(
            title: "Standup", startedAt: startedAt, status: .recording,
            segments: [
                MeetingSegment(source: .you, text: "Hi", start: 0, end: 4),
                MeetingSegment(source: .others, text: "Hello", start: 4, end: 90),
            ])
        let failed = try #require(MeetingController.interrupted(meeting, reason: "Quit"))
        #expect(failed.status == .failed)
        #expect(failed.failureReason == "Quit")
        #expect(failed.endedAt == startedAt.addingTimeInterval(90))
        #expect(failed.segments == meeting.segments)
    }

    @Test("an interrupted summary keeps the meeting's end")
    func interruptedWhileSummarizing() throws {
        let endedAt = Date(timeIntervalSince1970: 5_000)
        let meeting = Meeting(title: "Review", endedAt: endedAt, status: .summarizing)
        let failed = try #require(MeetingController.interrupted(meeting, reason: "Quit"))
        #expect(failed.status == .failed)
        #expect(failed.endedAt == endedAt)
    }

    @Test("an empty interrupted meeting has no end")
    func interruptedWithoutTranscript() throws {
        let meeting = Meeting(title: "Review", status: .recording)
        let failed = try #require(MeetingController.interrupted(meeting, reason: "Quit"))
        #expect(failed.endedAt == nil)
    }

    @Test("finished and failed meetings are left alone")
    func notInterrupted() {
        #expect(
            MeetingController.interrupted(Meeting(title: "A", status: .done), reason: "Quit")
                == nil)
        #expect(
            MeetingController.interrupted(Meeting(title: "B", status: .failed), reason: "Quit")
                == nil)
    }

    // MARK: - Summaries

    @Test("the summary is told about invited people who weren't heard")
    func unheardAttendees() {
        let meeting = Meeting(
            title: "Planning",
            participants: [
                MeetingParticipant(name: "You", isUser: true, spoke: false),
                MeetingParticipant(name: "Ada", spoke: false),
                MeetingParticipant(name: "Grace", spoke: true),
            ])
        #expect(MeetingController.unheardAttendees(of: meeting) == ["Ada"])
    }
}
