import Foundation
import MomoKit

/// Runs routines when they are due: each prompt goes through the assistant as a background
/// message in the chat conversation, and the start of the reply arrives as a notification.
///
/// A Mac that slept through a routine catches up once when it wakes (see `Routine.isDue`).
/// Routines that come due while Momo is busy wait in a queue.
@MainActor
final class RoutineScheduler {
    private let store: MomoStore
    private let assistant: AssistantController
    private let clock: () -> Date
    private let calendar: Calendar
    /// Posts a notification: identifier, title, body.
    var notify: ((String, String, String) -> Void)?

    private var queue: [Routine] = []
    private var running: Routine?
    private var tick: Task<Void, Never>?
    private var retry: Task<Void, Never>?

    init(
        store: MomoStore, assistant: AssistantController, clock: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.store = store
        self.assistant = assistant
        self.clock = clock
        self.calendar = calendar
    }

    func start() {
        assistant.onAttentionNeeded = { [weak self] in self?.needsAttention() }
        tick = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Queues every routine that is due and starts the first one.
    func check() async {
        let now = clock()
        for routine in await store.routines() where routine.isDue(at: now, calendar: calendar) {
            guard !isPending(routine) else { continue }
            // Recorded before it runs, so a busy Momo or a restart never runs it twice.
            try? await store.markRoutineRun(id: routine.id, at: now)
            queue.append(routine)
        }
        runNext()
    }

    /// Runs a routine right away (or as soon as Momo is free), whatever its schedule.
    func runNow(_ routine: Routine) {
        guard !isPending(routine) else { return }
        Task { try? await store.markRoutineRun(id: routine.id, at: clock()) }
        queue.append(routine)
        runNext()
    }

    private func isPending(_ routine: Routine) -> Bool {
        running?.id == routine.id || queue.contains { $0.id == routine.id }
    }

    private func runNext() {
        guard running == nil, let routine = queue.first else { return }
        let started = assistant.sendInBackground(routine.prompt) { [weak self] reply in
            self?.finished(routine, reply: reply)
        }
        guard started else {
            // Momo is answering something else; try again shortly.
            retry?.cancel()
            retry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.runNext()
            }
            return
        }
        queue.removeFirst()
        running = routine
    }

    private func finished(_ routine: Routine, reply: String?) {
        running = nil
        if let reply {
            notify?(
                "routine-\(routine.id)-\(Int(clock().timeIntervalSince1970))", routine.title,
                Self.preview(reply))
        }
        runNext()
    }

    private func needsAttention() {
        guard let running else { return }
        notify?(
            "routine-\(running.id)-attention", running.title,
            L("Momo needs your answer to finish this routine."))
    }

    /// The start of a reply as plain text, short enough for a notification.
    static func preview(_ reply: String, limit: Int = 180) -> String {
        let plain =
            reply
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isNewline)
            .map {
                $0.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#-*• "))
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard plain.count > limit else { return plain }
        return plain.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}
