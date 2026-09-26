import Foundation
import MomoVoice
import Observation

/// A spoken request answered in the caption bubble instead of the chat panel.
struct VoiceSession: Equatable {
    /// What the user said so far.
    var transcript = ""
    /// The user's message in the chat, once it was sent. The reply follows it.
    var messageID: UUID?
}

/// Connects dictation, spoken replies and the wake word to the assistant and the character.
///
/// Spoken requests from the shortcut or "Hey Momo" run in voice mode: Momo listens in the
/// notch, the caption bubble shows the transcript and the answer, and consent or
/// confirmation questions are asked aloud and can be answered with a spoken yes or no. The
/// exchange still lands in the chat. With the chat panel open, or when the user prefers it,
/// dictation goes into the panel's message field instead.
@MainActor
@Observable
final class VoiceController {
    private(set) var isListening = false
    /// Whether recorded speech is being transcribed (cloud engines work after recording).
    private(set) var isTranscribing = false
    private(set) var isSpeaking = false
    private(set) var level = 0.0
    private(set) var errorMessage: String?
    /// The spoken request shown in the caption bubble, if any.
    private(set) var session: VoiceSession?
    /// Whether Momo is listening for a spoken yes or no.
    private(set) var isAwaitingAnswer = false
    /// Whether the user is holding the shortcut to talk.
    private(set) var isHoldingToTalk = false

    @ObservationIgnored private var engine: (any DictationEngine)?
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var releasedWhileStarting = false
    /// Bumped when dictation is cancelled, so an engine that finishes starting afterwards is
    /// stopped again.
    @ObservationIgnored private var dictationGeneration = 0
    @ObservationIgnored private let answerListener = SpeechRecognizer()
    @ObservationIgnored private var answerTimeout: Task<Void, Never>?
    @ObservationIgnored private let appleVoice = SpeechSynthesizer()
    @ObservationIgnored private var cloudVoice: CloudSpeechSynthesizer?
    /// Runs when the current speech ends, instead of resuming the wake word.
    @ObservationIgnored private var afterSpeech: (() -> Void)?
    @ObservationIgnored private let wakeWord = WakeWordListener()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private weak var assistant: AssistantController?
    @ObservationIgnored private weak var character: CharacterController?
    /// The caption bubble for voice mode.
    @ObservationIgnored var bubble: VoiceBubbleController?
    /// Opens the chat panel.
    @ObservationIgnored var showPanel: (() -> Void)?
    /// Whether the chat panel is open.
    @ObservationIgnored var isPanelVisible: () -> Bool = { false }
    /// Whether meeting notes are being taken. The wake word stays off meanwhile, so talk in
    /// the meeting can't wake Momo.
    @ObservationIgnored var isTakingMeetingNotes: () -> Bool = { false }
    /// Whether the current message was spoken, so the reply is spoken too.
    @ObservationIgnored private var lastMessageWasSpoken = false

    init(settings: AppSettings, assistant: AssistantController, character: CharacterController) {
        self.settings = settings
        self.assistant = assistant
        self.character = character

        appleVoice.onStart = { [weak self] in self?.speechStarted() }
        appleVoice.onWord = { [weak self] in self?.character?.engine.pulseMouth() }
        appleVoice.onFinish = { [weak self] in self?.speechFinished() }

        answerListener.silenceTimeout = .seconds(1)
        answerListener.onFinal = { [weak self] text in self?.heardAnswer(text) }
        answerListener.onLevel = { [weak self] level in self?.level = level }

        wakeWord.onWake = { [weak self] command in self?.woke(command: command) }
        assistant.onReply = { [weak self] reply in self?.replyFinished(reply) }
        assistant.onPrompt = { [weak self] in self?.promptAppeared() }
        assistant.onRequestFinished = { [weak self] in self?.requestFinished() }
    }

    // MARK: - Shortcut

    /// The talk shortcut was pressed: starts or finishes a spoken request, or cancels one
    /// that is being answered. With push to talk, listening lasts while the key is held.
    func shortcutPressed() {
        if settings.preferences.pushToTalk {
            if session != nil, !isListening { cancelVoiceSession() }
            isHoldingToTalk = true
            beginSpokenRequest(continuous: true)
        } else if isListening {
            engine?.stop(deliver: true)
        } else if session != nil {
            cancelVoiceSession()
        } else {
            beginSpokenRequest(continuous: false)
        }
    }

    /// The talk shortcut was let go: with push to talk, sends what was said.
    func shortcutReleased() {
        guard settings.preferences.pushToTalk, isHoldingToTalk else { return }
        isHoldingToTalk = false
        if isStarting {
            releasedWhileStarting = true
        } else if isListening {
            engine?.stop(deliver: true)
        }
    }

    /// Starts listening for a request, in the bubble or in the chat panel.
    private func beginSpokenRequest(continuous: Bool) {
        if settings.preferences.opensChatForSpokenRequests || isPanelVisible() {
            showPanel?()
        } else {
            session = VoiceSession()
            bubble?.show()
        }
        startDictation(continuous: continuous)
    }

