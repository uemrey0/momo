import Foundation

/// An app people hold calls in.
public struct MeetingApp: Sendable, Hashable {
    public var name: String
    /// Bundle identifiers, or prefixes of them (helper processes add suffixes).
    public var bundleIDs: [String]
    /// A browser, where the microphone may be used for anything: only a calendar event makes
    /// it a meeting (Google Meet, Teams or Zoom on the web).
    public var isBrowser: Bool

    public init(name: String, bundleIDs: [String], isBrowser: Bool = false) {
        self.name = name
        self.bundleIDs = bundleIDs
        self.isBrowser = isBrowser
    }

    /// The apps Momo recognises.
    public static let known: [MeetingApp] = [
        MeetingApp(name: "Zoom", bundleIDs: ["us.zoom.xos", "us.zoom.ZoomClips"]),
        MeetingApp(
            name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams", "com.microsoft.teams2"]),
        MeetingApp(
            name: "Webex",
            bundleIDs: [
                "com.cisco.webexmeetingsapp", "com.webex.meetingmanager", "Cisco-Systems.Spark",
            ]
        ),
        MeetingApp(name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"]),
        MeetingApp(name: "FaceTime", bundleIDs: ["com.apple.FaceTime"]),
        MeetingApp(name: "Discord", bundleIDs: ["com.hnc.Discord"]),
        MeetingApp(
            name: "Safari", bundleIDs: ["com.apple.Safari", "com.apple.WebKit"], isBrowser: true),
        MeetingApp(name: "Google Chrome", bundleIDs: ["com.google.Chrome"], isBrowser: true),
        MeetingApp(name: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"], isBrowser: true),
        MeetingApp(name: "Arc", bundleIDs: ["company.thebrowser.Browser"], isBrowser: true),
        MeetingApp(name: "Firefox", bundleIDs: ["org.mozilla.firefox"], isBrowser: true),
        MeetingApp(name: "Brave", bundleIDs: ["com.brave.Browser"], isBrowser: true),
    ]

    /// The known app a bundle identifier belongs to, including its helper processes
    /// ("com.google.Chrome.helper" belongs to Chrome).
    public static func app(forBundleID bundleID: String) -> MeetingApp? {
        known.first { app in
            app.bundleIDs.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
        }
    }
}

/// A calendar event, as far as meeting detection cares.
public struct CalendarMeeting: Sendable, Equatable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// Names of the invited people, without the user.
    public var attendees: [String]

    public init(
        id: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
        attendees: [String] = []
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendees = attendees
    }
}

/// Decides when Momo should offer to take notes: a meeting app is using the microphone,
/// and either a calendar event is in progress or about to start, or the app is one people
/// only use the microphone in for calls.
///
/// It only decides; it never records. The app asks the user and starts nothing without a
/// yes. All inputs are passed in, so the decision is easy to test.
public enum MeetingDetector {
    /// What Momo can observe right now.
    public struct Signals: Sendable {
        public var now: Date
        /// Calendar events around now.
        public var events: [CalendarMeeting]
        /// Bundle identifiers of other processes using the microphone, or `nil` when macOS
        /// cannot tell (then only ``microphoneInUse`` is known).
        public var microphoneUsers: [String]?
        /// Whether another process uses the default microphone.
        public var microphoneInUse: Bool
        /// Bundle identifiers of running apps.
        public var runningApps: [String]
        /// The frontmost app's bundle identifier.
        public var frontmostApp: String?

        public init(
            now: Date, events: [CalendarMeeting] = [], microphoneUsers: [String]? = nil,
            microphoneInUse: Bool = false, runningApps: [String] = [], frontmostApp: String? = nil
        ) {
            self.now = now
            self.events = events
            self.microphoneUsers = microphoneUsers
            self.microphoneInUse = microphoneInUse
            self.runningApps = runningApps
            self.frontmostApp = frontmostApp
        }
    }

    /// A meeting worth offering to take notes of.
    public struct Offer: Sendable, Equatable {
        /// Identifies the meeting, so it is only offered once.
        public var key: String
        /// The calendar event, when there is one.
        public var event: CalendarMeeting?
        /// The app the call is in.
        public var app: MeetingApp
    }

    /// The calendar event that is in progress or starts within `leadTime`, preferring the
    /// one that started most recently.
    public static func currentEvent(
        in events: [CalendarMeeting], at now: Date, leadTime: TimeInterval = 5 * 60
    ) -> CalendarMeeting? {
        events.filter {
            !$0.isAllDay && $0.start.addingTimeInterval(-leadTime) <= now && now < $0.end
        }
        .max { $0.start < $1.start }
    }

    /// The meeting app that is using the microphone, if any.
    public static func callApp(in signals: Signals, hasEvent: Bool) -> MeetingApp? {
        if let users = signals.microphoneUsers {
            let apps = users.compactMap(MeetingApp.app(forBundleID:))
            return apps.first { !$0.isBrowser } ?? apps.first
        }
        guard signals.microphoneInUse else { return nil }
        // Without the list of processes, the frontmost app is the best guess; with a meeting
        // on the calendar any running meeting app will do.
        if let front = signals.frontmostApp.flatMap(MeetingApp.app(forBundleID:)) { return front }
        guard hasEvent else { return nil }
        let running = signals.runningApps.compactMap(MeetingApp.app(forBundleID:))
        return running.first { !$0.isBrowser } ?? running.first
    }

    /// Whether to offer taking notes now, and of which meeting.
    public static func offer(
        for signals: Signals, leadTime: TimeInterval = 5 * 60
    ) -> Offer? {
        let event = currentEvent(in: signals.events, at: signals.now, leadTime: leadTime)
        guard let app = callApp(in: signals, hasEvent: event != nil) else { return nil }
        if app.isBrowser && event == nil { return nil }
        // Without the process list, a dedicated app in front is only a guess: it needs an
        // event too.
        if signals.microphoneUsers == nil && event == nil { return nil }
        let key =
            event.map { "event-\($0.id)-\(Int($0.start.timeIntervalSince1970))" }
            ?? "app-\(app.bundleIDs.first ?? app.name)"
        return Offer(key: key, event: event, app: app)
    }
}
