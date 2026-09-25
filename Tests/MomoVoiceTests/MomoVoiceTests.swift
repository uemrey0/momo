import Testing

@testable import MomoVoice

@Suite("Speech text")
struct SpeechTextTests {
    @Test("strips Markdown before reading aloud")
    func stripsMarkdown() {
        let markdown = """
            ## Plan
            - **Call** [Ayşe](https://example.com) at `15:00`
            - _Buy_ milk
            ```swift
            print("hi")
            ```
            """
        let plain = SpeechText.plain(fromMarkdown: markdown)
        #expect(!plain.contains("*"))
        #expect(!plain.contains("#"))
        #expect(!plain.contains("http"))
        #expect(!plain.contains("print"))
        #expect(plain.contains("Call Ayşe at 15:00"))
        #expect(plain.contains("Buy milk"))
    }

    @Test("detects the language of a reply")
    func detectsLanguage() {
        #expect(SpeechText.language(of: "Yarın saat üçte Ayşe'yi aramanı hatırlatacağım.") == "tr")
        #expect(
            SpeechText.language(of: "I will remind you to call Ayşe tomorrow at three.") == "en")
    }
}

@Suite("Voice choice")
struct VoiceChoiceTests {
    let voices = [
        VoiceDescriptor(id: "yelda", name: "Yelda", language: "tr-TR", quality: .standard),
        VoiceDescriptor(id: "yelda-hq", name: "Yelda", language: "tr-TR", quality: .enhanced),
        VoiceDescriptor(id: "samantha", name: "Samantha", language: "en-US", quality: .standard),
        VoiceDescriptor(id: "daniel", name: "Daniel", language: "en-GB", quality: .enhanced),
        VoiceDescriptor(id: "kate", name: "Kate", language: "en-GB", quality: .standard),
    ]

    @Test("prefers the best quality voice for the language")
    func bestQuality() {
        #expect(VoiceDescriptor.best(for: "tr", among: voices)?.id == "yelda-hq")
        #expect(
            VoiceDescriptor.best(for: "en", among: voices, preferredRegion: "US")?.id == "daniel")
    }

    @Test("honours the user's voice when it speaks the language")
    func preferredVoice() {
        #expect(VoiceDescriptor.best(for: "en", among: voices, preferredID: "kate")?.id == "kate")
        #expect(
            VoiceDescriptor.best(for: "tr", among: voices, preferredID: "kate")?.id == "yelda-hq")
    }

    @Test("returns nothing for languages without voices")
    func missingLanguage() {
        #expect(VoiceDescriptor.best(for: "ja", among: voices) == nil)
    }
}

@Suite("Wake word")
struct WakeWordTests {
    let detector = WakeWordDetector()

    @Test(
        "hears Momo as a word",
        arguments: ["Hey Momo", "momo, what time is it", "Hey MOMO!", "Merhaba Momo"])
    func matches(_ transcript: String) {
        #expect(detector.matches(transcript))
    }

    @Test(
        "ignores Momo inside other words", arguments: ["momentum is key", "the memo", "Momotaro"])
    func ignores(_ transcript: String) {
        #expect(!detector.matches(transcript))
    }

    @Test("extracts the command after the wake word")
    func command() {
        #expect(detector.command(in: "Hey Momo, what time is it?") == "what time is it")
        #expect(detector.command(in: "Hey Momo") == "")
    }
}
