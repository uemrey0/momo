import AVFoundation
import Foundation
import Testing

@testable import MomoVoice

@Suite("Sentence splitting")
struct SentenceSplitterTests {
    /// Streams `text` in chunks of `size` characters and returns every sentence, flushed.
    func split(_ text: String, chunk size: Int = 3) -> [String] {
        var splitter = SpeechSentenceSplitter()
        var sentences: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            sentences += splitter.append(String(text[index..<end]))
            index = end
        }
        return sentences + splitter.flush()
    }

    @Test("emits a sentence as soon as the next one starts")
    func streaming() {
        var splitter = SpeechSentenceSplitter()
        #expect(splitter.append("Hello there.").isEmpty)
        #expect(splitter.append(" How").isEmpty == false)
        #expect(splitter.append(" are you?").isEmpty)
        #expect(splitter.flush() == ["How are you?"])
    }

    @Test(
        "splits English and Turkish sentences, whatever the chunk size", arguments: [1, 2, 5, 50])
    func sentences(chunk: Int) {
        #expect(
            split("It's sunny today! Want me to add a reminder? Sure.", chunk: chunk) == [
                "It's sunny today!", "Want me to add a reminder?", "Sure.",
            ])
        #expect(
            split("Yarın hava güneşli. Saat 10.30'da toplantın var.", chunk: chunk) == [
                "Yarın hava güneşli.", "Saat 10.30'da toplantın var.",
            ])
    }

    @Test("keeps abbreviations, initials, decimals and ordinals inside the sentence")
    func abbreviations() {
        #expect(
            split("Dr. Smith said the price is 3.5 dollars. OK.") == [
                "Dr. Smith said the price is 3.5 dollars.", "OK.",
            ])
        #expect(
            split("J. K. Rowling wrote it, e.g. the first book. Nice.") == [
                "J. K. Rowling wrote it, e.g. the first book.", "Nice.",
            ])
        #expect(
            split("Ayın 5. günü Prof. Yılmaz geliyor. Tamam mı?") == [
                "Ayın 5. günü Prof. Yılmaz geliyor.", "Tamam mı?",
            ])
        #expect(split("Hmm... bakalım. Evet.") == ["Hmm... bakalım.", "Evet."])
    }

    @Test("speaks list items one by one without their markers")
    func lists() {
        #expect(
            split("You have three tasks:\n1. Buy milk\n2. Call **Ali**\n- Pay rent") == [
                "You have three tasks", "Buy milk", "Call Ali", "Pay rent",
            ])
    }

    @Test("drops Markdown, links, code, tables and emoji")
    func cleaning() {
        #expect(
            split(
                "Here's the [article](https://example.com/a.b). 🎉 Great!\n```swift\nlet x = 1.\n```\nDone ✅"
            ) == [
                "Here's the article.", "Great!", "Done",
            ])
        #expect(split("| Day | Temp |\n|---|---|\n| Mon | 20 |") == ["Day, Temp", "Mon, 20"])
        #expect(
            split("## Weather\nSee https://weather.com for more.") == ["Weather", "See for more."])
        #expect(SpeechSentenceSplitter.speakable("👍🏽") == "")
        #expect(SpeechSentenceSplitter.removingEmoji(from: "Room #1 ❤️ at 3*4") == "Room #1  at 3*4")
    }

    @Test("flushes what is left before a tool runs")
    func flushOnTool() {
        var splitter = SpeechSentenceSplitter()
        #expect(splitter.append("Let me check the weather").isEmpty)
        #expect(splitter.flush() == ["Let me check the weather"])
        #expect(splitter.append("It's 20 degrees. ").isEmpty)
        #expect(splitter.flush() == ["It's 20 degrees."])
    }

    @Test("cuts an overlong sentence at a pause")
    func longSentence() {
        var splitter = SpeechSentenceSplitter(maximumLength: 60)
        let text =
            "This is a sentence that goes on and on, with a comma in the middle, and keeps going without end"
        let sentences = splitter.append(text)
        #expect(sentences.first == "This is a sentence that goes on and on")
    }
}

