import MomoVoice
import Testing

@testable import MomoApp

@Suite("Live voice notices")
struct LiveVoiceNoticeTests {
    @Test("missing voice models point to Settings → Voice")
    func modelsMissing() {
        #expect(LiveVoiceNotice.modelsNotReady(.modelsMissing).action == .openVoiceSettings)
        #expect(LiveVoiceNotice.blocked(.modelsMissing).action == .openVoiceSettings)
        #expect(LiveVoiceNotice.blocked(.unsupportedLanguage).action == .openVoiceSettings)
    }

    @Test("a missing microphone permission points to the permission")
    func permissions() {
        #expect(LiveVoiceNotice.blocked(.microphoneDenied).action == .allowMicrophone)
    }

    @Test("never shows an engine's raw error")
    func noRawErrors() {
        let raw =
            "The operation couldn’t be completed. (com.apple.coreaudio.avfaudio error -10875.)"
        for notice in [LiveVoiceNotice.blocked(.other(raw)), .cloudFallback()] {
            #expect(!notice.message.contains("10875"))
            #expect(!notice.message.isEmpty)
        }
    }

    @Test("preparing models only need a moment, so there is nothing to press")
    func preparing() {
        #expect(LiveVoiceNotice.modelsNotReady(.preparing).action == nil)
        #expect(LiveVoiceNotice.blocked(.timedOut).action == nil)
    }
}
