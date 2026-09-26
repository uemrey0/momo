import MomoVoice
import Testing

@testable import MomoApp

@Suite("Live voice notices")
struct LiveVoiceNoticeTests {
    @Test("missing voices point to Settings → Voice")
    func modelsMissing() {
        #expect(LiveVoiceNotice.helperNotReady(.modelsMissing).action == .openVoiceSettings)
        #expect(
            LiveVoiceNotice.fallback(from: .openSource, problem: .modelsMissing).action
                == .openVoiceSettings)
    }

    @Test("missing permissions point to the permission")
    func permissions() {
        #expect(LiveVoiceNotice.blocked(.microphoneDenied).action == .allowMicrophone)
        #expect(
            LiveVoiceNotice.blocked(.speechRecognitionDenied).action == .allowSpeechRecognition)
    }

    @Test("never shows an engine's raw error")
    func noRawErrors() {
        let raw =
            "The operation couldn’t be completed. (com.apple.coreaudio.avfaudio error -10875.)"
        let notices = [
            LiveVoiceNotice.fallback(from: .openSource, problem: .other(raw)),
            LiveVoiceNotice.fallback(from: .cloudRealtime, problem: .other(raw)),
            LiveVoiceNotice.classicFallback(problem: .other(raw)),
            LiveVoiceNotice.blocked(.other(raw)),
        ]
        for notice in notices {
            #expect(!notice.message.contains("10875"))
            #expect(!notice.message.isEmpty)
        }
    }

    @Test("timeouts and audio problems keep the conversation going without a button")
    func noButtonNeeded() {
        #expect(LiveVoiceNotice.fallback(from: .openSource, problem: .timedOut).action == nil)
        #expect(LiveVoiceNotice.classicFallback(problem: .audioDevice).action == nil)
        #expect(LiveVoiceNotice.helperNotReady(.preparing).action == nil)
    }
}
