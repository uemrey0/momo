import Foundation

/// How important a task is.
public enum TaskPriority: String, Codable, Sendable, CaseIterable, Comparable {
    case low
    case normal
    case high

    /// Reads unknown values as `.normal`, so newer files still load.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TaskPriority(rawValue: raw.lowercased()) ?? .normal
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .normal: 1
        case .high: 2
        }
    }

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A rule for repeating a task.
public struct Recurrence: Codable, Sendable, Hashable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case daily
        /// Monday to Friday.
        case weekdays
        case weekly
        case monthly
        case yearly
    }

    public var frequency: Frequency
    /// Repeat every `interval` days, weeks, months or years. Ignored for `weekdays`.
    public var interval: Int
    /// The day of the month the task started on, so a task due on the 31st returns to the
    /// 31st after a shorter month, and one due on 29 February returns to it in leap years.
    public var anchorDay: Int?

    public init(frequency: Frequency, interval: Int = 1, anchorDay: Int? = nil) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.anchorDay = anchorDay
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try container.decode(Frequency.self, forKey: .frequency)
        interval = max(1, container.lenient(Int.self, .interval) ?? 1)
        anchorDay = container.lenient(Int.self, .anchorDay)
    }

    /// Reads "daily", "weekdays", "weekly", "monthly" or "yearly", plus a few synonyms.
    public init?(_ text: String, interval: Int = 1) {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let synonyms: [String: Frequency] = [
            "day": .daily, "every day": .daily, "weekday": .weekdays, "workdays": .weekdays,
            "week": .weekly, "every week": .weekly, "month": .monthly, "every month": .monthly,
            "year": .yearly, "annually": .yearly, "every year": .yearly,
        ]
        guard let frequency = Frequency(rawValue: key) ?? synonyms[key] else { return nil }
        self.init(frequency: frequency, interval: interval)
    }

    /// A short English description for the model, e.g. "every 2 weeks".
    public var summary: String {
        let unit: String
        switch frequency {
        case .weekdays: return "every weekday"
        case .daily: unit = "day"
        case .weekly: unit = "week"
        case .monthly: unit = "month"
        case .yearly: unit = "year"
        }
        return interval == 1 ? "every \(unit)" : "every \(interval) \(unit)s"
    }

    /// The first occurrence after `date`, at the same time of day.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        switch frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: interval, to: date)
        case .weekdays:
            var candidate = date
            for _ in 0..<7 {
                guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else {
                    return nil
                }
                if !calendar.isDateInWeekend(next) { return next }
                candidate = next
            }
            return nil
        case .weekly:
            return calendar.date(byAdding: .day, value: 7 * interval, to: date)
        case .monthly:
            return adding(.month, interval, to: date, calendar: calendar)
        case .yearly:
            return adding(.year, interval, to: date, calendar: calendar)
        }
    }

    /// The first occurrence after `date` that is also later than `now`, so a task that is
    /// days overdue moves to its next future date instead of stacking up past ones.
    public func next(
        after date: Date, notBefore now: Date, calendar: Calendar = .current
    )
        -> Date?
    {
        guard var candidate = next(after: date, calendar: calendar) else { return nil }
        var steps = 0
        while candidate <= now, steps < 5000 {
            guard let later = next(after: candidate, calendar: calendar) else { return nil }
            candidate = later
            steps += 1
        }
        return candidate
    }

    /// Adds months or years, keeping the anchor day where the month allows it.
    private func adding(
        _ component: Calendar.Component, _ value: Int, to date: Date, calendar: Calendar
    ) -> Date? {
        var parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let day = anchorDay ?? parts.day ?? 1
        parts.day = 1
        guard let firstOfMonth = calendar.date(from: parts),
            let shifted = calendar.date(byAdding: component, value: value, to: firstOfMonth),
            let days = calendar.range(of: .day, in: .month, for: shifted)
        else { return nil }
        var target = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: shifted)
        target.day = min(day, days.count)
        return calendar.date(from: target)
    }
}

extension TaskItem {
    /// The next occurrence of a repeating task, due after `now`, with its reminder moved by
    /// the same amount. `nil` when the task does not repeat.
    public func nextOccurrence(
        completedAt now: Date = Date(), calendar: Calendar = .current
    )
        -> TaskItem?
    {
        guard var rule = recurrence else { return nil }
        let base = dueDate ?? remindAt
        if rule.anchorDay == nil, let base {
            rule.anchorDay = calendar.component(.day, from: base)
        }
        let next: Date?
        if let base {
            next = rule.next(after: base, notBefore: now, calendar: calendar)
        } else {
            // Without a date the next occurrence is due at 9 on the next day the rule allows.
            let morning = calendar.date(
                bySettingHour: 9, minute: 0, second: 0, of: calendar.startOfDay(for: now))
            next = morning.flatMap { rule.next(after: $0, notBefore: now, calendar: calendar) }
        }
        guard let next else { return nil }
        var due: Date?
        var remind: Date?
        if let dueDate {
            due = next
            remind = remindAt.map { next.addingTimeInterval($0.timeIntervalSince(dueDate)) }
        } else if remindAt != nil {
            remind = next
        } else {
            due = next
        }
        return TaskItem(
            title: title, notes: notes, dueDate: due, remindAt: remind, createdAt: now,
            recurrence: rule, priority: priority, tags: tags)
    }
}
