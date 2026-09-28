import MomoVoice

/// What the user can do about a voice notice, offered as a button in the bubble.
enum VoiceNoticeAction: Equatable {
    /// Settings → Voice, where Momo's voice models are downloaded.
    case openVoiceSettings
    /// Settings → Permissions at the microphone.
    case allowMicrophone

    var title: String {
        switch self {
        case .openVoiceSettings: L("Open Voice Settings")
        case .allowMicrophone: L("Allow the Microphone")
        }
    }
}

/// A notice in the voice bubble when Momo can't listen or speak: what happened in words the
/// user understands, and what to do about it. Never an engine's raw error.
struct LiveVoiceNotice: Equatable {
    var message: String
    var action: VoiceNoticeAction?

    /// Momo's voice models can't run now, so voice mode doesn't start.
    static func modelsNotReady(_ status: LiveHelperStatus) -> LiveVoiceNotice {
        switch status {
        case .modelsMissing:
            LiveVoiceNotice(
                message: L(
                    "Momo's voice models aren't downloaded yet. Download them in Settings → Voice to talk with Momo."
                ),
                action: .openVoiceSettings)
        case .preparing:
            LiveVoiceNotice(
                message: L(
                    "Momo's voice models are getting ready for their first use. This takes a minute or two, once; try again shortly."
                ))
        case .notResponding:
            LiveVoiceNotice(
                message: L("Momo's voice engine didn't answer. Try again in a moment."),
                action: .openVoiceSettings)
        case .unavailable, .ready:
            LiveVoiceNotice(
                message: L(
                    "Momo's voice models need macOS 15 or later on a Mac with Apple silicon."))
        }
    }

    /// A cloud realtime session couldn't start, and Momo's voice models took over.
    static func cloudFallback() -> LiveVoiceNotice {
        LiveVoiceNotice(
            message: L(
                "Cloud realtime voice couldn't start, so Momo is using its own voice models this time."
            ))
    }

    /// The live engine failed to start with `problem`, and nothing else can take over.
    static func blocked(_ problem: LiveStartProblem) -> LiveVoiceNotice {
        switch problem {
        case .microphoneDenied:
            LiveVoiceNotice(
                message: L("Momo can't use the microphone. Allow it in Settings → Permissions."),
                action: .allowMicrophone)
        case .modelsMissing:
            modelsNotReady(.modelsMissing)
        case .unsupportedLanguage:
            LiveVoiceNotice(
                message: L("Momo's voice models don't understand your Mac's language yet."),
                action: .openVoiceSettings)
        case .timedOut:
            LiveVoiceNotice(
                message: L(
                    "Momo's voice models took too long to start. They're being prepared again; try again in a minute."
                ))
        case .audioDevice:
            LiveVoiceNotice(
                message: L(
                    "Momo couldn't open the microphone or the speakers. Check your audio devices and try again."
                ))
        case .other:
            LiveVoiceNotice(message: L("Momo couldn't start listening. Try again in a moment."))
        }
    }
}
