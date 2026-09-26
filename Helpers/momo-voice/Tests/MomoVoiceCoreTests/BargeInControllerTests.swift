import Testing

@testable import MomoVoiceCore

@Suite("Barge-in")
struct BargeInControllerTests {
    @Test("speech while Momo is silent starts a turn")
    func silentMomo() {
        var controller = BargeInController(allowsBargeIn: true)
        #expect(controller.speechStarted(at: 1) == [.beginTurn])
        #expect(controller.isInTurn)
        #expect(controller.speechStarted(at: 1.5) == [])
        #expect(controller.speechEnded() == [])
        #expect(!controller.isInTurn)
    }

    @Test("sustained speech during playback interrupts it")
    func interrupts() {
        var controller = BargeInController(allowsBargeIn: true, minimumOverlap: 0.3)
        controller.playbackStarted(id: "7")
        #expect(controller.speechStarted(at: 2.0) == [])
        #expect(controller.speechContinues(at: 2.2) == [])
        #expect(controller.speechContinues(at: 2.31) == [.interrupt(id: "7"), .beginTurn])
        #expect(controller.playingID == nil)
        #expect(controller.isInTurn)
        #expect(controller.speechContinues(at: 3) == [])
    }

    @Test("short speech during playback is treated as echo")
    func discardsEcho() {
        var controller = BargeInController(allowsBargeIn: true, minimumOverlap: 0.3)
        controller.playbackStarted(id: "7")
        #expect(controller.speechStarted(at: 2.0) == [])
        #expect(controller.speechEnded() == [.discardSpeech])
        #expect(controller.playingID == "7")
        #expect(controller.playbackStopped() == [])
    }

    @Test("speech still going when playback ends becomes a turn")
    func playbackEndsFirst() {
        var controller = BargeInController(allowsBargeIn: true, minimumOverlap: 0.5)
        controller.playbackStarted(id: "1")
        _ = controller.speechStarted(at: 0)
        #expect(controller.playbackStopped() == [.beginTurn])
        #expect(controller.isInTurn)
    }

    @Test("without barge-in the user talks over Momo")
    func noBargeIn() {
        var controller = BargeInController(allowsBargeIn: false)
        controller.playbackStarted(id: "1")
        #expect(controller.speechStarted(at: 0) == [.beginTurn])
        #expect(controller.speechContinues(at: 5) == [])
        #expect(controller.playingID == "1")
    }

    @Test("a zero overlap interrupts at once")
    func immediate() {
        var controller = BargeInController(allowsBargeIn: true, minimumOverlap: 0)
        controller.playbackStarted(id: "x")
        #expect(controller.speechStarted(at: 0) == [.interrupt(id: "x"), .beginTurn])
        controller.reset()
        #expect(controller.playingID == nil)
        #expect(!controller.isInTurn)
    }
}
