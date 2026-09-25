import Foundation

/// Something the user wants to get done.
public struct TaskItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var notes: String?
    /// When the task is due, if it has a deadline.
    public var dueDate: Date?
    /// When Momo should remind the user, if at all.
    public var remindAt: Date?
    public var isDone: Bool
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: String = ShortID.make(), title: String, notes: String? = nil, dueDate: Date? = nil,
        remindAt: Date? = nil, isDone: Bool = false, createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.remindAt = remindAt
        self.isDone = isDone
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

/// A free-form note.
public struct Note: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = ShortID.make(), title: String, body: String, createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A habit tracked by day.
public struct Habit: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var createdAt: Date
    /// Days the habit was done, as `yyyy-MM-dd` in the user's calendar.
    public var completedDays: Set<String>

    public init(
        id: String = ShortID.make(), name: String, createdAt: Date = Date(),
        completedDays: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.completedDays = completedDays
    }

    /// Consecutive days up to and including `today` (or yesterday, if today isn't done yet).
    public func streak(asOf today: Date = Date(), calendar: Calendar = .current) -> Int {
        var day = today
        if !completedDays.contains(DayKey.string(for: day, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else {
                return 0
            }
            day = yesterday
        }
        var count = 0
        while completedDays.contains(DayKey.string(for: day, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    public func isDone(on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        completedDays.contains(DayKey.string(for: date, calendar: calendar))
    }
}

/// A fact Momo remembers about the user.
public struct Memory: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var createdAt: Date

    public init(id: String = ShortID.make(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// Everything Momo stores, persisted as one JSON document.
public struct MomoData: Codable, Sendable, Equatable {
    public var version: Int
    public var tasks: [TaskItem]
    public var notes: [Note]
    public var habits: [Habit]
    public var memories: [Memory]

    public init(
        tasks: [TaskItem] = [], notes: [Note] = [], habits: [Habit] = [], memories: [Memory] = []
    ) {
        self.version = 1
        self.tasks = tasks
        self.notes = notes
        self.habits = habits
        self.memories = memories
    }
}

/// Short, readable identifiers that models can repeat back reliably.
public enum ShortID {
    public static func make() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
    }
}

/// Formats days as `yyyy-MM-dd` keys.
public enum DayKey {
    public static func string(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
