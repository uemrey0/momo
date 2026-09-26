import AppKit
import MomoVoice
import SwiftUI

/// Meeting notes: offering to take notes, the language, keeping audio and hearing the call.
struct MeetingsSettingsView: View {
    @Bindable var settings: AppSettings
    var model: AppModel

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        Form {
            MeetingNotesSection(settings: settings, model: model)
        }
        .formStyle(.grouped)
    }
}

/// Meeting notes settings: offering to take notes, the language, keeping audio and the call
/// audio permission.
struct MeetingNotesSection: View {
    @Bindable var settings: AppSettings
    var model: AppModel
    @State private var hasCallAudio = MeetingAudioCapture.hasSystemAudioPermission

    /// Languages offered for meetings, besides following the system.
    private static let languages = [
        "en", "tr", "de", "fr", "es", "it", "pt", "nl", "pl", "sv", "ru", "ar", "hi", "ja", "ko",
        "zh",
    ]

    var body: some View {
        Section {
            Toggle(L("Offer to take meeting notes"), isOn: $settings.preferences.offersMeetingNotes)
            Picker(L("Meeting language"), selection: $settings.preferences.meetingLanguage) {
                Text(verbatim: L("Same as the Mac")).tag("")
                ForEach(Self.languages, id: \.self) { code in
                    Text(verbatim: Locale.current.localizedString(forLanguageCode: code) ?? code)
                        .tag(code)
                }
            }
            Toggle(L("Keep meeting audio"), isOn: $settings.preferences.keepsMeetingAudio)
            if settings.preferences.keepsMeetingAudio {
                Button(L("Show Meeting Audio in Finder")) {
                    let folder = AppSettings.meetingsDirectory
                    try? FileManager.default.createDirectory(
                        at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
            }
            LabeledContent(L("Call audio")) {
                if hasCallAudio {
                    Text(verbatim: L("Allowed"))
                } else {
                    Button(L("Allow…")) {
                        MeetingAudioCapture.requestSystemAudioPermission()
                        hasCallAudio = MeetingAudioCapture.hasSystemAudioPermission
                    }
                }
            }
        } header: {
            Text(verbatim: L("Meeting notes"))
        } footer: {
            Text(verbatim: footnote)
        }
        .onAppear { hasCallAudio = MeetingAudioCapture.hasSystemAudioPermission }
    }

    private var footnote: String {
        let offer = L(
            "When a meeting app uses the microphone during a calendar event, Momo asks whether to take notes. It never records without your yes, and shows a red dot while it does."
        )
        let engine: String
        if settings.preferences.brains.localOnly || !settings.preferences.dictationEngine.isRemote {
            engine = L(
                "Meetings are transcribed on this Mac with the speech recognition chosen in Voice.")
        } else {
            engine = L(
                "Meetings are transcribed by the cloud service chosen in Voice, which tells the other speakers apart; Momo asks before each meeting, and you can pick this Mac instead."
            )
        }
        let audio =
            settings.preferences.keepsMeetingAudio
            ? L("Audio is saved as WAV files in Momo's Meetings folder.")
            : L("Audio is kept in memory only and never saved.")
        let permission = L(
            "Hearing the call needs the Screen Recording permission; Momo only captures sound. Without it, Momo takes notes from your microphone only."
        )
        return [offer, engine, audio, permission].joined(separator: " ")
    }
}