@Suite("Turn detection")
struct TurnDetectionTests {
    @Test(
        "judges how finished a turn sounds",
        arguments: [
            ("What's the weather tomorrow?", TurnCompleteness.complete),
            ("Remind me to call mom.", .complete),
            ("Yarın hava nasıl olacak mı", .complete),
            ("Add milk and", .incomplete),
            ("Yarın toplantı var çünkü", .incomplete),
            ("Set a timer for", .incomplete),
            ("so,", .incomplete),
            ("What's the weather tomorrow", .neutral),
            ("Hello.", .neutral),
            ("", .neutral),
        ])
    func completeness(transcript: String, expected: TurnCompleteness) {
        #expect(TurnCompleteness.assess(transcript) == expected)
    }

    /// Feeds `levels` at 20 per second from `start` and returns each event with its time.
    func run(
        _ detector: inout LiveTurnDetector, _ levels: [Double], start: Double = 0,
        output: Bool = false
    ) -> [(Double, LiveTurnDetector.Event)] {
        levels.enumerated().compactMap { index, level in
            let time = start + Double(index) * 0.05
            let event = detector.process(level: level, at: time, isOutputActive: output)
            return event == .none ? nil : (time, event)
        }
    }

    @Test("a complete sentence ends after a short pause, a trailing one waits longer")
    func pauses() throws {
        var detector = LiveTurnDetector()
        var events = run(&detector, Array(repeating: 0.6, count: 10))
        #expect(events.map(\.1) == [.speechStarted])
        _ = detector.update(transcript: "What time is it?", at: 0.5)
        events = run(&detector, Array(repeating: 0.05, count: 40), start: 0.5)
        let completeEnd = try #require(events.first { $0.1 == .endOfTurn }?.0)
        #expect(completeEnd - 0.5 >= 0.6 && completeEnd - 0.5 < 0.7)

        _ = run(&detector, Array(repeating: 0.6, count: 10), start: 10)
        _ = detector.update(transcript: "Add eggs and", at: 10.5)
        events = run(&detector, Array(repeating: 0.05, count: 60), start: 10.5)
        let trailingEnd = try #require(events.first { $0.1 == .endOfTurn }?.0)
        #expect(trailingEnd - 10.5 >= 1.4)
    }

    @Test("speech without words is discarded, not sent")
    func noise() {
        var detector = LiveTurnDetector()
        _ = run(&detector, Array(repeating: 0.6, count: 6))
        let events = run(&detector, Array(repeating: 0.05, count: 40), start: 0.3)
        #expect(events.map(\.1) == [.discarded])
        #expect(!detector.hasSpeech)
    }

    @Test("talking over Momo needs a louder, longer sound")
    func bargeIn() {
        var detector = LiveTurnDetector()
        // Residual echo at 0.35 never counts while Momo talks.
        #expect(run(&detector, Array(repeating: 0.35, count: 40), output: true).isEmpty)
        // A short loud click is not enough either.
        #expect(run(&detector, [0.7, 0.7, 0.7, 0.1], start: 3, output: true).isEmpty)
        let events = run(&detector, Array(repeating: 0.7, count: 10), start: 5, output: true)
        #expect(events.map(\.1) == [.speechStarted])
        #expect(events.first.map { $0.0 - 5 } ?? 0 >= 0.3)
    }

    @Test("words count as speech, and unchanged words end a turn in a noisy room")
    func softAndNoisy() {
        var detector = LiveTurnDetector()
        #expect(detector.update(transcript: "turn on the lights", at: 1) == .speechStarted)
        #expect(detector.hasSpeech)
        // The room stays at 0.25: never loud enough for speech, never quiet enough to end.
        let events = run(&detector, Array(repeating: 0.25, count: 60), start: 1)
        let end = events.first { $0.1 == .endOfTurn }?.0 ?? 0
        #expect(end >= 1 + 2.4 && end < 1 + 2.6)
    }

