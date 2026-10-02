import Foundation
import MomoKit

/// The decisions ``ContextMonitor`` makes on each check, apart from the system services it
/// reads, so they can be tested on their own.
enum ContextRules {
    // MARK: - Meetings

    /// Identifies an announced calendar event, so it is announced once.
    static func meetingKey(identifier: String?, title: String?, startDate: Date) -> String {
        "\(identifier ?? title ?? "")-\(startDate.timeIntervalSince1970)"
    }

    /// The minutes to announce for an event starting at `startDate`, or `nil` when it isn't
    /// within the next five minutes.
    static func minutesUntilMeeting(startingAt startDate: Date, now: Date) -> Int? {
        let minutes = startDate.timeIntervalSince(now) / 60
        guard minutes > 0, minutes <= 5 else { return nil }
        return max(1, Int(minutes.rounded()))
    }

    // MARK: - Reminders

    /// Whether a reminder set for `remindAt` came due in the last two minutes.
    static func reminderJustCameDue(_ remindAt: Date?, now: Date) -> Bool {
        guard let remindAt else { return false }
        return remindAt <= now && now.timeIntervalSince(remindAt) < 120
    }

    /// The identifier of a task's scheduled reminder notification. It changes with the
    /// reminder time, so a moved reminder replaces the old notification.
    static func reminderNotificationID(for task: TaskItem) -> String {
        "task-\(task.id)-\(task.remindAt?.timeIntervalSince1970 ?? 0)"
    }

    /// How scheduled reminder notifications change to match the tasks.
    struct ReminderNotificationPlan: Equatable {
        /// Pending notifications whose task or reminder time is gone.
        var stale: [String]
        /// Tasks whose future reminder has no notification yet.
        var toSchedule: [TaskItem]

        /// One notification per task with a future reminder: `pending` notifications not
        /// wanted any more are stale, and wanted ones not pending are scheduled.
        init(tasks: [TaskItem], pending: [String], now: Date) {
            let wanted = tasks.filter { ($0.remindAt ?? .distantPast) > now }
            let wantedIDs = Set(wanted.map(ContextRules.reminderNotificationID(for:)))
            stale = pending.filter { !wantedIDs.contains($0) }
            toSchedule = wanted.filter {
                !pending.contains(ContextRules.reminderNotificationID(for: $0))
            }
        }
    }

    // MARK: - Times of day

    /// Whether to notice that the user is up late: active between 1 and 5 in the morning, once
    /// a day.
    static func isLateNight(
        now: Date, idle: Double, lastDay: String?, calendar: Calendar = .current
    ) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return (1..<5).contains(hour) && idle < 60
            && lastDay != DayKey.string(for: now, calendar: calendar)
    }

    /// Whether to greet the user: their first activity between 5 and noon, once a day.
    static func shouldGreet(
        now: Date, idle: Double, lastGreetingDay: String?, calendar: Calendar = .current
    ) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return (5..<12).contains(hour) && idle < 30
            && lastGreetingDay != DayKey.string(for: now, calendar: calendar)
    }

    /// The tasks the morning greeting counts: due or reminding today, or overdue.
    static func tasksForToday(
        _ tasks: [TaskItem], now: Date, calendar: Calendar = .current
    ) -> [TaskItem] {
        tasks.filter { task in
            guard let due = task.dueDate ?? task.remindAt else { return false }
            return calendar.isDate(due, inSameDayAs: now) || due < now
        }
    }

    // MARK: - Battery

    /// Whether to announce a low battery once it drops to 10% on battery power. The warning is
    /// given again only after charging or rising above 20%. Returns whether to announce now
    /// and the new announced state.
    static func lowBattery(
        onBattery: Bool, capacity: Int, announced: Bool
    ) -> (announce: Bool, announced: Bool) {
        if onBattery, capacity <= 10, !announced { return (true, true) }
        if !onBattery || capacity > 20 { return (false, false) }
        return (false, announced)
    }
}
