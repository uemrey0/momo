import Foundation
import MomoVoice
import Observation

/// Connects dictation, spoken replies and the wake word to the assistant and the character.
@MainActor
@Observable
final class VoiceController {
    private(set) var isListening = false
    /// Whether recorded speech is being transcribed (cloud engines work after recording).
    private(set) var isTranscribing = false
    private(set) var isSpeaking = false
    private(set) var level = 0.0
    private(set) var errorMessage: String?

    @ObservationIgnored private var engine: (any DictationEngine)?
    @ObservationIgnored private let appleVoice = SpeechSynthesizer()
    @ObservationIgnored private var cloudVoice: CloudSpeechSynthesizer?
    @ObservationIgnored private let wakeWord = WakeWordListener()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private weak var assistant: AssistantController?
    @ObservationIgnored private weak var character: CharacterController?
    /// Opens the chat panel, for the wake word.
    @ObservationIgnored var showPanel: (() -> Void)?
    /// Whether the current message was spoken, so the reply is spoken too.
    @ObservationIgnored private var lastMessageWasSpoken = false

    init(settings: AppSettings, assistant: AssistantController, character: CharacterController) {
        self.settings = settings
        self.assistant = assistant
        self.character = character

        appleVoice.onStart = { [weak self] in self?.speechStarted() }
        appleVoice.onWord = { [weak self] in self?.character?.engine.pulseMouth() }
        appleVoice.onFinish = { [weak self] in self?.speechFinished() }

        wakeWord.onWake = { [weak self] command in self?.woke(command: command) }
        assistant.onReply = { [weak self] reply in self?.replyFinished(reply) }
    }

    // MARK: - Dictation

    func toggleDictation() {
        if isListening {
            engine?.stop(deliver: true)
        } else {
            startDictation()
        }
    }

    func startDictation() {
        guard !isListening else { return }
        stopSpeaking()
        errorMessage = nil
        wakeWord.stop()
        Task {
            do {
                try await startEngine()
                isListening = true
                character?.showListening()
            } catch {
                errorMessage = error.localizedDescription
                character?.showTrouble()
                startWakeWordIfEnabled()
            }
        }
    }

    /// Starts the chosen engine, falling back to Apple Speech when it cannot run.
    private func startEngine() async throws {
        engine?.stop(deliver: false)
        let preferences = settings.preferences
        let selection = DictationEngineSelector.select(
            preferences.dictationEngine,
            speechAnalyzerAvailable: DictationEngineSelector.isSpeechAnalyzerAvailable,
            hasOpenAIKey: openAIKey != nil, hasGeminiKey: geminiKey != nil)
        if selection.isMissingKey {
            errorMessage = L(
                "The chosen speech engine needs an API key, so Momo listened on this Mac instead.")
        }
        let preferred = makeEngine(selection.kind)
        do {
            try await start(preferred)
        } catch {
            guard selection.kind != .appleSpeech else { throw error }
            errorMessage = String(
                format: L("%@ Momo listened with Apple Speech instead."),
                error.localizedDescription)
            try await start(makeEngine(.appleSpeech))
        }
    }

    private func start(_ engine: any DictationEngine) async throws {
        self.engine = engine
        try await engine.start(locale: Locale.current)
    }

