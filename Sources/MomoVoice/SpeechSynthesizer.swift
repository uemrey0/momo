import AVFoundation
import Foundation

/// Reads text aloud with the system's voices and reports each word, for lip sync.
@MainActor
public final class SpeechSynthesizer: NSObject {
    /// Called when speech starts.
    public var onStart: (() -> Void)?
    /// Called for each word as it is spoken.
    public var onWord: (() -> Void)?
    /// Called when speech finishes or is stopped.
    public var onFinish: (() -> Void)?

    /// The user's chosen voice identifier; empty for automatic.
    public var preferredVoiceID = ""
    /// Speaking rate from 0.5 (slow) to 1.5 (fast).
    public var rateMultiplier: Float = 1

    private let synthesizer = AVSpeechSynthesizer()
    private let delegateProxy = Proxy()

    public override init() {
        super.init()
        delegateProxy.owner = self
        synthesizer.delegate = delegateProxy
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    /// All installed voices.
    public static var voices: [VoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            VoiceDescriptor(
                id: voice.identifier, name: voice.name, language: voice.language,
                quality: {
                    switch voice.quality {
                    case .premium: .premium
                    case .enhanced: .enhanced
                    default: .standard
                    }
                }())
        }
    }

    /// Speaks Markdown text in its own language.
    public func speak(_ markdown: String, fallbackLanguage: String = "en") {
        stop()
        let text = SpeechText.plain(fromMarkdown: markdown)
        guard !text.isEmpty else { return }
        let language = SpeechText.language(of: text) ?? fallbackLanguage
        let utterance = AVSpeechUtterance(string: text)
        if let descriptor = VoiceDescriptor.best(
            for: language, among: Self.voices,
            preferredID: preferredVoiceID.isEmpty ? nil : preferredVoiceID),
            let voice = AVSpeechSynthesisVoice(identifier: descriptor.id)
        {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * min(1.5, max(0.5, rateMultiplier))
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.speak(utterance)
    }

    public func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// Receives delegate callbacks off the main actor and forwards them.
    private final class Proxy: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        weak var owner: SpeechSynthesizer?

        func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
        ) {
            Task { @MainActor [weak self] in self?.owner?.onStart?() }
        }

        func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer,
            willSpeakRangeOfSpeechString characterRange: NSRange,
            utterance: AVSpeechUtterance
        ) {
            Task { @MainActor [weak self] in self?.owner?.onWord?() }
        }

        func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
        ) {
            Task { @MainActor [weak self] in self?.owner?.onFinish?() }
        }

        func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
        ) {
            Task { @MainActor [weak self] in self?.owner?.onFinish?() }
        }
    }
}
