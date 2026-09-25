import EventKit
import Foundation
import MomoKit

/// Reads and adds calendar events through EventKit. Google and Outlook calendars appear here
/// too once the user adds those accounts to macOS.
final class CalendarService: @unchecked Sendable {
    private let store = EKEventStore()

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    var hasBeenAsked: Bool {
        EKEventStore.authorizationStatus(for: .event) != .notDetermined
    }

    /// Asks for full calendar access. Returns whether it was granted.
    @discardableResult
    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Events overlapping the period, sorted by start date.
    func events(from start: Date, to end: Date) -> [EKEvent] {
        guard isAuthorized else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    func addEvent(title: String, start: Date, end: Date, notes: String?) throws -> EKEvent {
        guard isAuthorized else { throw ToolError("Calendar access is not allowed.") }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
        return event
    }

    /// Describes an event for a model, e.g. "09:30–10:00 Stand-up (Work) @ Room 2".
    static func describe(_ event: EKEvent) -> String {
        var text: String
        if event.isAllDay {
            text = "\(DayKey.string(for: event.startDate)) all day: \(event.title ?? "")"
        } else {
            text =
                "\(FlexibleDate.format(event.startDate))–\(time(event.endDate)) \(event.title ?? "")"
        }
        if let calendar = event.calendar?.title { text += " (\(calendar))" }
        if let location = event.location, !location.isEmpty { text += " @ \(location)" }
        return text
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
