import MomoVoice

/// What the user can do about a voice notice, offered as a button in the bubble.
enum VoiceNoticeAction: Equatable {
    /// Settings → Voice, where the open source voices are downloaded.
    case openVoiceSettings
    /// Settings → Permissions at the microphone.
    case allowMicrophone
    /// Settings → Permissions at speech recognition.
    case allowSpeechRecognition

    var title: String {
        switch self {
        case .openVoiceSettings: L("Open Voice Settings")
        case .allowMicrophone: L("Allow the Microphone")
        case .allowSpeechRecognition: L("Allow Speech Recognition")
        }
    }
}

/// A notice in the voice bubble when a live engine can't run: what happened in words the
/// user understands, and what to do about it. Never the engine's raw error.
struct LiveVoiceNotice: Equatable {
    var message: String
    var action: VoiceNoticeAction?

    /// The open source engine was chosen but can't run now, so Apple's engine talks.
    static func helperNotReady(_ status: LiveHelperStatus) -> LiveVoiceNotice {
        switch status {
        case .modelsMissing:
            LiveVoiceNotice(
                message: L(
                    "The open source voices aren't downloaded yet, so Momo is using Apple's voice. Download them in Settings → Voice."
                ),
                action: .openVoiceSettings)
        case .preparing:
            LiveVoiceNotice(
                message: L(
                    "The open source voices are getting ready for their first use, so Momo is using Apple's voice this time."
                ))
        case .notResponding:
            LiveVoiceNotice(
                message: L(
                    "The open source voice engine didn't answer, so Momo is using Apple's voice this time."
                ))
        case .unavailable, .ready:
            LiveVoiceNotice(
                message: L(
                    "The open source voice engine can't run on this Mac, so Momo is using Apple's voice."
                ))
        }
    }

    /// `kind` failed to start with `problem`, so Apple's live engine takes over.
    static func fallback(from kind: LiveEngineKind, problem: LiveStartProblem) -> LiveVoiceNotice {
        guard kind == .openSource else {
            return LiveVoiceNotice(
                message: L(
                    "Cloud realtime voice couldn't start, so Momo is using Apple's voice this time."
                ))
        }
        switch problem {
        case .modelsMissing:
            return helperNotReady(.modelsMissing)
        case .timedOut:
            return LiveVoiceNotice(
                message: L(
                    "The open source voice engine took too long to start, so Momo is using Apple's voice this time."
                ))
        case .audioDevice:
            return LiveVoiceNotice(
                message: L(
                    "The open source voice engine couldn't open the microphone or speakers, so Momo is using Apple's voice."
                ))
        default:
            return LiveVoiceNotice(
                message: L(
                    "The open source voice engine couldn't start, so Momo is using Apple's voice this time."
                ))
        }
    }

    /// No live engine could start, so the classic voice flow listens instead.
    static func classicFallback(problem: LiveStartProblem) -> LiveVoiceNotice {
        switch problem {
        case .audioDevice:
            LiveVoiceNotice(
                message: L(
                    "Live conversation couldn't open the microphone and speakers together, so Momo is listening the classic way. Say your request, then pause."
                ))
        default:
            LiveVoiceNotice(
                message: L(
                    "Live conversation couldn't start, so Momo is listening the classic way. Say your request, then pause."
                ))
        }
    }

    /// Nothing can listen until the user allows something.
    static func blocked(_ problem: LiveStartProblem) -> LiveVoiceNotice {
        switch problem {
        case .microphoneDenied:
            LiveVoiceNotice(
                message: L("Momo can't use the microphone. Allow it in Settings → Permissions."),
                action: .allowMicrophone)
        case .speechRecognitionDenied:
            LiveVoiceNotice(
                message: L(
                    "Momo can't use speech recognition. Allow it in Settings → Permissions."),
                action: .allowSpeechRecognition)
        case .unsupportedLanguage:
            LiveVoiceNotice(
                message: L("Speech recognition doesn't understand your Mac's language yet."))
        default:
            LiveVoiceNotice(message: L("Momo couldn't start listening. Try again in a moment."))
        }
    }
}
