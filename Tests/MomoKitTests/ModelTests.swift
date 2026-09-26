import Foundation
import Testing

@testable import MomoKit

/// A fixed Gregorian calendar, so date math does not depend on the machine running the tests.
func testCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Istanbul") ?? .gmt
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

/// Builds a date in the test calendar.
func date(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9, _ minute: Int = 0,
    calendar: Calendar = testCalendar()
) -> Date {
    let parts = DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute)
    guard let date = calendar.date(from: parts) else {
        preconditionFailure("Invalid test date")
    }
    return date
}

@Suite("Data format")
struct DataFormatTests {
    /// A data.json written by Momo before version 2.
    static let versionOne = """
        {
          "habits" : [
            { "completedDays" : [ "2026-09-20" ], "createdAt" : "2026-09-01T08:00:00Z",
              "id" : "h1", "name" : "Drink water" }
          ],
          "memories" : [
            { "createdAt" : "2026-09-01T08:00:00Z", "id" : "m1", "text" : "The user's name is Emre" }
          ],
          "notes" : [
            { "body" : "Momo wears a hat", "createdAt" : "2026-09-01T08:00:00Z", "id" : "n1",
              "title" : "Ideas", "updatedAt" : "2026-09-02T08:00:00Z" }
          ],
          "tasks" : [
            { "createdAt" : "2026-09-01T08:00:00Z", "dueDate" : "2026-09-27T12:00:00Z",
              "id" : "t1", "isDone" : false, "title" : "Pay rent" }
          ],
          "version" : 1
        }
        """

