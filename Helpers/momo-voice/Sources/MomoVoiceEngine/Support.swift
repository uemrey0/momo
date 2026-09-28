import Foundation

/// Diagnostics on standard error. Standard output carries the protocol only.
public enum Log {
    private static let lock = NSLock()
    private static let start = Date()

    /// Whether `info` lines are written; errors always are.
    nonisolated(unsafe) public static var isVerbose = true

    public static func info(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        write("momo-voice: \(message())")
    }

    public static func error(_ message: @autoclosure () -> String) {
        write("momo-voice: error: \(message())")
    }

    private static func write(_ line: String) {
        let elapsed = String(format: "%7.3f", Date().timeIntervalSince(start))
        lock.withLock {
            FileHandle.standardError.write(Data("[\(elapsed)] \(line)\n".utf8))
        }
    }
}

/// Why the engine could not do something.
///
/// Momo recognises some of these by their text ("need to be downloaded", "microphone" with
/// "not allowed", "No microphone"), so keep those phrasings.
public enum VoiceEngineError: Error, CustomStringConvertible, LocalizedError {
    case modelsMissing([String])
    case unknownModel(String)
    case unknownVoice(String)
    case noVoices(String)
    case customModelNotDownloadable(String)
    case sessionDoesNotSpeak
    case unreadableRecording(String)
    case microphoneDenied
    case noMicrophone
    case echoCancellationDisabled

    public var description: String {
        switch self {
        case .modelsMissing(let ids):
            "These models need to be downloaded first: \(ids.joined(separator: ", "))."
        case .unknownModel(let id):
            "Unknown model \(id)."
        case .unknownVoice(let voice):
            "The voice \(voice) does not exist."
        case .noVoices(let model):
            "The model \(model) has no voices."
        case .customModelNotDownloadable(let id):
            "The model \(id) was added from a folder and cannot be downloaded."
        case .sessionDoesNotSpeak:
            "This session only listens, so it cannot speak."
        case .unreadableRecording(let reason):
            "The recording cannot be read: \(reason)."
        case .microphoneDenied:
            "Momo is not allowed to use the microphone."
        case .noMicrophone:
            "No microphone is available."
        case .echoCancellationDisabled:
            "Echo cancellation was turned off."
        }
    }

    public var errorDescription: String? { description }
}
