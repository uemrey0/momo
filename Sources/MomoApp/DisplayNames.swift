import Foundation
import MomoFace

extension Mood {
    /// The mood's name as shown in the menu.
    var displayName: String {
        switch self {
        case .idle: String(localized: "Idle", bundle: .module, comment: "Mood name")
        case .happy: String(localized: "Happy", bundle: .module, comment: "Mood name")
        case .listening: String(localized: "Listening", bundle: .module, comment: "Mood name")
        case .thinking: String(localized: "Thinking", bundle: .module, comment: "Mood name")
        case .speaking: String(localized: "Speaking", bundle: .module, comment: "Mood name")
        case .focused: String(localized: "Focused", bundle: .module, comment: "Mood name")
        case .sleepy: String(localized: "Sleepy", bundle: .module, comment: "Mood name")
        case .surprised: String(localized: "Surprised", bundle: .module, comment: "Mood name")
        case .sad: String(localized: "Sad", bundle: .module, comment: "Mood name")
        case .love: String(localized: "In Love", bundle: .module, comment: "Mood name")
        case .music: String(localized: "Grooving", bundle: .module, comment: "Mood name")
        case .dizzy: String(localized: "Dizzy", bundle: .module, comment: "Mood name")
        }
    }
}

extension FaceEvent {
    /// The event's name as shown in the menu.
    var displayName: String {
        switch self {
        case .taskCompleted:
            String(localized: "Task Completed", bundle: .module, comment: "Simulated event")
        case .meetingSoon:
            String(localized: "Meeting in 5 Minutes", bundle: .module, comment: "Simulated event")
        case .newMail:
            String(localized: "New Email", bundle: .module, comment: "Simulated event")
        case .lowBattery:
            String(localized: "Low Battery", bundle: .module, comment: "Simulated event")
        case .failure:
            String(localized: "Something Failed", bundle: .module, comment: "Simulated event")
        case .screenSharingStarted:
            String(
                localized: "Screen Sharing Started", bundle: .module, comment: "Simulated event")
        case .screenSharingEnded:
            String(localized: "Screen Sharing Ended", bundle: .module, comment: "Simulated event")
        case .lateNight:
            String(localized: "It's 2 AM", bundle: .module, comment: "Simulated event")
        }
    }
}

extension BrainSource {
    /// The brain source's name as shown in the menu.
    var displayName: String {
        switch self {
        case .local:
            String(localized: "On This Mac", bundle: .module, comment: "Brain source name")
        case .subscription:
            String(localized: "My Subscription", bundle: .module, comment: "Brain source name")
        case .apiKey:
            String(localized: "API Key", bundle: .module, comment: "Brain source name")
        }
    }
}