    private func decode(_ json: String) throws -> MomoData {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MomoData.self, from: Data(json.utf8))
    }

    @Test("loads a version 1 file with defaults for the new fields")
    func versionOneFile() throws {
        let data = try decode(Self.versionOne)
        #expect(data.version == MomoData.currentVersion)
        #expect(data.tasks.first?.title == "Pay rent")
        #expect(data.tasks.first?.priority == .normal)
        #expect(data.tasks.first?.recurrence == nil)
        #expect(data.tasks.first?.tags == [])
        #expect(data.memories.first?.category == .fact)
        #expect(data.notes.first?.body == "Momo wears a hat")
        #expect(data.habits.first?.completedDays == ["2026-09-20"])
        #expect(data.routines.isEmpty)
    }

    @Test("reads a version 1 file from disk and writes it back as version 2")
    func migratesOnDisk() async throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.versionOne.utf8).write(to: store.fileURL)
        #expect(await store.tasks().count == 1)
        try await store.addNote(title: "New", body: "")
        let written = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(written.contains(#""version" : 2"#))
        #expect(written.contains(#""category" : "fact""#))
        #expect(written.contains(#""priority" : "normal""#))
        #expect(await store.memories().count == 1)
    }

    @Test("reads missing or unknown values in newer fields leniently")
    func lenientValues() throws {
        let data = try decode(
            """
            {
              "memories" : [ { "id" : "m1", "text" : "X", "category" : "someday" } ],
              "tasks" : [ { "id" : "t1", "title" : "Y", "priority" : "urgent",
                            "recurrence" : { "frequency" : "weekly", "interval" : 0 } } ],
              "routines" : [ { "id" : "r1", "title" : "Morning" } ]
            }
            """)
        #expect(data.memories.first?.category == .fact)
        #expect(data.tasks.first?.priority == .normal)
        #expect(data.tasks.first?.recurrence == Recurrence(frequency: .weekly, interval: 1))
        #expect(data.tasks.first?.isDone == false)
        #expect(data.routines.first?.isEnabled == true)
        #expect(data.routines.first?.schedule == RoutineSchedule(hour: 9, minute: 0))
    }

    @Test("round-trips the current format")
    func roundTrip() throws {
        let original = MomoData(
            tasks: [
                TaskItem(
                    title: "Stretch", recurrence: Recurrence(frequency: .daily, interval: 2),
                    priority: .high, tags: ["health"])
            ],
            memories: [Memory(text: "Ayşe is the user's sister", category: .person)],
            routines: [
                Routine(
                    title: "Morning", prompt: "Summarise my day",
                    schedule: RoutineSchedule(hour: 9, minute: 0, weekdays: [2, 3]))
            ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try decode(String(decoding: try encoder.encode(original), as: UTF8.self))
        #expect(decoded.tasks.first?.recurrence == original.tasks.first?.recurrence)
        #expect(decoded.tasks.first?.priority == .high)
        #expect(decoded.tasks.first?.tags == ["health"])
        #expect(decoded.memories.first?.category == .person)
        #expect(decoded.routines.first?.schedule.weekdays == [2, 3])
    }
}

@Suite("Recurrence")
struct RecurrenceTests {
    let calendar = testCalendar()

    @Test("daily, weekly and yearly steps keep the time of day")
    func simpleSteps() {
        let start = date(2026, 9, 26, 15, 30)
        #expect(
            Recurrence(frequency: .daily).next(after: start, calendar: calendar)
                == date(2026, 9, 27, 15, 30))
        #expect(
            Recurrence(frequency: .daily, interval: 3).next(after: start, calendar: calendar)
                == date(2026, 9, 29, 15, 30))
        #expect(
            Recurrence(frequency: .weekly, interval: 2).next(after: start, calendar: calendar)
                == date(2026, 10, 10, 15, 30))
        #expect(
            Recurrence(frequency: .yearly).next(after: start, calendar: calendar)
                == date(2027, 9, 26, 15, 30))
    }

    @Test("weekdays skip the weekend")
    func weekdays() {
        let friday = date(2026, 9, 25)
        let rule = Recurrence(frequency: .weekdays)
        #expect(rule.next(after: friday, calendar: calendar) == date(2026, 9, 28))
        #expect(rule.next(after: date(2026, 9, 28), calendar: calendar) == date(2026, 9, 29))
    }

    @Test("monthly clamps to short months and returns to the anchor day")
    func monthEnd() {
        let rule = Recurrence(frequency: .monthly, anchorDay: 31)
        let january = date(2026, 1, 31)
        let february = rule.next(after: january, calendar: calendar)
        #expect(february == date(2026, 2, 28))
        #expect(rule.next(after: date(2026, 2, 28), calendar: calendar) == date(2026, 3, 31))
        #expect(rule.next(after: date(2026, 3, 31), calendar: calendar) == date(2026, 4, 30))
        // Leap year February.
        #expect(rule.next(after: date(2028, 1, 31), calendar: calendar) == date(2028, 2, 29))
    }

    @Test("yearly on 29 February falls back to the 28th and returns in leap years")
    func leapYear() {
        let rule = Recurrence(frequency: .yearly, anchorDay: 29)
        #expect(rule.next(after: date(2028, 2, 29), calendar: calendar) == date(2029, 2, 28))
        #expect(rule.next(after: date(2031, 2, 28), calendar: calendar) == date(2032, 2, 29))
        let fourYears = Recurrence(frequency: .yearly, interval: 4, anchorDay: 29)
        #expect(fourYears.next(after: date(2028, 2, 29), calendar: calendar) == date(2032, 2, 29))
    }

    @Test("an overdue task moves to its next future date")
    func skipsPast() {
        let rule = Recurrence(frequency: .daily)
        let now = date(2026, 9, 26, 22)
        #expect(
            rule.next(after: date(2026, 9, 23), notBefore: now, calendar: calendar)
                == date(2026, 9, 27))
    }

    @Test("the next occurrence moves the reminder with the due date and keeps the details")
    func nextOccurrence() throws {
        let task = TaskItem(
            title: "Pay rent", notes: "Bank transfer", dueDate: date(2026, 1, 31, 12),
            remindAt: date(2026, 1, 31, 10), recurrence: Recurrence(frequency: .monthly),
            priority: .high, tags: ["home"])
        let next = try #require(
            task.nextOccurrence(completedAt: date(2026, 1, 30), calendar: calendar))
        #expect(next.id != task.id)
        #expect(next.dueDate == date(2026, 2, 28, 12))
        #expect(next.remindAt == date(2026, 2, 28, 10))
        #expect(next.recurrence?.anchorDay == 31)
        #expect(next.priority == .high)
        #expect(next.tags == ["home"])
        #expect(next.notes == "Bank transfer")
        #expect(!next.isDone)
        let after = try #require(
            next.nextOccurrence(completedAt: date(2026, 2, 27), calendar: calendar))
        #expect(after.dueDate == date(2026, 3, 31, 12))
    }

    @Test("a repeating task without dates gets one")
    func undatedOccurrence() throws {
        let task = TaskItem(title: "Water plants", recurrence: Recurrence(frequency: .daily))
        let next = try #require(
            task.nextOccurrence(completedAt: date(2026, 9, 26, 20), calendar: calendar))
        #expect(next.dueDate == date(2026, 9, 27, 9))
        #expect(TaskItem(title: "Once").nextOccurrence() == nil)
    }

    @Test("parses frequency names")
    func parsing() {
        #expect(Recurrence("Weekdays")?.frequency == .weekdays)
        #expect(Recurrence("every month")?.frequency == .monthly)
        #expect(Recurrence("fortnightly") == nil)
        #expect(Recurrence(frequency: .weekly, interval: 2).summary == "every 2 weeks")
    }
}

