import Foundation

/// Listens for "Hey Momo" in the background with on-device speech recognition.
///
/// Speech recognition sessions are limited in length, so the listener restarts its session
/// regularly. It pauses while dictation is running.
@MainActor
public final class WakeWordListener {
    /// Called with whatever the user said after the wake word (may be empty).
    public var onWake: ((String) -> Void)?
    public private(set) var isRunning = false

    private let recognizer = SpeechRecognizer()
    private let detector = WakeWordDetector()
    private var restartTask: Task<Void, Never>?
    private var locale = Locale.current
    private var heardWake = false

    public init() {
        recognizer.isContinuous = true
        recognizer.onPartial = { [weak self] text in self?.heard(text) }
        recognizer.onFinal = { [weak self] _ in self?.scheduleRestart(after: .milliseconds(200)) }
    }

    public func start(locale: Locale = .current) async throws {
        self.locale = locale
        isRunning = true
        try await listen()
    }

    public func stop() {
        isRunning = false
        restartTask?.cancel()
        restartTask = nil
        recognizer.stop(deliver: false)
    }

    private func listen() async throws {
        guard isRunning else { return }
        heardWake = false
        try await recognizer.start(locale: locale)
        // Recognition sessions are limited to about a minute; start a fresh one regularly.
        scheduleRestart(after: .seconds(50))
    }

    private func heard(_ transcript: String) {
        guard !heardWake, detector.matches(transcript) else { return }
        heardWake = true
        // Give the user a moment to finish the sentence after "Hey Momo".
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled else { return }
            self.recognizer.stop(deliver: false)
            self.onWake?(self.detector.command(in: transcript))
        }
    }

    private func scheduleRestart(after delay: Duration) {
        guard isRunning, !heardWake else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.recognizer.stop(deliver: false)
            try? await self.listen()
        }
    }

    /// Resumes listening after the conversation triggered by the wake word ends.
    public func resume() {
        guard isRunning else { return }
        heardWake = false
        scheduleRestart(after: .milliseconds(300))
    }
}
