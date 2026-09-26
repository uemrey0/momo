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
    /// How the task repeats. Completing a repeating task creates its next occurrence.
    public var recurrence: Recurrence?
    public var priority: TaskPriority
    /// Short labels such as "work" or "home", lowercased.
    public var tags: [String]
    /// The occurrence created when this repeating task was completed, so undoing the
    /// completion can remove it again.
    public var nextOccurrenceID: String?

    public init(
        id: String = ShortID.make(), title: String, notes: String? = nil, dueDate: Date? = nil,
        remindAt: Date? = nil, isDone: Bool = false, createdAt: Date = Date(),
        completedAt: Date? = nil, recurrence: Recurrence? = nil, priority: TaskPriority = .normal,
        tags: [String] = [], nextOccurrenceID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.remindAt = remindAt
        self.isDone = isDone
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.recurrence = recurrence
        self.priority = priority
        self.tags = tags
        self.nextOccurrenceID = nextOccurrenceID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        notes = container.lenient(String.self, .notes)
        dueDate = container.lenient(Date.self, .dueDate)
        remindAt = container.lenient(Date.self, .remindAt)
        isDone = container.lenient(Bool.self, .isDone) ?? false
        createdAt = container.lenient(Date.self, .createdAt) ?? Date()
        completedAt = container.lenient(Date.self, .completedAt)
        recurrence = container.lenient(Recurrence.self, .recurrence)
        priority = container.lenient(TaskPriority.self, .priority) ?? .normal
        tags = container.lenient([String].self, .tags) ?? []
        nextOccurrenceID = container.lenient(String.self, .nextOccurrenceID)
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

/// What kind of thing a memory is about.
public enum MemoryCategory: String, Codable, Sendable, CaseIterable {
    /// How the user likes things done ("prefers short answers").
    case preference
    /// Someone in the user's life ("Ayşe is the user's sister").
    case person
    /// Something the user is working on.
    case project
    /// Anything else worth remembering.
    case fact

    /// Reads unknown values as `.fact`, so newer files still load.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MemoryCategory(rawValue: raw.lowercased()) ?? .fact
    }
}

/// A fact Momo remembers about the user.
public struct Memory: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var createdAt: Date
    public var category: MemoryCategory

    public init(
        id: String = ShortID.make(), text: String, category: MemoryCategory = .fact,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.category = category
        self.createdAt = createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        createdAt = container.lenient(Date.self, .createdAt) ?? Date()
        category = container.lenient(MemoryCategory.self, .category) ?? .fact
    }
}

/// Everything Momo stores, persisted as one JSON document.
///
/// Older files load too: fields added later decode with their defaults, and the file is
/// written back in the current format on the next change.
public struct MomoData: Codable, Sendable, Equatable {
    /// The format written today. Version 2 added memory categories, repeating tasks with
    /// priority and tags, and routines.
    public static let currentVersion = 2

    public var version: Int
    public var tasks: [TaskItem]
    public var notes: [Note]
    public var habits: [Habit]
    public var memories: [Memory]
    public var routines: [Routine]

    public init(
        tasks: [TaskItem] = [], notes: [Note] = [], habits: [Habit] = [], memories: [Memory] = [],
        routines: [Routine] = []
    ) {
        self.version = Self.currentVersion
        self.tasks = tasks
        self.notes = notes
        self.habits = habits
        self.memories = memories
        self.routines = routines
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decoding migrates older formats, so the value in memory is always current.
        version = Self.currentVersion
        tasks = try container.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? []
        notes = try container.decodeIfPresent([Note].self, forKey: .notes) ?? []
        habits = try container.decodeIfPresent([Habit].self, forKey: .habits) ?? []
        memories = try container.decodeIfPresent([Memory].self, forKey: .memories) ?? []
        routines = try container.decodeIfPresent([Routine].self, forKey: .routines) ?? []
    }
}

extension KeyedDecodingContainer {
    /// Decodes an optional value, treating a missing or unreadable value as `nil`.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
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