    // MARK: - Dictation

    /// Starts or stops dictation into the chat panel (the panel's microphone button).
    func toggleDictation() {
        if isListening {
            engine?.stop(deliver: true)
        } else {
            startDictation()
        }
    }

    func startDictation(continuous: Bool = false) {
        guard !isListening, !isStarting else { return }
        stopListeningForAnswer()
        stopSpeaking()
        errorMessage = nil
        wakeWord.stop()
        isStarting = true
        releasedWhileStarting = false
        let generation = dictationGeneration
        Task {
            do {
                try await startEngine(continuous: continuous)
                guard generation == dictationGeneration else {
                    engine?.stop(deliver: false)
                    engine = nil
                    return
                }
                isStarting = false
                isListening = true
                character?.showListening()
                if releasedWhileStarting {
                    releasedWhileStarting = false
                    engine?.stop(deliver: true)
                }
            } catch {
                guard generation == dictationGeneration else { return }
                isStarting = false
                errorMessage = error.localizedDescription
                character?.showTrouble()
                if session != nil {
                    bubble?.hide(after: .seconds(4)) { [weak self] in self?.endSession() }
                }
                startWakeWordIfEnabled()
            }
        }
    }

    /// Starts the chosen engine, falling back to Apple Speech when it cannot run.
    private func startEngine(continuous: Bool) async throws {
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
        let preferred = makeEngine(selection.kind, continuous: continuous)
        do {
            try await start(preferred)
        } catch {
            guard selection.kind != .appleSpeech else { throw error }
            errorMessage = String(
                format: L("%@ Momo listened with Apple Speech instead."),
                error.localizedDescription)
            try await start(makeEngine(.appleSpeech, continuous: continuous))
        }
    }

    private func start(_ engine: any DictationEngine) async throws {
        self.engine = engine
        try await engine.start(locale: Locale.current)
    }