@Suite("Routine schedule")
struct RoutineScheduleTests {
    let calendar = testCalendar()

    @Test("finds the latest and next scheduled times")
    func latestAndNext() {
        let weekdays = RoutineSchedule(hour: 9, minute: 0, weekdays: RoutineSchedule.workweek)
        let saturday = date(2026, 9, 26, 12)
        #expect(weekdays.latest(atOrBefore: saturday, calendar: calendar) == date(2026, 9, 25))
        #expect(weekdays.next(after: saturday, calendar: calendar) == date(2026, 9, 28))
        let daily = RoutineSchedule(hour: 21, minute: 15)
        #expect(daily.latest(atOrBefore: saturday, calendar: calendar) == date(2026, 9, 25, 21, 15))
        #expect(daily.next(after: saturday, calendar: calendar) == date(2026, 9, 26, 21, 15))
    }

    @Test("is due once after its time, and not for runs before it was created")
    func due() {
        let schedule = RoutineSchedule(hour: 9, minute: 0)
        var routine = Routine(
            title: "Morning", prompt: "Summarise my day", schedule: schedule,
            createdAt: date(2026, 9, 26, 10))
        #expect(!routine.isDue(at: date(2026, 9, 26, 11), calendar: calendar))
        #expect(routine.isDue(at: date(2026, 9, 27, 9, 0), calendar: calendar))
        routine.lastRun = date(2026, 9, 27, 9, 0)
        #expect(!routine.isDue(at: date(2026, 9, 27, 9, 1), calendar: calendar))
        routine.isEnabled = false
        #expect(!routine.isDue(at: date(2026, 9, 28, 9, 0), calendar: calendar))
    }

    @Test("catches up once after sleep, within the window")
    func catchUp() {
        let routine = Routine(
            title: "Morning", prompt: "Hi", schedule: RoutineSchedule(hour: 9, minute: 0),
            lastRun: date(2026, 9, 20, 9), createdAt: date(2026, 9, 1))
        // Several runs were missed; the latest one is two hours ago, so it runs once.
        #expect(routine.isDue(at: date(2026, 9, 26, 11), calendar: calendar))
        // The latest run is more than twelve hours ago: wait for the next one.
        #expect(!routine.isDue(at: date(2026, 9, 26, 22), calendar: calendar))
    }

    @Test("parses times and days")
    func parsing() {
        #expect(RoutineSchedule.parseTime("9:30").map { [$0.hour, $0.minute] } == [9, 30])
        #expect(RoutineSchedule.parseTime("21").map { [$0.hour, $0.minute] } == [21, 0])
        #expect(RoutineSchedule.parseTime("25:00") == nil)
        #expect(RoutineSchedule.parseDays("weekdays") == RoutineSchedule.workweek)
        #expect(RoutineSchedule.parseDays("daily") == [])
        #expect(RoutineSchedule.parseDays("Monday, Wednesday and fri") == [2, 4, 6])
        #expect(RoutineSchedule.parseDays("someday") == nil)
        #expect(
            RoutineSchedule(hour: 8, minute: 5, weekdays: [1, 2]).summary == "Mon, Sun at 08:05")
        #expect(
            RoutineSchedule(hour: 8, minute: 0, weekdays: [1, 2, 3, 4, 5, 6, 7]).isDaily)
    }
}
