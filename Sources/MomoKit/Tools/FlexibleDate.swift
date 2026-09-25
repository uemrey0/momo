import Foundation

/// Parses the date formats models tend to produce, in the user's time zone.
public enum FlexibleDate {
    /// Accepts ISO 8601 with or without time zone, seconds or time
    /// (`2026-09-27T15:00:00Z`, `2026-09-27T15:00`, `2026-09-27 15:00`, `2026-09-27`).
    public static func parse(
        _ text: String, timeZone: TimeZone = .current, calendar: Calendar = .current
    ) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: trimmed) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: trimmed) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.calendar = Calendar(identifier: .gregorian)
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                if format == "yyyy-MM-dd" {
                    // A bare day means the start of that day's working hours.
                    return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date)
                }
                return date
            }
        }
        return nil
    }

    /// Formats a date for the model: local time with offset, e.g. `2026-09-27T15:00+03:00`.
    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [
            .withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate,
            .withTimeZone, .withColonSeparatorInTimeZone,
        ]
        return formatter.string(from: date)
    }
}
