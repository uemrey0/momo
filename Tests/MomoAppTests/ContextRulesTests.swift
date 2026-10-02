import Foundation
import MomoKit
import Testing

@testable import MomoApp

@Suite("Context monitor rules")
struct ContextRulesTests {
    /// 3 October 2026, 00:00 UTC.
    private let midnight = Date(timeIntervalSince1970: 1_790_985_600)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func at(hour: Double) -> Date { midnight.addingTimeInterval(hour * 3600) }

    // MARK: - Reminder notifications

    @Test("schedules a notification for each future reminder that has none")
    func schedulesMissingReminders() {
        let now = at(hour: 9)
        let soon = TaskItem(id: "a", title: "Call mum", remindAt: now.addingTimeInterval(600))
        let later = TaskItem(id: "b", title: "Pay rent", remindAt: now.addingTimeInterval(7200))
        let pending = [ContextRules.reminderNotificationID(for: soon)]
        let plan = ContextRules.ReminderNotificationPlan(
            tasks: [soon, later], pending: pending, now: now)
        #expect(plan.toSchedule == [later])
        #expect(plan.stale.isEmpty)
    }

    @Test("removes notifications of past, moved and deleted reminders")
    func removesStaleReminders() {
        let now = at(hour: 9)
        var moved = TaskItem(id: "a", title: "Call mum", remindAt: now.addingTimeInterval(600))
        let oldID = ContextRules.reminderNotificationID(for: moved)
        moved.remindAt = now.addingTimeInterval(1200)
        let past = TaskItem(id: "b", title: "Water plants", remindAt: now.addingTimeInterval(-60))
        let pastID = ContextRules.reminderNotificationID(for: past)
        let deletedID = "task-gone-1790000000.0"
        let plan = ContextRules.ReminderNotificationPlan(
            tasks: [moved, past], pending: [oldID, pastID, deletedID], now: now)
        #expect(Set(plan.stale) == [oldID, pastID, deletedID])
        #expect(plan.toSchedule == [moved])
    }

    @Test("tasks without a reminder get no notification")
    func ignoresTasksWithoutReminder() {
        let plan = ContextRules.ReminderNotificationPlan(
            tasks: [TaskItem(title: "Someday")], pending: [], now: at(hour: 9))
        #expect(plan.toSchedule.isEmpty)
        #expect(plan.stale.isEmpty)
    }

    @Test("a reminder's notification ID changes when the reminder moves")
    func reminderIDFollowsTime() {
        var task = TaskItem(id: "a", title: "Call mum", remindAt: at(hour: 10))
        let first = ContextRules.reminderNotificationID(for: task)
        task.remindAt = at(hour: 11)
        #expect(ContextRules.reminderNotificationID(for: task) != first)
        #expect(first.hasPrefix("task-a-"))
    }

    @Test("Momo peeks out for a reminder only in the two minutes after it comes due")
    func reminderJustCameDue() {
        let remind = at(hour: 9)
        #expect(ContextRules.reminderJustCameDue(remind, now: remind))
        #expect(ContextRules.reminderJustCameDue(remind, now: remind.addingTimeInterval(119)))
        #expect(!ContextRules.reminderJustCameDue(remind, now: remind.addingTimeInterval(120)))
        #expect(!ContextRules.reminderJustCameDue(remind, now: remind.addingTimeInterval(-1)))
        #expect(!ContextRules.reminderJustCameDue(nil, now: remind))
    }

    // MARK: - Meetings

    @Test("announces a meeting in the five minutes before it starts")
    func meetingSoon() {
        let start = at(hour: 10)
        let minutes = { (before: TimeInterval) in
            ContextRules.minutesUntilMeeting(startingAt: start, now: start - before)
        }
        #expect(minutes(5 * 60) == 5)
        #expect(minutes(150) == 3)
        // Under a minute still says one minute rather than zero.
        #expect(minutes(10) == 1)
        #expect(minutes(5 * 60 + 1) == nil)
        #expect(minutes(0) == nil)
        #expect(minutes(-60) == nil)
    }