    private func makeEngine(_ kind: DictationEngineKind, continuous: Bool) -> any DictationEngine {
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
        engine.isContinuous = continuous
        engine.onPartial = { [weak self] text in self?.heardPartial(text) }
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

    private func heardPartial(_ text: String) {
        if session != nil {
            session?.transcript = text
        } else {
            assistant?.draft = text
        }
    }

    private func finishDictation(_ text: String) {
        isListening = false
        isTranscribing = false
        isHoldingToTalk = false
        level = 0
        engine = nil
        guard !text.isEmpty else {
            character?.showIdle()
            if session != nil { endVoiceSession() }
            startWakeWordIfEnabled()
            return
        }
        send(text)
        startWakeWordIfEnabled()
    }

    /// Sends a spoken request, noting the message so the bubble can show its reply.
    private func send(_ text: String) {
        guard let assistant else { return }
        guard !assistant.isBusy else {
            errorMessage = L("Momo is still answering. Try again in a moment.")
            if session != nil {
                bubble?.hide(after: .seconds(3)) { [weak self] in self?.endSession() }
            }
            return
        }
        lastMessageWasSpoken = true
        assistant.send(text)
        if session != nil {
            session?.transcript = text
            session?.messageID = assistant.messages.last { $0.role == .user }?.id
        }
    }

    // MARK: - Voice session

    /// Cancels the spoken request: stops listening, speaking and answering, and hides the
    /// bubble. Escape and the shortcut do this.
    func cancelVoiceSession() {
        guard session != nil else { return }
        dictationGeneration += 1
        engine?.stop(deliver: false)
        engine = nil
        isListening = false
        isStarting = false
        isTranscribing = false
        isHoldingToTalk = false
        level = 0
        stopListeningForAnswer()
        afterSpeech = nil
        stopSpeaking()
        if let assistant, assistant.isBusy { assistant.stop() }
        character?.showIdle()
        endVoiceSession()
        startWakeWordIfEnabled()
    }

    /// Opens the chat on the spoken exchange; the reply keeps being read aloud.
    func openChatFromBubble() {
        endVoiceSession()
        showPanel?()
    }

    /// The chat panel opened, so it takes over from the bubble.
    func chatPanelDidOpen() {
        guard session != nil else { return }
        stopListeningForAnswer()
        endVoiceSession()
    }

    private func endVoiceSession() {
        bubble?.hide()
        endSession()
    }

    private func endSession() {
        session = nil
        isAwaitingAnswer = false
    }

    /// Fades the bubble out a little after the exchange is over.
    private func finishSessionSoon() {
        guard session != nil, !isListening, !isSpeaking, !isAwaitingAnswer,
            assistant?.isBusy != true
        else { return }
        bubble?.hide(after: .seconds(3.5)) { [weak self] in self?.endSession() }
    }

    private func requestFinished() {
        guard session != nil else { return }
        // A reply that is spoken ends the session when speech ends; anything else (an error,
        // a cancelled request) fades out now.
        if !isSpeaking, afterSpeech == nil { finishSessionSoon() }
    }

    // MARK: - Spoken questions

    /// A consent or confirmation question appeared: in voice mode, ask it aloud and listen
    /// for a yes or no.
    private func promptAppeared() {
        guard session != nil, let assistant else { return }
        bubble?.show()
        let question: String
        if let prompt = assistant.consentPrompt {
            question = String(format: L("Can I ask %@? Say yes or no."), prompt.brain.name)
        } else if let prompt = assistant.confirmationPrompt {
            question = prompt.summary + " " + L("Should I go ahead?")
        } else {
            return
        }
        afterSpeech = { [weak self] in self?.listenForAnswer() }
        speak(question)
    }

    private var hasOpenPrompt: Bool {
        assistant?.consentPrompt != nil || assistant?.confirmationPrompt != nil
    }

    private func listenForAnswer() {
        guard session != nil, hasOpenPrompt else { return }
        wakeWord.stop()
        Task {
            do {
                try await answerListener.start(locale: Locale.current)
                guard session != nil, hasOpenPrompt else {
                    answerListener.stop(deliver: false)
                    return
                }
                isAwaitingAnswer = true
                character?.showListening()
                answerTimeout?.cancel()
                answerTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(7))
                    guard !Task.isCancelled else { return }
                    self?.answerListener.stop(deliver: true)
                }
            } catch {
                startWakeWordIfEnabled()
            }
        }
    }

    private func stopListeningForAnswer() {
        answerTimeout?.cancel()
        answerTimeout = nil
        if answerListener.isListening { answerListener.stop(deliver: false) }
        isAwaitingAnswer = false
    }

    private func heardAnswer(_ text: String) {
        answerTimeout?.cancel()
        answerTimeout = nil
        isAwaitingAnswer = false
        level = 0
        startWakeWordIfEnabled()
        guard let assistant, session != nil else { return }
        // Without a clear answer the buttons stay in the bubble.
        guard let answer = SpeechText.answer(in: text) else { return }
        if assistant.consentPrompt != nil {
            assistant.answerConsent(answer == .yes ? .allowOnce : .useLocal)
        } else if assistant.confirmationPrompt != nil {
            assistant.answerConfirmation(answer == .yes)
            if answer == .yes { character?.showWorking() }
        }
    }

    // MARK: - Speaking

    private func replyFinished(_ reply: String) {
        let shouldSpeak =
            settings.preferences.speaksReplies || lastMessageWasSpoken || session != nil
        lastMessageWasSpoken = false
        guard shouldSpeak else { return }
        speak(reply)
    }

    /// Reads `text` aloud with the chosen voice. A cloud voice that fails falls back to the
    /// system voice.
    func speak(_ text: String) {
        wakeWord.stop()
        let pending = afterSpeech
        afterSpeech = nil
        stopSpeaking()
        afterSpeech = pending
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
        if session != nil { bubble?.show() }
    }

    private func speechFinished() {
        // A cancelled utterance reports its end late, after the next one started.
        guard !appleVoice.isSpeaking, cloudVoice?.isSpeaking != true else { return }
        isSpeaking = false
        character?.engine.setVoiceDriven(false)
        if let next = afterSpeech {
            afterSpeech = nil
            next()
            return
        }
        character?.showIdle()
        wakeWord.resume()
        finishSessionSoon()
    }

    func stopSpeaking() {
        appleVoice.stop()
        cloudVoice?.stop()
    }

    // MARK: - Wake word

    /// Whether Momo itself has the microphone open (dictation, a spoken answer, the wake word).
    var usesMicrophone: Bool { isListening || isAwaitingAnswer || wakeWord.isRunning }

    /// Turns the wake word off while meeting notes are taken, and back on afterwards.
    func meetingNotesChanged() {
        if isTakingMeetingNotes() {
            wakeWord.stop()
        } else {
            startWakeWordIfEnabled()
        }
    }

    /// Starts or stops the wake word listener to match the preference.
    func startWakeWordIfEnabled() {
        guard settings.preferences.wakeWordEnabled, !isTakingMeetingNotes() else {
            wakeWord.stop()
            return
        }
        guard !isListening, !isStarting, !isSpeaking, !isAwaitingAnswer else { return }
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
        character?.showCurious()
        guard command.split(separator: " ").count >= 2 else {
            beginSpokenRequest(continuous: false)
            return
        }
        if settings.preferences.opensChatForSpokenRequests || isPanelVisible() {
            showPanel?()
        } else {
            session = VoiceSession(transcript: command)
            bubble?.show()
        }
        send(command)
        startWakeWordIfEnabled()
    }
}

extension OpenAISpeechRequest {
    /// The name shown in the privacy log.
    var displayName: String { "OpenAI \(model) (\(voice))" }
}
