import Foundation

/// A saved prompt Momo runs on a schedule, such as "every weekday at 9, summarise my day".
public struct Routine: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// The message Momo answers when the routine runs.
    public var prompt: String
    public var schedule: RoutineSchedule
    public var isEnabled: Bool
    /// When the routine last ran, if ever.
    public var lastRun: Date?
    public var createdAt: Date

    public init(
        id: String = ShortID.make(), title: String, prompt: String, schedule: RoutineSchedule,
        isEnabled: Bool = true, lastRun: Date? = nil, createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.schedule = schedule
        self.isEnabled = isEnabled
        self.lastRun = lastRun
        self.createdAt = createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        prompt = container.lenient(String.self, .prompt) ?? ""
        schedule =
            container.lenient(RoutineSchedule.self, .schedule)
            ?? RoutineSchedule(hour: 9, minute: 0)
        isEnabled = container.lenient(Bool.self, .isEnabled) ?? true
        lastRun = container.lenient(Date.self, .lastRun)
        createdAt = container.lenient(Date.self, .createdAt) ?? Date()
    }

    /// Whether the routine should run now: its latest scheduled time has passed since it last
    /// ran (or was created) and is at most `catchUpWindow` ago.
    ///
    /// Only the latest scheduled time counts, so a Mac that slept through several runs catches
    /// up once, and not at all when the run is older than the window.
    public func isDue(
        at now: Date, catchUpWindow: TimeInterval = 12 * 3600, calendar: Calendar = .current
    ) -> Bool {
        guard isEnabled, let scheduled = schedule.latest(atOrBefore: now, calendar: calendar)
        else { return false }
        return scheduled > (lastRun ?? createdAt)
            && now.timeIntervalSince(scheduled) <= catchUpWindow
    }
}

/// When a routine runs: a time of day on some or all days of the week.
public struct RoutineSchedule: Codable, Sendable, Hashable {
    public var hour: Int
    public var minute: Int
    /// Days of the week as `Calendar` weekday numbers (1 is Sunday, 7 is Saturday). Empty
    /// means every day.
    public var weekdays: Set<Int>

    public static let workweek: Set<Int> = [2, 3, 4, 5, 6]
    public static let weekend: Set<Int> = [1, 7]

    public init(hour: Int, minute: Int, weekdays: Set<Int> = []) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekdays = weekdays.filter { (1...7).contains($0) }
        if self.weekdays.count == 7 { self.weekdays = [] }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hour: container.lenient(Int.self, .hour) ?? 9,
            minute: container.lenient(Int.self, .minute) ?? 0,
            weekdays: container.lenient(Set<Int>.self, .weekdays) ?? [])
    }

    public var isDaily: Bool { weekdays.isEmpty }

    /// Whether the schedule includes the weekday of `date`.
    public func includes(_ date: Date, calendar: Calendar = .current) -> Bool {
        isDaily || weekdays.contains(calendar.component(.weekday, from: date))
    }

    /// The most recent scheduled time at or before `date`, looking back a week.
    public func latest(atOrBefore date: Date, calendar: Calendar = .current) -> Date? {
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date),
                includes(day, calendar: calendar),
                let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                time <= date
            else { continue }
            return time
        }
        return nil
    }

    /// The next scheduled time after `date`.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date),
                includes(day, calendar: calendar),
                let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                time > date
            else { continue }
            return time
        }
        return nil
    }

    /// Reads a time like "09:00", "9:30" or "21:15".
    public static func parseTime(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (1...3).contains(parts.count), let hour = Int(parts[0]), (0...23).contains(hour)
        else { return nil }
        let minute = parts.count > 1 ? Int(parts[1]) : 0
        guard let minute, (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// Reads "daily", "weekdays", "weekends" or a list of days such as "mon, wed, fri"
    /// (English names or three-letter abbreviations).
    public static func parseDays(_ text: String) -> Set<Int>? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "", "daily", "every day", "everyday", "all": return []
        case "weekdays", "workdays", "weekday": return workweek
        case "weekends", "weekend": return weekend
        default: break
        }
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        var days: Set<Int> = []
        for word in key.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
        where word != "and" {
            guard let index = names.firstIndex(where: { word.hasPrefix($0) }) else { return nil }
            days.insert(index + 1)
        }
        return days.isEmpty ? nil : days
    }

    /// A short English description for the model, e.g. "weekdays at 09:00".
    public var summary: String {
        let time = String(format: "%02d:%02d", hour, minute)
        if isDaily { return "every day at \(time)" }
        if weekdays == Self.workweek { return "weekdays at \(time)" }
        if weekdays == Self.weekend { return "weekends at \(time)" }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        // Monday first, the way most people read a week.
        let ordered = [2, 3, 4, 5, 6, 7, 1].filter(weekdays.contains).map { names[$0 - 1] }
        return "\(ordered.joined(separator: ", ")) at \(time)"
    }
}
