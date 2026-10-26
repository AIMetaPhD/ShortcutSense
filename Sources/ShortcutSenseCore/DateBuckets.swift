import Foundation

/// Calendar arithmetic for day buckets and rolling 7-day windows.
///
/// All bucketing is done in the user's collection time zone, which is captured the
/// first time collection starts. Tests cover DST transitions and time zone changes.
public enum DateBuckets {
    /// `yyyy-MM-dd` in the given time zone.
    public static func bucket(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Every bucket string from `start` through `end` inclusive.
    public static func buckets(from start: Date, through end: Date, timeZone: TimeZone) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var result: [String] = []
        var cursor = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while cursor <= last {
            result.append(bucket(for: cursor, timeZone: timeZone))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// Rolling window: the last `days` days ending today, inclusive.
    public static func rollingWindow(endingAt now: Date, days: Int, timeZone: TimeZone) -> (start: Date, end: Date, buckets: [String]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        return (start, end, buckets(from: start, through: end, timeZone: timeZone))
    }

    /// The most recent fully completed natural week (Monday 00:00 → Sunday 23:59:59)
    /// before `now`. Used by the weekly review scheduler.
    public static func previousNaturalWeek(before now: Date, timeZone: TimeZone) -> (start: Date, end: Date, buckets: [String]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2 // Monday
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today) // 1 = Sunday … 7 = Saturday
        // Days since the most recent Monday (Monday itself → 0).
        let daysSinceMonday = (weekday + 5) % 7
        guard let thisMonday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today),
              let lastMonday = calendar.date(byAdding: .day, value: -7, to: thisMonday),
              let lastSunday = calendar.date(byAdding: .day, value: 6, to: lastMonday)
        else { return (today, today, []) }
        return (lastMonday, lastSunday, buckets(from: lastMonday, through: lastSunday, timeZone: timeZone))
    }

    /// The natural week containing `now` (Monday → Sunday).
    public static func naturalWeek(containing now: Date, timeZone: TimeZone) -> (start: Date, end: Date, buckets: [String]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let daysSinceMonday = (weekday + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today),
              let sunday = calendar.date(byAdding: .day, value: 6, to: monday)
        else { return (today, today, []) }
        return (monday, sunday, buckets(from: monday, through: sunday, timeZone: timeZone))
    }

    /// Whether at least `days` full days of real collection data exist.
    public static func hasFullDaysSinceFirstCollection(_ first: Date?, now: Date, days: Int, timeZone: TimeZone) -> Bool {
        guard let first else { return false }
        let elapsed = now.timeIntervalSince(first)
        return elapsed >= Double(days) * 86_400
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func iso8601(_ date: Date) -> String { isoFormatter.string(from: date) }

    public static func parseISO8601(_ string: String) -> Date? { isoFormatter.date(from: string) }
}
