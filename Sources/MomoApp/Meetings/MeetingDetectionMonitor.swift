import AppKit
import MomoKit
import MomoVoice

/// Notices when a meeting seems to start and offers to take notes: a notification with a
/// "Take notes" button, a curious look from the character and a card in the Meetings tab.
///
/// It only reads state (the calendar, which processes use the microphone, running apps) and
/// never records; ``MeetingDetector`` makes the decision. Each calendar event is offered
/// once, and a call without an event once until its app stops using the microphone.
@MainActor
final class MeetingDetectionMonitor {
    private let settings: AppSettings
    private let calendar: CalendarService
    private weak var meetings: MeetingController?
    /// Posts the offer as a notification, with the offer's key as its identifier.
    var notify: ((MeetingDetector.Offer) -> Void)?
    /// Whether Momo itself is listening, which older systems can't tell apart from other apps.
    var isMomoListening: () -> Bool = { false }

    private var tick: Task<Void, Never>?
    private var offered: Set<String> = []
    private var quietChecks = 0

    init(settings: AppSettings, calendar: CalendarService, meetings: MeetingController) {
        self.settings = settings
        self.calendar = calendar
        self.meetings = meetings
    }

    func start() {
        tick = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func check() {
        guard settings.preferences.offersMeetingNotes, let meetings, meetings.phase == .idle
        else { return }
        let offer = MeetingDetector.offer(for: signals())
        guard let offer else {
            // The call ended: calls without an event may be offered again next time, and an
            // unanswered offer goes away.
            quietChecks += 1
            if quietChecks >= 2 {
                offered = offered.filter { !$0.hasPrefix("app-") }
                meetings.dismissOffer()
            }
            return
        }
        quietChecks = 0
        guard !offered.contains(offer.key) else { return }
        offered.insert(offer.key)
        meetings.offer(offer)
        notify?(offer)
    }

    private func signals(now: Date = Date()) -> MeetingDetector.Signals {
        let events =
            calendar.isAuthorized
            ? calendar.events(
                from: now.addingTimeInterval(-6 * 3600), to: now.addingTimeInterval(10 * 60)
            )
            .map(CalendarService.meeting(from:)) : []
        let users = MicrophoneActivity.inputProcessBundleIDs()
        let workspace = NSWorkspace.shared
        return MeetingDetector.Signals(
            now: now, events: events, microphoneUsers: users,
            microphoneInUse: users == nil && MicrophoneActivity.isDefaultInputRunning
                && !isMomoListening(),
            runningApps: workspace.runningApplications.compactMap(\.bundleIdentifier),
            frontmostApp: workspace.frontmostApplication?.bundleIdentifier)
    }
}
