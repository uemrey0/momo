import Foundation
import MomoVoice
import Observation

/// Connects dictation, spoken replies and the wake word to the assistant and the character.
@MainActor
@Observable
final class VoiceController {
    private(set) var isListening = false
    private(set) var isSpeaking = false
    private(set) var level = 0.0
    private(set) var errorMessage: String?

    @ObservationIgnored private let recognizer = SpeechRecognizer()
    @ObservationIgnored private let synthesizer = SpeechSynthesizer()
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

        recognizer.onPartial = { [weak self] text in
            self?.assistant?.draft = text
        }
        recognizer.onFinal = { [weak self] text in self?.finishDictation(text) }
        recognizer.onLevel = { [weak self] level in self?.level = level }

        synthesizer.onStart = { [weak self] in
            self?.isSpeaking = true
            self?.character?.engine.setVoiceDriven(true)
            self?.character?.showSpeaking()
        }
        synthesizer.onWord = { [weak self] in self?.character?.engine.pulseMouth() }
        synthesizer.onFinish = { [weak self] in
            guard let self else { return }
            self.isSpeaking = false
            self.character?.engine.setVoiceDriven(false)
            self.character?.showIdle()
            self.wakeWord.resume()
        }

        wakeWord.onWake = { [weak self] command in self?.woke(command: command) }
        assistant.onReply = { [weak self] reply in self?.replyFinished(reply) }
    }

    // MARK: - Dictation

    func toggleDictation() {
        if isListening {
            recognizer.stop(deliver: true)
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
                try await recognizer.start(locale: Locale.current)
                isListening = true
                character?.showListening()
            } catch {
                errorMessage = error.localizedDescription
                character?.showTrouble()
                startWakeWordIfEnabled()
            }
        }
    }

    private func finishDictation(_ text: String) {
        isListening = false
        level = 0
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

    func speak(_ text: String) {
        wakeWord.stop()
        synthesizer.preferredVoiceID = settings.preferences.voiceIdentifier
        synthesizer.speak(
            text, fallbackLanguage: Locale.current.language.languageCode?.identifier ?? "en")
    }

    func stopSpeaking() {
        synthesizer.stop()
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