    @Test("push to talk never ends a turn on a pause")
    func pushToTalk() {
        var detector = LiveTurnDetector(configuration: .init(endsTurnsOnPause: false))
        _ = run(&detector, Array(repeating: 0.6, count: 6))
        _ = detector.update(transcript: "Hello there.", at: 0.3)
        #expect(run(&detector, Array(repeating: 0.05, count: 100), start: 0.3).isEmpty)
    }
}

@Suite("Closing phrases")
struct ClosingPhraseTests {
    @Test(
        "recognises phrases that end the conversation",
        arguments: [
            "Thanks, that's all.", "teşekkürler", "Tamam bu kadar", "Okay, thanks Momo!",
            "thank you very much", "Sağ ol.", "Görüşürüz", "That's it, thanks.", "bye",
            "Tamam, teşekkür ederim",
        ])
    func closing(text: String) {
        #expect(SpeechText.isClosingPhrase(text))
    }

    @Test(
        "keeps going when there is a request",
        arguments: [
            "Thanks, and what about tomorrow?", "teşekkürler, yarın için de hatırlat", "okay",
            "tamam", "That's all I need for the shopping list, add eggs", "", "Is that all?",
        ])
    func notClosing(text: String) {
        #expect(!SpeechText.isClosingPhrase(text))
    }
}

@Suite("Live engine selection")
struct LiveEngineSelectionTests {
    @Test("automatic prefers the helper when its models are ready")
    func automatic() {
        #expect(
            LiveEngineSelector.select(.automatic, helperReady: true, cloudRealtimeReady: false)
                == .init(kind: .openSource))
        #expect(
            LiveEngineSelector.select(.automatic, helperReady: false, cloudRealtimeReady: true)
                == .init(kind: .apple))
    }

    @Test("an engine that can't run falls back to Apple and says so")
    func fallback() {
        #expect(
            LiveEngineSelector.select(.openSource, helperReady: false, cloudRealtimeReady: false)
                == .init(kind: .apple, isFallback: true))
        #expect(
            LiveEngineSelector.select(.cloudRealtime, helperReady: true, cloudRealtimeReady: false)
                == .init(kind: .apple, isFallback: true))
        #expect(
            LiveEngineSelector.select(.cloudRealtime, helperReady: false, cloudRealtimeReady: true)
                == .init(kind: .cloudRealtime))
        #expect(LiveEngineChoice.cloudRealtime.isRemote)
        #expect(!LiveEngineChoice.openSource.isRemote)
    }

    @Test(
        "automatic only picks the helper when it answers and its models are downloaded and warm",
        arguments: [
            LiveHelperStatus.unavailable, .notResponding, .modelsMissing, .preparing,
        ])
    func automaticNeedsAReadyHelper(status: LiveHelperStatus) {
        #expect(
            LiveEngineSelector.select(.automatic, helper: status, cloudRealtimeReady: true)
                == .init(kind: .apple))
        #expect(
            LiveEngineSelector.select(.openSource, helper: status, cloudRealtimeReady: false)
                == .init(kind: .apple, isFallback: true))
        #expect(
            LiveEngineSelector.select(.automatic, helper: .ready, cloudRealtimeReady: false)
                == .init(kind: .openSource))
    }
}

