import AppKit
import Foundation
import IOKit.ps
import MomoKit
import UserNotifications

/// Watches what happens on the Mac and lets Momo react: upcoming meetings, reminders, low
/// battery, music, late nights and the first activity of the morning.
@MainActor
final class ContextMonitor: NSObject {
    private let settings: AppSettings
    private let store: MomoStore
    private let calendar: CalendarService
    private weak var character: CharacterController?
    /// Opens the chat with a message, for notification actions.
    var openChat: ((String?) -> Void)?
    /// Opens the Meetings tab, when a meeting offer is clicked.
    var openMeetings: (() -> Void)?
    /// Starts meeting notes, when the user picks "Take notes" on a meeting offer.
    var takeMeetingNotes: (() -> Void)?

    private var tick: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    private var announcedEvents: Set<String> = []
    private var firedReminders: Set<String> = []
    private var lowBatteryAnnounced = false
    private var lateNightDay: String?
    private var greetingDay: String?

    init(
        settings: AppSettings, store: MomoStore, calendar: CalendarService,
        character: CharacterController
    ) {
        self.settings = settings
        self.store = store
        self.calendar = calendar
        self.character = character
        greetingDay = UserDefaults.standard.string(forKey: "lastGreetingDay")
        super.init()
    }

    func start() {
        observeMusic()
        prepareNotifications()
        observeActivation()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: - Periodic checks

    private func check() async {
        let preferences = settings.preferences
        let now = Date()
        let idle = SystemActivity.idleSeconds()
        if preferences.reactsToCalendar { checkMeetings(now: now) }
        await checkReminders(now: now)
        if preferences.reactsToBattery { checkBattery() }
        if preferences.reactsToLateNight { checkLateNight(now: now, idle: idle) }
        await checkMorning(now: now, idle: idle)
    }

    private func checkMeetings(now: Date) {
        guard calendar.isAuthorized else { return }
        for event in calendar.events(from: now, to: now.addingTimeInterval(6 * 60))
        where !event.isAllDay {
            let key = ContextRules.meetingKey(
                identifier: event.eventIdentifier, title: event.title, startDate: event.startDate)
            guard
                let minutes = ContextRules.minutesUntilMeeting(
                    startingAt: event.startDate, now: now),
                !announcedEvents.contains(key)
            else { continue }
            announcedEvents.insert(key)
            character?.simulate(.meetingSoon)
            notify(
                id: "meeting-\(key)", title: event.title ?? L("Meeting"),
                body: String(format: L("Starts in %lld minutes."), minutes))
        }
    }

    private func checkReminders(now: Date) async {
        let tasks = await store.tasks()
        for task in tasks {
            guard ContextRules.reminderJustCameDue(task.remindAt, now: now),
                !firedReminders.contains(task.id)
            else { continue }
            firedReminders.insert(task.id)
            // The notification itself is scheduled ahead of time; Momo peeks out as well.
            character?.simulate(.newMail)
        }
        scheduleReminderNotifications(for: tasks)
    }

    private func checkBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                let state = description[kIOPSPowerSourceStateKey] as? String
            else { continue }
            let alert = ContextRules.lowBattery(
                onBattery: state == kIOPSBatteryPowerValue, capacity: capacity,
                announced: lowBatteryAnnounced)
            lowBatteryAnnounced = alert.announced
            if alert.announce { character?.simulate(.lowBattery) }
        }
    }

    private func checkLateNight(now: Date, idle: Double) {
        guard ContextRules.isLateNight(now: now, idle: idle, lastDay: lateNightDay) else { return }
        lateNightDay = DayKey.string(for: now)
        character?.simulate(.lateNight)
    }

    /// Greets the user the first time they are active on a morning, with a summary of the day.
    private func checkMorning(now: Date, idle: Double) async {
        guard ContextRules.shouldGreet(now: now, idle: idle, lastGreetingDay: greetingDay)
        else { return }
        let day = DayKey.string(for: now)
        greetingDay = day
        UserDefaults.standard.set(day, forKey: "lastGreetingDay")

        let calendarDay = Calendar.current
        let tasks = ContextRules.tasksForToday(await store.tasks(), now: now)
        let end =
            calendarDay.date(byAdding: .day, value: 1, to: calendarDay.startOfDay(for: now)) ?? now
        let events = calendar.events(from: now, to: end).filter { !$0.isAllDay }
        character?.showDone()
        let body = String(
            format: L("You have %lld tasks due and %lld events today. Want me to plan your day?"),
            tasks.count, events.count)
        notify(id: "morning-\(day)", title: L("Good morning!"), body: body, action: .planDay)
    }

    // MARK: - Music

    private func observeMusic() {
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(
                center.addObserver(
                    forName: Notification.Name(name), object: nil, queue: .main
                ) { [weak self] notification in
                    let state = notification.userInfo?["Player State"] as? String
                    MainActor.assumeIsolated { self?.musicChanged(isPlaying: state == "Playing") }
                })
        }
    }

    private func musicChanged(isPlaying: Bool) {
        guard settings.preferences.reactsToMusic, let character else { return }
        if isPlaying {
            if character.ambientMood == nil { character.ambientMood = .music }
        } else if character.ambientMood == .music {
            character.ambientMood = nil
        }
    }

    // MARK: - Notifications

    enum NotificationAction: String {
        case planDay = "plan-day"
        case openTask = "open-task"
        case openChat = "open-chat"
        case meetingOffer = "meeting-offer"
    }

    /// The category of meeting offers, whose "Take notes" button starts recording.
    private static let meetingCategory = "meeting-offer"
    private static let takeNotesAction = "take-notes"

    /// Asks whether to take notes of a meeting that seems to have started. Only the "Take
    /// notes" button starts recording; clicking the notification opens the Meetings tab.
    func notifyMeetingOffer(id: String, title: String, body: String) {
        notify(
            id: "meeting-offer-\(id)", title: title, body: body, action: .meetingOffer,
            category: Self.meetingCategory)
    }

    /// Posts a notification that opens the chat when clicked, e.g. a routine's reply.
    func notifyOpeningChat(id: String, title: String, body: String) {
        notify(id: id, title: title, body: body, action: .openChat)
    }

    /// Notifications need an app bundle; `swift run` builds skip them.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func prepareNotifications() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().delegate = self
        let takeNotes = UNNotificationAction(
            identifier: Self.takeNotesAction, title: L("Take notes"), options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.meetingCategory, actions: [takeNotes], intentIdentifiers: [])
        ])
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound])
        }
    }

    /// The user may allow notifications in System Settings while Momo runs, so reminders that
    /// were skipped are scheduled as soon as Momo comes back rather than on the next check.
    private func observeActivation() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { self.scheduleReminderNotifications(for: await self.store.tasks()) }
                }
            })
    }

    /// Whether macOS currently lets Momo post notifications.
    nonisolated static func mayNotify(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional: true
        default: false
        }
    }

    /// Reads the permission each time, because the user can change it in System Settings at any
    /// moment. The center is looked up here rather than passed in, so it never crosses actors.
    private nonisolated static func notificationsAllowed() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings {
                continuation.resume(returning: $0.authorizationStatus)
            }
        }
        return mayNotify(status)
    }

    private func notify(
        id: String, title: String, body: String, action: NotificationAction? = nil,
        category: String? = nil
    ) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let action { content.userInfo = ["action": action.rawValue] }
        if let category { content.categoryIdentifier = category }
        Task {
            guard await Self.notificationsAllowed() else { return }
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// Identifiers of scheduled task reminders. Only the identifiers leave the callback,
    /// because notification requests are not Sendable on every SDK.
    /// The center is looked up here rather than passed in, so it never crosses actors.
    private nonisolated static func pendingTaskNotificationIDs() async -> [String] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                continuation.resume(
                    returning: requests.map(\.identifier).filter { $0.hasPrefix("task-") })
            }
        }
    }

    /// Keeps one scheduled notification per open task with a future reminder.
    private func scheduleReminderNotifications(for tasks: [TaskItem]) {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        let now = Date()
        Task {
            // Checked every time, so reminders skipped while notifications were off are
            // scheduled once the user allows them.
            guard await Self.notificationsAllowed() else { return }
            let pending = await Self.pendingTaskNotificationIDs()
            let plan = ContextRules.ReminderNotificationPlan(
                tasks: tasks, pending: pending, now: now)
            center.removePendingNotificationRequests(withIdentifiers: plan.stale)
            for task in plan.toSchedule {
                let id = ContextRules.reminderNotificationID(for: task)
                guard let remind = task.remindAt else { continue }
                let content = UNMutableNotificationContent()
                content.title = L("Reminder")
                content.body = task.title
                content.sound = .default
                content.userInfo = ["action": NotificationAction.openTask.rawValue]
                let parts = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: remind)
                try? await center.add(
                    UNNotificationRequest(
                        identifier: id, content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
                )
            }
        }
    }
}

extension ContextMonitor: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.notification.request.content.userInfo["action"] as? String
        let tapped = response.actionIdentifier
        await MainActor.run {
            switch NotificationAction(rawValue: action ?? "") {
            case .planDay: openChat?(L("Plan my day"))
            case .openTask, .openChat: openChat?(nil)
            case .meetingOffer:
                if tapped == Self.takeNotesAction {
                    takeMeetingNotes?()
                } else if tapped == UNNotificationDefaultActionIdentifier {
                    openMeetings?()
                }
            case nil: break
            }
        }
    }
}
