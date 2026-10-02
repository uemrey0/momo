import Foundation
import MomoKit
import Testing

@testable import MomoApp

@MainActor
@Suite("Routine scheduler")
struct RoutineSchedulerTests {
    /// 3 October 2026, 09:05 UTC: just after a daily 09:00 routine came due.
    private let start = Date(timeIntervalSince1970: 1_791_018_300)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    @Test("runs a routine once even when saving the run fails")
    func failedSaveDoesNotRepeat() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MomoStore(fileURL: folder.appendingPathComponent("data.json"))
        let routine = Routine(
            title: "Morning", prompt: "Plan my day", schedule: RoutineSchedule(hour: 9, minute: 0),
            createdAt: start.addingTimeInterval(-86_400))
        try await store.saveRoutine(routine)
        // A folder that can't be written makes every later save fail.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }

        var now = start
        var sent: [String] = []
        var replies: [(String?) -> Void] = []
        let scheduler = RoutineScheduler(
            store: store, assistant: nil,
            send: { prompt, completion in
                sent.append(prompt)
                replies.append(completion)
                return true
            },
            clock: { now }, calendar: calendar)

        await scheduler.check()
        #expect(sent == ["Plan my day"])
        #expect(await store.routines().first?.lastRun == nil)

        for minutes in [0.5, 1, 30, 120] {
            // Each run finishes before the next check, so only the schedule can hold it back.
            replies.forEach { $0(nil) }
            replies = []
            now = start.addingTimeInterval(minutes * 60)
            await scheduler.check()
        }
        #expect(sent == ["Plan my day"])
    }
}