@Suite("Live start problems")
struct LiveStartProblemTests {
    @Test("classifies permission, language and audio errors")
    func dictation() {
        #expect(LiveStartProblem.classify(DictationError.microphoneDenied) == .microphoneDenied)
        #expect(
            LiveStartProblem.classify(DictationError.speechRecognitionDenied)
                == .speechRecognitionDenied)
        #expect(
            LiveStartProblem.classify(DictationError.unsupportedLanguage("xx"))
                == .unsupportedLanguage)
        #expect(LiveStartProblem.classify(LiveAudioError.noMicrophone) == .audioDevice)
        #expect(
            LiveStartProblem.classify(LiveAudioError.engineFailed(code: -10875)) == .audioDevice)
        // What AVAudioEngine throws when voice processing can't be set up.
        let engine = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10875)
        #expect(LiveStartProblem.classify(engine) == .audioDevice)
    }

    @Test("classifies the helper's failures from its messages")
    func helper() {
        #expect(LiveStartProblem.classify(LiveVoiceHelperError.noAnswer) == .timedOut)
        #expect(
            LiveStartProblem.classify(
                LiveVoiceHelperError.failed(
                    "These models need to be downloaded first: kokoro-82m, silero-vad."))
                == .modelsMissing)
        #expect(
            LiveStartProblem.classify(
                LiveVoiceHelperError.failed("Momo is not allowed to use the microphone."))
                == .microphoneDenied)
        #expect(
            LiveStartProblem.classify(
                LiveVoiceHelperError.failed("No speech recognition model understands xx."))
                == .unsupportedLanguage)
        #expect(
            LiveStartProblem.classify(LiveVoiceHelperError.failed("Something odd."))
                == .other("Something odd."))
    }

    @Test("falls back from the helper to Apple, from Apple to the classic flow")
    func fallbackPlan() {
        #expect(LiveFallbackPlan.next(after: .openSource, problem: .timedOut) == .appleLive)
        #expect(LiveFallbackPlan.next(after: .cloudRealtime, problem: .other("x")) == .appleLive)
        #expect(LiveFallbackPlan.next(after: .apple, problem: .audioDevice) == .classic)
        #expect(LiveFallbackPlan.next(after: .apple, problem: .other("x")) == .classic)
    }

    @Test("stops when a permission is missing, because no engine can listen")
    func permissionsStop() {
        for kind in [LiveEngineKind.openSource, .apple, .cloudRealtime] {
            #expect(LiveFallbackPlan.next(after: kind, problem: .microphoneDenied) == .stop)
            #expect(
                LiveFallbackPlan.next(after: kind, problem: .speechRecognitionDenied) == .stop)
        }
    }
}

@Suite("Apple live engine plumbing")
struct AppleLiveEngineTests {
    func buffer(
        channels: AVAudioChannelCount, frames: Int, value: (Int, Int) -> Float
    )
        throws -> AVAudioPCMBuffer
    {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: channels,
                interleaved: false))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<frames { data[channel][frame] = value(channel, frame) }
        }
        return buffer
    }

    @Test("keeps the first channel of voice-processed input")
    func mono() throws {
        let input = try buffer(channels: 2, frames: 8) { channel, frame in
            Float(channel * 100 + frame)
        }
        let mono = try #require(LiveInputRouter.mono(input))
        #expect(mono.format.channelCount == 1)
        #expect(mono.frameLength == 8)
        #expect(mono.floatChannelData?[0][5] == 5)
    }

    @Test("replays the last half second to a new target for barge-in")
    func preroll() throws {
        let router = LiveInputRouter()
        for _ in 0..<40 {
            router.receive(try buffer(channels: 1, frames: 1024) { _, _ in 0.1 })
        }
        let received = Counter()
        router.setTarget({ buffer in received.add(Int(buffer.frameLength)) }, withPreroll: true)
        #expect(received.value >= 24_000 - 1024 && received.value <= 24_000)
        router.setTarget({ buffer in received.add(Int(buffer.frameLength)) }, withPreroll: false)
        #expect(received.value <= 24_000)
    }

    @Test("a caller sending whole sentences is not kept waiting")
    func wholeSentences() {
        var splitter = SpeechSentenceSplitter()
        #expect(splitter.append("Hello there.").isEmpty)
        #expect(splitter.flushIfComplete() == ["Hello there."])
        #expect(splitter.append("And then").isEmpty)
        #expect(splitter.flushIfComplete().isEmpty)
    }
}

/// Counts from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    var value: Int { lock.withLock { total } }

    func add(_ amount: Int) {
        lock.withLock { total += amount }
    }
}
