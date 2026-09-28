import Foundation
import MomoKit
import MomoLiveProtocol
import MomoVoice
import Observation

/// Momo's voice models can't run now, so a voice feature that needs them didn't start.
struct VoiceModelsNotReady: Error, Equatable {
    var status: LiveHelperStatus
}

/// A spoken request answered in the caption bubble instead of the chat panel.
struct VoiceSession: Equatable {
    /// What the user said so far.
    var transcript = ""
    /// The user's message in the chat, once it was sent. The reply follows it.
    var messageID: UUID?
}

/// A cloud realtime conversation that waits for the user to agree that audio leaves the Mac.
struct RealtimeConsentRequest: Equatable {
    /// The service's name, such as "OpenAI Realtime".
    var providerName: String
    var service: RealtimeVoiceService
    var firstTurn: String?
    var pushToTalk: Bool
}

/// Connects dictation, spoken replies and the wake word to the assistant and the character.
///
/// Everything that listens or speaks on this Mac runs on Momo's voice models in the
/// `momo-voice` helper. When they aren't downloaded or ready yet, voice mode doesn't start
/// and the bubble says why and where to fix it; cloud engines the user chose still work.
///
/// With live conversation on (the default), the shortcut and "Hey Momo" start a
/// ``LiveConversation`` instead: Momo listens continuously, speaks the reply while it
/// streams, can be interrupted, and listens for a follow-up. Otherwise a spoken request is
/// transcribed, sent, and the finished reply read aloud.
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
    /// What the user can do about ``errorMessage``, offered as a button in the bubble.
    private(set) var errorAction: VoiceNoticeAction?
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
    /// Listens for a spoken yes or no.
    @ObservationIgnored private var answerEngine: HelperDictationEngine?
    @ObservationIgnored private var answerTimeout: Task<Void, Never>?
    /// Reads replies aloud with Momo's voice models.
    @ObservationIgnored private let modelVoice: HelperSpeaker?
    @ObservationIgnored private var cloudVoice: CloudSpeechSynthesizer?
    /// Runs when the current speech ends, instead of resuming the wake word.
    @ObservationIgnored private var afterSpeech: (() -> Void)?
    @ObservationIgnored private let wakeWord: HelperWakeWordListener?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private weak var assistant: AssistantController?
    @ObservationIgnored private weak var character: CharacterController?
    /// The caption bubble for voice mode.
    @ObservationIgnored var bubble: VoiceBubbleController?
    /// Opens the chat panel.
    @ObservationIgnored var showPanel: (() -> Void)?
    /// Whether the chat panel is open.
    @ObservationIgnored var isPanelVisible: () -> Bool = { false }
    /// Opens a Settings pane.
    @ObservationIgnored var openSettings: ((SettingsPane) -> Void)?
    /// Opens Settings on the Permissions pane at a permission.
    @ObservationIgnored var openPermissions: ((MacPermission) -> Void)?
    /// Whether meeting notes are being taken. The wake word stays off meanwhile, so talk in
    /// the meeting can't wake Momo.
    @ObservationIgnored var isTakingMeetingNotes: () -> Bool = { false }
    /// Whether the current message was spoken, so the reply is spoken too.
    @ObservationIgnored private var lastMessageWasSpoken = false

    /// The live conversation's state, while one runs.
    private(set) var liveState: LiveConversation.State?
    /// Momo's voice models, for Settings.
    let liveModels: LiveVoiceModels
    @ObservationIgnored private var live: (any LiveConversing)?
    @ObservationIgnored private let liveBrain: AssistantLiveBrain
    /// Whether the live conversation runs with a cloud realtime model.
    private(set) var isRealtime = false
    /// What the realtime model says in its current response.
    private(set) var realtimeReply = ""
    /// Whether the realtime model handed a request to Momo's assistant that still runs.
    private(set) var isRealtimeWorking = false
    /// The running tool's activity label while the assistant works for the realtime model.
    private(set) var realtimeActivity: String?
    /// A cloud realtime conversation waiting for the user to agree that audio leaves the Mac.
    private(set) var realtimeConsent: RealtimeConsentRequest?
    @ObservationIgnored private let realtimeBrain: AssistantRealtimeBrain
    /// Set when a cloud realtime session failed, so the next conversation runs on the Mac.
    @ObservationIgnored private var realtimeFailedRecently = false
    /// The `momo-voice` helper, when it is installed and runs on this Mac.
    @ObservationIgnored private let liveHelper: LiveVoiceHelperClient?
    @ObservationIgnored private var liveReleasedWhileStarting = false

    init(settings: AppSettings, assistant: AssistantController, character: CharacterController) {
        self.settings = settings
        self.assistant = assistant
        self.character = character
        liveBrain = AssistantLiveBrain(assistant: assistant)
        realtimeBrain = AssistantRealtimeBrain(assistant: assistant)
        if LiveVoiceHelperClient.isSupportedOnThisMac, let path = AppSettings.liveVoiceHelperPath {
            let url = URL(fileURLWithPath: path)
            let helper = LiveVoiceHelperClient(executableURL: url)
            liveHelper = helper
            liveModels = LiveVoiceModels(
                client: helper, buildID: LiveVoiceModels.buildID(ofExecutableAt: url))
            wakeWord = HelperWakeWordListener(client: helper)
            let speaker = HelperSpeaker(client: helper)
            modelVoice = speaker
            speaker.configuration = { [weak self] language in
                self?.speechConfiguration(language: language)
                    ?? LiveSpeechConfiguration(locale: Locale(identifier: language))
            }
            speaker.onStart = { [weak self] in self?.speechStarted() }
            speaker.onLevel = { [weak self] level in
                self?.character?.engine.pulseMouth(strength: min(1, level * 1.3))
            }
            speaker.onFinish = { [weak self] in self?.speechFinished() }
            speaker.onError = { [weak self] message in
                self?.show(LiveVoiceNotice.blocked(LiveStartProblem.classify(message: message)))
            }
        } else {
            liveHelper = nil
            liveModels = LiveVoiceModels(client: nil)
            wakeWord = nil
            modelVoice = nil
        }

        wakeWord?.onWake = { [weak self] command in self?.woke(command: command) }
        assistant.onReply = { [weak self] reply in self?.replyFinished(reply) }
        assistant.onPrompt = { [weak self] in self?.promptAppeared() }
        assistant.onRequestFinished = { [weak self] in self?.requestFinished() }
        assistant.onPromptAnswered = { [weak self] in self?.liveBrain.promptAnswered() }
        realtimeBrain.onActivity = { [weak self] label in self?.realtimeActivity = label }
        Task { await prepareVoiceModels() }
    }

    // MARK: - Voice models

    /// Brings Momo's voice models up to date for the Mac's language and the user's choice:
    /// lists them and, when this helper build hasn't loaded them yet, loads them in the
    /// background, so no conversation waits on it. Runs at launch and when the choice changes.
    func prepareVoiceModels() async {
        guard liveHelper != nil else { return }
        syncModelChoice()
        await liveModels.refresh()
        if liveModels.status == .preparing, !liveModels.isPreparing {
            await liveModels.prepare()
        }
        startWakeWordIfEnabled()
    }

    private func syncModelChoice() {
        liveModels.locale = voiceLocale.identifier(.bcp47)
        let chosen = settings.preferences.voiceModel
        liveModels.textToSpeechModel = chosen.isEmpty ? nil : chosen
    }

    /// Where the voice models stand right now, asked fresh. Models that still need their
    /// first load start loading, so trying again shortly works.
    private func voiceModelStatus() async -> LiveHelperStatus {
        guard liveHelper != nil else { return .unavailable }
        syncModelChoice()
        await liveModels.refresh()
        let status = liveModels.status
        if status == .preparing, !liveModels.isPreparing {
            Task { await liveModels.prepare() }
        }
        return status
    }

    /// The language the user speaks to Momo: the one chosen in Settings, or the Mac's.
    var voiceLocale: Locale {
        Self.voiceLocale(settings.preferences.voiceLanguage)
    }

    /// The language code of ``voiceLocale``, e.g. "tr".
    var voiceLanguage: String {
        voiceLocale.language.languageCode?.identifier ?? "en"
    }

    /// The locale for a chosen language code; an empty code means the Mac's language. A code
    /// in the Mac's language keeps the Mac's region.
    static func voiceLocale(_ code: String) -> Locale {
        guard !code.isEmpty, code != Locale.current.language.languageCode?.identifier else {
            return Locale.current
        }
        if let region = Locale.current.region?.identifier {
            return Locale(identifier: "\(code)-\(region)")
        }
        return Locale(identifier: code)
    }

    /// A transcription service on Momo's voice models, for meeting notes.
    func onDeviceTranscription(locale: Locale) -> (any AudioTranscriptionService)? {
        liveHelper.map { HelperTranscriptionService(client: $0, locale: locale) }
    }

    /// Whether Momo's voice models can transcribe: the listening models are downloaded.
    /// Speaking isn't needed for that.
    func listeningModelsStatus() async -> LiveHelperStatus {
        guard liveHelper != nil else { return .unavailable }
        syncModelChoice()
        await liveModels.refresh()
        if liveModels.isPreparing || liveModels.canListen { return .ready }
        return liveModels.status == .ready ? .ready : .modelsMissing
    }

    /// The model and voice to speak `language` (a code such as "tr") with: the user's choice
    /// when it speaks the language, otherwise the helper's choice.
    func speechConfiguration(
        language: String, mode: LiveSessionMode = .speak
    )
        -> LiveSpeechConfiguration
    {
        let preferences = settings.preferences
        var configuration = LiveSpeechConfiguration(
            locale: language == voiceLanguage ? voiceLocale : Locale(identifier: language),
            mode: mode)
        let speaks = liveModels.speechModels(speaking: language).contains {
            $0.id == preferences.voiceModel
        }
        if !preferences.voiceModel.isEmpty, speaks {
            configuration.textToSpeechModel = preferences.voiceModel
            configuration.modelVoice = preferences.voiceName.isEmpty ? nil : preferences.voiceName
        }
        return configuration
    }

    // MARK: - Shortcut

    /// The talk shortcut was pressed: starts or finishes a spoken request, or cancels one
    /// that is being answered. With push to talk, listening lasts while the key is held.
    func shortcutPressed() {
        let pushToTalk = settings.preferences.pushToTalk
        if realtimeConsent != nil {
            cancelVoiceSession()
            return
        }
        if let live {
            if pushToTalk {
                isHoldingToTalk = true
                live.interrupt()
                live.holdsWindowOpen = true
            } else {
                cancelVoiceSession()
            }
            return
        }
        if usesLiveConversation {
            isHoldingToTalk = pushToTalk
            startLive(firstTurn: nil, pushToTalk: pushToTalk)
            return
        }
        if pushToTalk {
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
        if let live {
            if liveState == .starting {
                liveReleasedWhileStarting = true
            } else {
                live.holdsWindowOpen = false
                live.endTurn()
            }
            return
        }
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
        live?.end()
        stopListeningForAnswer()
        stopSpeaking()
        errorMessage = nil
        errorAction = nil
        wakeWord?.stop()
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
                let failed = engine
                engine = nil
                if let notReady = error as? VoiceModelsNotReady {
                    show(LiveVoiceNotice.modelsNotReady(notReady.status))
                } else if failed is CloudDictationEngine {
                    errorMessage = error.localizedDescription
                } else {
                    show(LiveVoiceNotice.blocked(LiveStartProblem.classify(error)))
                }
                character?.showTrouble()
                if session != nil {
                    bubble?.hide(after: .seconds(4)) { [weak self] in self?.endSession() }
                }
                startWakeWordIfEnabled()
            }
        }
    }

    /// Starts the chosen engine. Momo's voice models must be ready; a cloud engine the user
    /// chose runs without them.
    private func startEngine(continuous: Bool) async throws {
        engine?.stop(deliver: false)
        let preferences = settings.preferences
        let selection = DictationEngineSelector.select(
            preferences.dictationEngine, hasOpenAIKey: openAIKey != nil,
            hasGeminiKey: geminiKey != nil)
        if selection.isMissingKey {
            errorMessage = L(
                "The chosen speech engine needs an API key, so Momo listened with its own voice models instead."
            )
        }
        let engine: any DictationEngine
        if selection.kind.isRemote, let cloud = makeCloudEngine(selection.kind) {
            engine = cloud
        } else {
            let status = await voiceModelStatus()
            guard status == .ready, let liveHelper else {
                throw VoiceModelsNotReady(status: status)
            }
            engine = HelperDictationEngine(client: liveHelper)
        }
        engine.isContinuous = continuous
        engine.onPartial = { [weak self] text in self?.heardPartial(text) }
        engine.onFinal = { [weak self] text in self?.finishDictation(text) }
        engine.onLevel = { [weak self] level in self?.level = level }
        self.engine = engine
        try await engine.start(locale: voiceLocale)
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
        case .onDevice:
            return nil
        }
        let fallback = liveHelper.map { HelperTranscriptionService(client: $0) }
        let engine = CloudDictationEngine(service: service, fallback: fallback)
        engine.onTranscribing = { [weak self] in
            self?.isTranscribing = true
            self?.character?.showWorking()
        }
        engine.onUpload = { [weak self] name, seconds in
            self?.assistant?.recordOutbound(service: name, audioSeconds: seconds)
        }
        engine.onCloudFailure = { [weak self] error in
            self?.errorMessage = String(
                format: L(
                    "Cloud transcription failed, so Momo used its own voice models instead. %@"),
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
        if let live {
            live.end()
            endVoiceSession()
            return
        }
        if realtimeConsent != nil {
            realtimeConsent = nil
            liveState = nil
            isHoldingToTalk = false
            character?.showIdle()
            endVoiceSession()
            startWakeWordIfEnabled()
            return
        }
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
        live?.end()
        if realtimeConsent != nil { cancelVoiceSession() }
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
        if live != nil {
            liveBrain.requestFinished()
            realtimeBrain.requestFinished()
            return
        }
        guard session != nil else { return }
        // A reply that is spoken ends the session when speech ends; anything else (an error,
        // a cancelled request) fades out now.
        if !isSpeaking, afterSpeech == nil { finishSessionSoon() }
    }

    // MARK: - Spoken questions

    /// A consent or confirmation question appeared: in voice mode, ask it aloud and listen
    /// for a yes or no.
    private func promptAppeared() {
        if live != nil {
            bubble?.show()
            liveBrain.promptAppeared()
            realtimeBrain.promptAppeared()
            return
        }
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
        guard session != nil, hasOpenPrompt, let liveHelper, liveModels.status == .ready else {
            // Without the voice models the buttons in the bubble answer.
            return
        }
        wakeWord?.stop()
        let engine = HelperDictationEngine(client: liveHelper)
        engine.onFinal = { [weak self, weak engine] text in
            guard let self, let engine, self.answerEngine === engine else { return }
            self.heardAnswer(text)
        }
        engine.onLevel = { [weak self] level in self?.level = level }
        answerEngine = engine
        Task {
            do {
                try await engine.start(locale: voiceLocale)
                guard session != nil, hasOpenPrompt, answerEngine === engine else {
                    engine.stop(deliver: false)
                    return
                }
                isAwaitingAnswer = true
                character?.showListening()
                answerTimeout?.cancel()
                answerTimeout = Task { [weak self, weak engine] in
                    try? await Task.sleep(for: .seconds(7))
                    guard !Task.isCancelled else { return }
                    engine?.stop(deliver: true)
                    _ = self
                }
            } catch {
                if answerEngine === engine { answerEngine = nil }
                startWakeWordIfEnabled()
            }
        }
    }

    private func stopListeningForAnswer() {
        answerTimeout?.cancel()
        answerTimeout = nil
        let engine = answerEngine
        answerEngine = nil
        engine?.stop(deliver: false)
        isAwaitingAnswer = false
    }

    private func heardAnswer(_ text: String) {
        answerTimeout?.cancel()
        answerTimeout = nil
        answerEngine = nil
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
        guard live == nil else {
            // The live conversation spoke the reply while it streamed.
            lastMessageWasSpoken = false
            return
        }
        let shouldSpeak =
            settings.preferences.speaksReplies || lastMessageWasSpoken || session != nil
        lastMessageWasSpoken = false
        guard shouldSpeak else { return }
        speak(reply)
    }

    /// Reads `text` aloud with the chosen voice: Momo's voice models, or an OpenAI voice,
    /// which falls back to Momo's voice models when it fails. With `withVoiceModels`, the
    /// voice models speak whatever the choice is (Settings tests them).
    func speak(_ text: String, withVoiceModels: Bool = false) {
        wakeWord?.stop()
        let pending = afterSpeech
        afterSpeech = nil
        stopSpeaking()
        afterSpeech = pending
        if !withVoiceModels, settings.preferences.speechVoice == .openAI,
            let voice = makeCloudVoice()
        {
            let plain = SpeechText.plain(fromMarkdown: text)
            assistant?.recordOutbound(service: voice.request.displayName, characters: plain.count)
            voice.onError = { [weak self] error in
                self?.errorMessage = String(
                    format: L("The OpenAI voice failed, so Momo used its own voice. %@"),
                    error.localizedDescription)
                self?.speakWithModels(text)
            }
            voice.speak(text)
        } else {
            speakWithModels(text)
        }
    }

    private func speakWithModels(_ text: String) {
        let status = liveHelper == nil ? LiveHelperStatus.unavailable : liveModels.status
        guard let modelVoice, status == .ready else {
            show(LiveVoiceNotice.modelsNotReady(status))
            if status == .preparing || status == .notResponding {
                Task { await prepareVoiceModels() }
            }
            // Nothing is said, so whatever waited on it doesn't happen either.
            afterSpeech = nil
            finishSessionSoon()
            return
        }
        modelVoice.speak(
            text, fallbackLanguage: voiceLanguage)
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
        guard modelVoice?.isSpeaking != true, cloudVoice?.isSpeaking != true else { return }
        isSpeaking = false
        character?.engine.setVoiceDriven(false)
        if let next = afterSpeech {
            afterSpeech = nil
            next()
            return
        }
        character?.showIdle()
        wakeWord?.resume()
        finishSessionSoon()
    }

    func stopSpeaking() {
        live?.interrupt()
        modelVoice?.stop()
        cloudVoice?.stop()
    }

    // MARK: - Wake word

    /// Whether Momo itself has the microphone open (dictation, a spoken answer, the wake word).
    var usesMicrophone: Bool {
        isListening || isAwaitingAnswer || wakeWord?.isRunning == true || live != nil
    }

    /// Turns the wake word off while meeting notes are taken, and back on afterwards.
    func meetingNotesChanged() {
        if isTakingMeetingNotes() {
            live?.end()
            wakeWord?.stop()
        } else {
            startWakeWordIfEnabled()
        }
    }

    /// Starts or stops the wake word listener to match the preference. It runs on Momo's
    /// voice models, so it waits until they are ready.
    func startWakeWordIfEnabled() {
        guard let wakeWord else { return }
        guard settings.preferences.wakeWordEnabled, !isTakingMeetingNotes() else {
            wakeWord.stop()
            return
        }
        guard !isListening, !isStarting, !isSpeaking, !isAwaitingAnswer, live == nil,
            realtimeConsent == nil, liveModels.status == .ready
        else {
            return
        }
        if wakeWord.isRunning {
            wakeWord.resume()
            return
        }
        Task {
            do {
                try await wakeWord.start(locale: voiceLocale)
            } catch {
                wakeWord.stop()
                show(LiveVoiceNotice.blocked(LiveStartProblem.classify(error)))
            }
        }
    }

    private func woke(command: String) {
        character?.showCurious()
        if usesLiveConversation {
            let hasCommand = command.split(separator: " ").count >= 2
            startLive(firstTurn: hasCommand ? command : nil, pushToTalk: false)
            return
        }
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

// MARK: - Live conversation

extension VoiceController {
    /// Whether spoken requests run as a live conversation in the bubble.
    var usesLiveConversation: Bool {
        settings.preferences.liveConversation && !settings.preferences.opensChatForSpokenRequests
            && !isPanelVisible()
    }

    /// Whether a live conversation runs.
    var isLive: Bool { live != nil }

    /// Whether the bubble should show Momo listening to a turn.
    var showsListening: Bool {
        isListening || liveState == .listening || liveState == .starting
    }

    /// Whether Momo listens for a follow-up after answering.
    var isListeningForFollowUp: Bool { liveState == .followUp }

    /// Starts a live conversation in the bubble; `firstTurn` came with "Hey Momo".
    private func startLive(firstTurn: String?, pushToTalk: Bool) {
        stopListeningForAnswer()
        stopSpeaking()
        errorMessage = nil
        errorAction = nil
        wakeWord?.stop()
        if engine != nil {
            engine?.stop(deliver: false)
            engine = nil
            isListening = false
        }
        session = VoiceSession(transcript: firstTurn ?? "")
        bubble?.show()
        character?.showListening()
        liveState = .starting
        liveReleasedWhileStarting = false
        Task {
            guard let setup = await makeLiveIO() else {
                liveBlocked()
                return
            }
            switch setup {
            case .speech(let io, let kind):
                launchSpeechEngine(io: io, kind: kind, firstTurn: firstTurn, pushToTalk: pushToTalk)
            case .realtime(let service):
                guard session != nil, liveState == .starting else { return }
                if CloudRealtimeSetup.needsConsent(settings.preferences) {
                    askRealtimeConsent(
                        service: service, firstTurn: firstTurn, pushToTalk: pushToTalk)
                } else {
                    launchRealtime(service: service, firstTurn: firstTurn, pushToTalk: pushToTalk)
                }
            }
        }
    }

    private func launchSpeechEngine(
        io: any LiveSpeechIO, kind: LiveEngineKind, firstTurn: String?, pushToTalk: Bool
    ) {
        guard session != nil, liveState == .starting else { return }
        launch(
            makeLiveConversation(io: io, pushToTalk: pushToTalk), kind: kind,
            firstTurn: firstTurn, pushToTalk: pushToTalk)
    }

    private func launch(
        _ conversation: any LiveConversing, kind: LiveEngineKind, firstTurn: String?,
        pushToTalk: Bool
    ) {
        live = conversation
        isRealtime = kind == .cloudRealtime
        conversation.holdsWindowOpen = pushToTalk && isHoldingToTalk
        Task {
            do {
                try await conversation.start(firstTurn: firstTurn)
                guard live === conversation else { return }
                if liveReleasedWhileStarting {
                    liveReleasedWhileStarting = false
                    conversation.holdsWindowOpen = false
                    conversation.endTurn()
                }
            } catch {
                guard live === conversation else { return }
                live = nil
                isRealtime = false
                liveFailed(
                    kind: kind, problem: LiveStartProblem.classify(error), firstTurn: firstTurn,
                    pushToTalk: pushToTalk)
            }
        }
    }

    /// A live engine couldn't start: a failed cloud session hands over to Momo's voice
    /// models when they are ready; otherwise the user is told why and what to do about it.
    private func liveFailed(
        kind: LiveEngineKind, problem: LiveStartProblem, firstTurn: String?, pushToTalk: Bool
    ) {
        if kind == .onDevice, problem == .timedOut {
            // The models went cold (a new build, or the system dropped its cache): load them
            // again in the background before a conversation relies on them again.
            liveModels.forgetPrepared()
            Task { await liveModels.prepare() }
        }
        let helperReady = liveHelper != nil && liveModels.status == .ready
        let plan = LiveFallbackPlan.next(after: kind, problem: problem, helperReady: helperReady)
        if plan == .onDevice, let liveHelper {
            show(LiveVoiceNotice.cloudFallback())
            liveState = .starting
            launchSpeechEngine(
                io: HelperLiveSpeechIO(client: liveHelper), kind: .onDevice,
                firstTurn: firstTurn, pushToTalk: pushToTalk)
            return
        }
        show(LiveVoiceNotice.blocked(problem))
        liveBlocked()
    }

    /// No live engine can run: the bubble shows the notice a while and closes.
    private func liveBlocked() {
        liveState = nil
        isHoldingToTalk = false
        character?.showTrouble()
        bubble?.hide(after: .seconds(errorAction == nil ? 5 : 10)) { [weak self] in
            self?.endSession()
        }
        startWakeWordIfEnabled()
    }

    private func show(_ notice: LiveVoiceNotice) {
        errorMessage = notice.message
        errorAction = notice.action
    }

    /// The bubble's notice button was pressed.
    func performNoticeAction() {
        guard let action = errorAction else { return }
        switch action {
        case .openVoiceSettings: openSettings?(.voice)
        case .allowMicrophone: openPermissions?(.microphone)
        }
        cancelVoiceSession()
    }

    /// The engine a live conversation runs with.
    enum LiveEngineSetup {
        /// A speech layer in front of Momo's brain.
        case speech(any LiveSpeechIO, LiveEngineKind)
        /// A cloud realtime model that hands real work to Momo's brain.
        case realtime(RealtimeVoiceService)
    }

    /// The engine for the user's choice, or `nil` when none can run; the notice says why.
    private func makeLiveIO() async -> LiveEngineSetup? {
        let preferences = settings.preferences
        // Always ask: the helper must answer and have the language's models right now, or
        // the conversation would wait on a helper that can't start.
        let helper = await voiceModelStatus()
        let unavailable = CloudRealtimeSetup.unavailableReason(
            preferences, key: key(for:), recentFailure: realtimeFailedRecently)
        let selection = CloudRealtimeSetup.selectEngine(
            preferences, helper: helper, key: key(for:), recentFailure: realtimeFailedRecently)
        if preferences.liveEngine == .cloudRealtime {
            // One conversation on the Mac after a failure, then the cloud engine again.
            realtimeFailedRecently = false
        }
        switch selection.kind {
        case .cloudRealtime:
            if let service = CloudRealtimeSetup.service(preferences, key: key(for:)) {
                return .realtime(service)
            }
        case .onDevice:
            if let liveHelper {
                if selection.isFallback { errorMessage = realtimeFallbackMessage(unavailable) }
                return .speech(HelperLiveSpeechIO(client: liveHelper), .onDevice)
            }
        case nil:
            break
        }
        show(LiveVoiceNotice.modelsNotReady(helper))
        return nil
    }

    private func realtimeFallbackMessage(_ reason: CloudRealtimeSetup.Unavailable?) -> String {
        switch reason {
        case .localOnly:
            L(
                "Everything stays on this Mac, so Momo used its own voice models instead of cloud realtime voice."
            )
        case .recentFailure:
            L(
                "Cloud realtime voice failed last time, so Momo used its own voice models for this conversation."
            )
        case .missingKey, nil:
            L(
                "Cloud realtime voice needs an API key for the chosen service, so Momo used its own voice models."
            )
        }
    }

    private func makeLiveConversation(io: any LiveSpeechIO, pushToTalk: Bool) -> LiveConversation {
        let preferences = settings.preferences
        var speech = speechConfiguration(
            language: voiceLanguage,
            mode: .conversation)
        speech.locale = voiceLocale
        speech.endsTurnsOnPause = !pushToTalk
        let phrases = LiveConversationPhrases(
            acknowledgements: [L("Let me think."), L("Let me check."), L("On it.")],
            unclearAnswer: L("Sorry, was that a yes or a no?"),
            farewells: [L("Talk to you later!"), L("Bye for now!")],
            failure: L("Something went wrong. The details are in the chat."),
            busy: L("I'm still working on the last one."))
        let conversation = LiveConversation(
            io: io, brain: liveBrain, phrases: phrases,
            settings: .init(
                speech: speech,
                followUpWindow: max(0, preferences.liveFollowUpSeconds)),
            firstPhrase: Int.random(in: 0..<4))
        conversation.onTurn = { [weak self] text in self?.liveTurnSent(text) }
        observe(conversation)
        return conversation
    }

    /// Connects the conversation's events to the bubble and the character.
    private func observe(_ conversation: any LiveConversing) {
        conversation.onStateChange = { [weak self] state in self?.liveStateChanged(state) }
        conversation.onSpeakingChange = { [weak self] speaking in
            self?.liveSpeakingChanged(speaking)
        }
        conversation.onPartial = { [weak self] text in self?.livePartial(text) }
        conversation.onLevel = { [weak self] level in self?.level = level }
        conversation.onMouth = { [weak self] level in
            self?.character?.engine.pulseMouth(strength: min(1, level * 1.3))
        }
        conversation.onError = { [weak self] message in self?.errorMessage = message }
        conversation.onEnded = { [weak self, weak conversation] in
            guard let self, let conversation, self.live === conversation else { return }
            self.liveEnded()
        }
    }

    // MARK: - Cloud realtime

    /// Asks in the bubble whether audio may go to the provider, before the first cloud
    /// realtime conversation with it.
    private func askRealtimeConsent(
        service: RealtimeVoiceService, firstTurn: String?, pushToTalk: Bool
    ) {
        realtimeConsent = RealtimeConsentRequest(
            providerName: settings.preferences.realtimeProvider.displayName, service: service,
            firstTurn: firstTurn, pushToTalk: pushToTalk)
        character?.showCurious()
        bubble?.show()
    }

    /// The user answered the consent question in the bubble: talk with the cloud model, or
    /// use the built-in engine this time.
    func answerRealtimeConsent(_ allowed: Bool) {
        guard let request = realtimeConsent else { return }
        realtimeConsent = nil
        guard session != nil, liveState == .starting else { return }
        character?.showListening()
        if allowed {
            CloudRealtimeSetup.grantConsent(&settings.preferences)
            launchRealtime(
                service: request.service, firstTurn: request.firstTurn,
                pushToTalk: request.pushToTalk)
        } else if let liveHelper, liveModels.status == .ready {
            launchSpeechEngine(
                io: HelperLiveSpeechIO(client: liveHelper), kind: .onDevice,
                firstTurn: request.firstTurn, pushToTalk: request.pushToTalk)
        } else {
            show(LiveVoiceNotice.modelsNotReady(liveModels.status))
            liveBlocked()
        }
    }

    private func launchRealtime(service: RealtimeVoiceService, firstTurn: String?, pushToTalk: Bool)
    {
        let preferences = settings.preferences
        let conversation = RealtimeConversation(
            settings: .init(
                service: service,
                session: CloudRealtimeSetup.sessionConfiguration(preferences, locale: voiceLocale),
                followUpWindow: max(0, preferences.liveFollowUpSeconds), pushToTalk: pushToTalk),
            audio: RealtimeAudioEngine(), brain: realtimeBrain)
        observe(conversation)
        conversation.onAssistantTranscript = { [weak self] text in self?.realtimeReply = text }
        conversation.onWorkingChange = { [weak self] working in
            self?.isRealtimeWorking = working
            if !working { self?.realtimeActivity = nil }
        }
        conversation.onFailure = { [weak self] _ in self?.realtimeFailedRecently = true }
        conversation.onUsage = { [weak self] service, usage in
            self?.assistant?.recordOutbound(
                service: service, characters: usage.textCharactersSent,
                audioSeconds: usage.inputAudioSeconds)
        }
        launch(conversation, kind: .cloudRealtime, firstTurn: firstTurn, pushToTalk: pushToTalk)
    }

    private func liveStateChanged(_ state: LiveConversation.State) {
        if isRealtime, state == .listening, liveState != .listening, liveState != .starting {
            // The user talks again: the bubble shows them instead of the last reply.
            realtimeReply = ""
        }
        liveState = state
        isAwaitingAnswer = state == .awaitingAnswer
        switch state {
        case .listening, .followUp, .awaitingAnswer:
            if !isSpeaking { character?.showListening() }
        case .thinking:
            if !isSpeaking { character?.showWorking() }
        case .idle, .starting, .speaking, .awaitingButtons, .closing:
            break
        }
    }

    private func liveSpeakingChanged(_ speaking: Bool) {
        isSpeaking = speaking
        character?.engine.setVoiceDriven(speaking)
        if speaking {
            character?.showSpeaking()
            bubble?.show()
        } else if [.listening, .followUp, .awaitingAnswer].contains(liveState) {
            character?.showListening()
        }
    }

    private func livePartial(_ text: String) {
        // A new turn starts: the bubble shows it instead of the last reply.
        if session?.messageID != nil { session?.messageID = nil }
        session?.transcript = text
    }

    private func liveTurnSent(_ text: String) {
        session?.transcript = text
        session?.messageID = assistant?.messages.last { $0.role == .user }?.id
    }

    private func liveEnded() {
        live = nil
        liveState = nil
        isRealtime = false
        realtimeReply = ""
        isRealtimeWorking = false
        realtimeActivity = nil
        isSpeaking = false
        isAwaitingAnswer = false
        isHoldingToTalk = false
        level = 0
        character?.engine.setVoiceDriven(false)
        if assistant?.isBusy != true { character?.showIdle() }
        bubble?.hide(after: .seconds(1.5)) { [weak self] in self?.endSession() }
        startWakeWordIfEnabled()
    }
}