    @Test("an event is announced once per start time")
    func meetingKey() {
        let start = at(hour: 10)
        let key = ContextRules.meetingKey(identifier: "E1", title: "Standup", startDate: start)
        #expect(
            key == ContextRules.meetingKey(identifier: "E1", title: "Renamed", startDate: start))
        #expect(
            key
                != ContextRules.meetingKey(
                    identifier: "E1", title: "Standup", startDate: start + 86_400))
        // Without an identifier, the title tells events apart.
        #expect(
            ContextRules.meetingKey(identifier: nil, title: "Standup", startDate: start)
                != ContextRules.meetingKey(identifier: nil, title: "Review", startDate: start))
    }

    // MARK: - Morning and night

    @Test("greets the first activity of a morning once")
    func morningGreeting() {
        let day = DayKey.string(for: midnight, calendar: calendar)
        func greets(_ hour: Double, idle: Double = 0, last: String? = nil) -> Bool {
            ContextRules.shouldGreet(
                now: at(hour: hour), idle: idle, lastGreetingDay: last, calendar: calendar)
        }
        #expect(greets(5))
        #expect(greets(11.9))
        #expect(!greets(4.9))
        #expect(!greets(12))
        // Away from the Mac: wait until the user is back.
        #expect(!greets(8, idle: 30))
        #expect(greets(8, idle: 29))
        // Already greeted today, but not yesterday.
        #expect(!greets(8, last: day))
        #expect(greets(8, last: "2026-10-02"))
    }

    @Test("notices a late night once, between 1 and 5")
    func lateNight() {
        let day = DayKey.string(for: midnight, calendar: calendar)
        func notices(_ hour: Double, idle: Double = 0, last: String? = nil) -> Bool {
            ContextRules.isLateNight(
                now: at(hour: hour), idle: idle, lastDay: last, calendar: calendar)
        }
        #expect(notices(1))
        #expect(notices(4.9))
        #expect(!notices(0.5))
        #expect(!notices(5))
        #expect(!notices(2, idle: 60))
        #expect(!notices(2, last: day))
    }

    @Test("the morning greeting counts today's and overdue tasks")
    func tasksForToday() {
        let now = at(hour: 8)
        let tasks = [
            TaskItem(id: "today", title: "Today", dueDate: at(hour: 17)),
            TaskItem(id: "overdue", title: "Overdue", dueDate: at(hour: -30)),
            TaskItem(id: "reminder", title: "Reminder", remindAt: at(hour: 12)),
            TaskItem(id: "tomorrow", title: "Tomorrow", dueDate: at(hour: 33)),
            TaskItem(id: "someday", title: "Someday"),
        ]
        let counted = ContextRules.tasksForToday(tasks, now: now, calendar: calendar)
        #expect(counted.map(\.id) == ["today", "overdue", "reminder"])
    }

    // MARK: - Battery

    @Test("warns about a low battery once until it charges")
    func lowBattery() {
        var announced = false
        func check(onBattery: Bool, _ capacity: Int) -> Bool {
            let result = ContextRules.lowBattery(
                onBattery: onBattery, capacity: capacity, announced: announced)
            announced = result.announced
            return result.announce
        }
        #expect(!check(onBattery: true, 11))
        #expect(check(onBattery: true, 10))
        #expect(!check(onBattery: true, 8))
        // Still low after a small rise: no second warning.
        #expect(!check(onBattery: true, 15))
        #expect(!check(onBattery: true, 9))
        // Plugged in, then low again: warn again.
        #expect(!check(onBattery: false, 9))
        #expect(check(onBattery: true, 9))
        // Above 20% resets the warning too.
        #expect(!check(onBattery: true, 21))
        #expect(check(onBattery: true, 10))
    }

    @Test("never warns while charging")
    func chargingNeverWarns() {
        let result = ContextRules.lowBattery(onBattery: false, capacity: 3, announced: false)
        #expect(!result.announce)
        #expect(!result.announced)
    }
}
