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

    private var tick: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    private var announcedEvents: Set<String> = []
    private var firedReminders: Set<String> = []
    private var lowBatteryAnnounced = false
    private var lateNightDay: String?
    private var greetingDay: String?
    private var notificationsReady = false

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
            let key =
                "\(event.eventIdentifier ?? event.title ?? "")-\(event.startDate.timeIntervalSince1970)"
            let minutes = event.startDate.timeIntervalSince(now) / 60
            guard minutes > 0, minutes <= 5, !announcedEvents.contains(key) else { continue }
            announcedEvents.insert(key)
            character?.simulate(.meetingSoon)
            notify(
                id: "meeting-\(key)", title: event.title ?? L("Meeting"),
                body: String(format: L("Starts in %lld minutes."), max(1, Int(minutes.rounded()))))
        }
    }

    private func checkReminders(now: Date) async {
        let tasks = await store.tasks()
        for task in tasks {
            guard let remind = task.remindAt, remind <= now, now.timeIntervalSince(remind) < 120,
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
            let onBattery = state == kIOPSBatteryPowerValue
            if onBattery, capacity <= 10, !lowBatteryAnnounced {
                lowBatteryAnnounced = true
                character?.simulate(.lowBattery)
            } else if !onBattery || capacity > 20 {
                lowBatteryAnnounced = false
            }
        }
    }

    private func checkLateNight(now: Date, idle: Double) {
        let hour = Calendar.current.component(.hour, from: now)
        let day = DayKey.string(for: now)
        guard (1..<5).contains(hour), idle < 60, lateNightDay != day else { return }
        lateNightDay = day
        character?.simulate(.lateNight)
    }

    /// Greets the user the first time they are active on a morning, with a summary of the day.
    private func checkMorning(now: Date, idle: Double) async {
        let hour = Calendar.current.component(.hour, from: now)
        let day = DayKey.string(for: now)
        guard (5..<12).contains(hour), idle < 30, greetingDay != day else { return }
        greetingDay = day
        UserDefaults.standard.set(day, forKey: "lastGreetingDay")

        let calendarDay = Calendar.current
        let tasks = await store.tasks().filter { task in
            guard let due = task.dueDate ?? task.remindAt else { return false }
            return calendarDay.isDateInToday(due) || due < now
        }
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
    }

    /// Notifications need an app bundle; `swift run` builds skip them.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func prepareNotifications() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().delegate = self
        Task {
            let granted =
                (try? await UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound])) ?? false
            notificationsReady = granted
        }
    }

    private func notify(id: String, title: String, body: String, action: NotificationAction? = nil)
    {
        guard canNotify, notificationsReady else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let action { content.userInfo = ["action": action.rawValue] }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Keeps one scheduled notification per open task with a future reminder.
    private func scheduleReminderNotifications(for tasks: [TaskItem]) {
        guard canNotify, notificationsReady else { return }
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let wanted = tasks.filter { ($0.remindAt ?? .distantPast) > now }
        let wantedIDs = Set(
            wanted.map { "task-\($0.id)-\($0.remindAt?.timeIntervalSince1970 ?? 0)" })
        Task {
            let pending = await center.pendingNotificationRequests()
                .map(\.identifier).filter { $0.hasPrefix("task-") }
            let stale = pending.filter { !wantedIDs.contains($0) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            for task in wanted {
                let id = "task-\(task.id)-\(task.remindAt?.timeIntervalSince1970 ?? 0)"
                guard !pending.contains(id), let remind = task.remindAt else { continue }
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
        await MainActor.run {
            switch NotificationAction(rawValue: action ?? "") {
            case .planDay: openChat?(L("Plan my day"))
            case .openTask: openChat?(nil)
            case nil: break
            }
        }
    }
}