    private func makeEngine(_ kind: DictationEngineKind) -> any DictationEngine {
        let engine: any DictationEngine
        switch kind {
        case .appleSpeech:
            engine = SpeechRecognizer()
        case .speechAnalyzer:
            if #available(macOS 26, *) {
                let analyzer = AnalyzerDictationEngine()
                analyzer.onPreparing = { [weak self] _ in
                    self?.errorMessage = L("Downloading the speech model for your language…")
                }
                engine = analyzer
            } else {
                engine = SpeechRecognizer()
            }
        case .openAI, .gemini:
            engine = makeCloudEngine(kind) ?? SpeechRecognizer()
        }
        engine.onPartial = { [weak self] text in self?.assistant?.draft = text }
        engine.onFinal = { [weak self] text in self?.finishDictation(text) }
        engine.onLevel = { [weak self] level in self?.level = level }
        return engine
    }

    private func makeCloudEngine(_ kind: DictationEngineKind) -> CloudDictationEngine? {
        let service: any AudioTranscriptionService
        switch kind {
        case .openAI:
            guard let key = openAIKey else { return nil }
            service = OpenAITranscriptionService(
                apiKey: key,
                model: OpenAITranscriptionService.Model(
                    rawValue: settings.preferences.openAITranscriptionModel)
                    ?? OpenAITranscriptionService.defaultModel)
        case .gemini:
            guard let key = geminiKey else { return nil }
            service = GeminiTranscriptionService(apiKey: key)
        default:
            return nil
        }
        let engine = CloudDictationEngine(service: service)
        engine.onTranscribing = { [weak self] in
            self?.isTranscribing = true
            self?.character?.showWorking()
        }
        engine.onUpload = { [weak self] name, seconds in
            self?.assistant?.recordOutbound(service: name, audioSeconds: seconds)
        }
        engine.onCloudFailure = { [weak self] error in
            self?.errorMessage = String(
                format: L("Cloud transcription failed, so Momo used Apple Speech instead. %@"),
                error.localizedDescription)
        }
        return engine
    }

    private var openAIKey: String? { key(for: "openai") }
    private var geminiKey: String? { key(for: "gemini-api") }

    private func key(for providerID: String) -> String? {
        guard let key = settings.keys.key(for: providerID), !key.isEmpty else { return nil }
        return key
    }

    private func finishDictation(_ text: String) {
        isListening = false
        isTranscribing = false
        level = 0
        engine = nil
        guard !text.isEmpty else {
            character?.showIdle()
            startWakeWordIfEnabled()
            return
        }
        lastMessageWasSpoken = true
        assistant?.send(text)
        startWakeWordIfEnabled()
    }

    // MARK: - Speaking

    private func replyFinished(_ reply: String) {
        let shouldSpeak = settings.preferences.speaksReplies || lastMessageWasSpoken
        lastMessageWasSpoken = false
        guard shouldSpeak else { return }
        speak(reply)
    }

    /// Reads `text` aloud with the chosen voice. A cloud voice that fails falls back to the
    /// system voice.
    func speak(_ text: String) {
        wakeWord.stop()
        stopSpeaking()
        if settings.preferences.speechVoice == .openAI, let voice = makeCloudVoice() {
            let plain = SpeechText.plain(fromMarkdown: text)
            assistant?.recordOutbound(service: voice.request.displayName, characters: plain.count)
            voice.onError = { [weak self] error in
                self?.errorMessage = String(
                    format: L("The OpenAI voice failed, so Momo used a system voice. %@"),
                    error.localizedDescription)
                self?.speakWithAppleVoice(text)
            }
            voice.speak(text)
        } else {
            speakWithAppleVoice(text)
        }
    }

    private func speakWithAppleVoice(_ text: String) {
        appleVoice.preferredVoiceID = settings.preferences.voiceIdentifier
        appleVoice.speak(
            text, fallbackLanguage: Locale.current.language.languageCode?.identifier ?? "en")
    }

    private func makeCloudVoice() -> CloudSpeechSynthesizer? {
        guard let key = openAIKey else { return nil }
        let request = OpenAISpeechRequest(
            apiKey: key, voice: settings.preferences.openAIVoice,
            instructions: "Speak warmly and naturally, like a friendly little companion.")
        let voice = cloudVoice ?? CloudSpeechSynthesizer(request: request)
        voice.request = request
        voice.onStart = { [weak self] in self?.speechStarted() }
        voice.onLevel = { [weak self] level in
            self?.character?.engine.pulseMouth(strength: min(1, level * 1.3))
        }
        voice.onFinish = { [weak self] in self?.speechFinished() }
        cloudVoice = voice
        return voice
    }

    private func speechStarted() {
        isSpeaking = true
        character?.engine.setVoiceDriven(true)
        character?.showSpeaking()
    }

    private func speechFinished() {
        isSpeaking = false
        character?.engine.setVoiceDriven(false)
        character?.showIdle()
        wakeWord.resume()
    }

    func stopSpeaking() {
        appleVoice.stop()
        cloudVoice?.stop()
    }

    // MARK: - Wake word

    /// Starts or stops the wake word listener to match the preference.
    func startWakeWordIfEnabled() {
        guard settings.preferences.wakeWordEnabled else {
            wakeWord.stop()
            return
        }
        guard !isListening, !isSpeaking else { return }
        if wakeWord.isRunning {
            wakeWord.resume()
            return
        }
        Task {
            do {
                try await wakeWord.start(locale: Locale.current)
            } catch {
                errorMessage = error.localizedDescription
                settings.preferences.wakeWordEnabled = false
            }
        }
    }

    private func woke(command: String) {
        showPanel?()
        character?.showCurious()
        if command.split(separator: " ").count >= 2 {
            lastMessageWasSpoken = true
            assistant?.send(command)
            startWakeWordIfEnabled()
        } else {
            startDictation()
        }
    }
}

extension OpenAISpeechRequest {
    /// The name shown in the privacy log.
    var displayName: String { "OpenAI \(model) (\(voice))" }
}
