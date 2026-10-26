import Foundation

public struct WeeklyReport: Equatable, Sendable {
    public let reviewID: String
    public let periodStart: String
    public let periodEnd: String
    public let generatedAt: Date
    /// True when fewer than seven days of real collection exist. Preview reports are
    /// labelled as such in the UI and never claim real weekly behaviour.
    public let isPreview: Bool
    public let totalAnonymousKeystrokes: Int
    public let topCombos: [ComboSummary]
    public let adoptedShortcuts: [AdoptedShortcutSummary]
    public let newCandidates: Int

    public init(reviewID: String, periodStart: String, periodEnd: String, generatedAt: Date,
                isPreview: Bool, totalAnonymousKeystrokes: Int, topCombos: [ComboSummary],
                adoptedShortcuts: [AdoptedShortcutSummary], newCandidates: Int) {
        self.reviewID = reviewID
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.generatedAt = generatedAt
        self.isPreview = isPreview
        self.totalAnonymousKeystrokes = totalAnonymousKeystrokes
        self.topCombos = topCombos
        self.adoptedShortcuts = adoptedShortcuts
        self.newCandidates = newCandidates
    }
}

public struct ComboSummary: Equatable, Sendable {
    public let comboID: String
    public let display: String
    public let count: Int
    public init(comboID: String, display: String, count: Int) {
        self.comboID = comboID; self.display = display; self.count = count
    }
}

public struct AdoptedShortcutSummary: Equatable, Sendable {
    public let shortcutID: String
    public let displayCombo: String
    public let targetBundleID: String
    /// Measured: counted inside ShortcutSense's own hotkey handler.
    public let triggerCount: Int
    /// Measured separately: activations attributed to that handler.
    public let successfulActivations: Int
    /// Always `true` — the UI must label these numbers as measured, not estimated.
    public let isMeasured: Bool
    public init(shortcutID: String, displayCombo: String, targetBundleID: String,
                triggerCount: Int, successfulActivations: Int) {
        self.shortcutID = shortcutID; self.displayCombo = displayCombo
        self.targetBundleID = targetBundleID; self.triggerCount = triggerCount
        self.successfulActivations = successfulActivations
        self.isMeasured = true
    }
}

public enum WeeklyReviewError: Error, Equatable {
    case nothingToReport
}

/// Generates and de-duplicates weekly reports.
///
/// Scheduling contract:
/// - Reports are generated when the app is running (or on next launch after the
///   scheduled time). The app never claims the report was produced at 09:00 if it
///   was asleep; `generatedAt` is the real time.
/// - Generation is idempotent per `(periodStart, periodEnd, isPreview)`.
public struct WeeklyReviewService {
    public let store: Store

    public init(store: Store) { self.store = store }

    public struct Outcome: Sendable {
        public let report: WeeklyReport
        public let wasCreated: Bool
    }

    /// Generates the review for the last completed natural week (or the current week
    /// when `useCurrentWeek` is true), or returns the existing one.
    public func generateIfNeeded(now: Date = Date(), useCurrentWeek: Bool = false) throws -> Outcome {
        let timeZone = store.collectionTimeZone
        let window = useCurrentWeek
            ? DateBuckets.naturalWeek(containing: now, timeZone: timeZone)
            : DateBuckets.previousNaturalWeek(before: now, timeZone: timeZone)
        return try generate(periodStart: window.start, periodEnd: window.end,
                            buckets: window.buckets, now: now, timeZone: timeZone)
    }

    public func generate(periodStart: Date, periodEnd: Date, buckets: [String],
                         now: Date, timeZone: TimeZone) throws -> Outcome {
        let firstCollection = store.firstCollectionStartedAt()
        let isPreview = !DateBuckets.hasFullDaysSinceFirstCollection(
            firstCollection, now: periodEnd, days: 7, timeZone: timeZone)

        let startBucket = buckets.first ?? DateBuckets.bucket(for: periodStart, timeZone: timeZone)
        let endBucket = buckets.last ?? DateBuckets.bucket(for: periodEnd, timeZone: timeZone)

        let activity = try store.dailyActivity(from: startBucket, to: endBucket)
        let combos = try store.comboStats(from: startBucket, to: endBucket)
        let usage = try store.shortcutUsage(from: startBucket, to: endBucket)
        let registered = try store.registeredShortcuts()
        let pending = try store.recommendations(status: .pending)

        let totalKeys = activity.reduce(0) { $0 + $1.totalAnonymousKeystrokes }

        var byCombo: [String: Int] = [:]
        for row in combos { byCombo[row.comboID, default: 0] += row.count }
        let topCombos = byCombo
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(5)
            .map { entry -> ComboSummary in
                let display = KeyComboCodec.decode(entry.key)?.displayString ?? entry.key
                return ComboSummary(comboID: entry.key, display: display, count: entry.value)
            }

        var usageByShortcut: [String: (trigger: Int, success: Int)] = [:]
        for row in usage {
            var current = usageByShortcut[row.shortcutID] ?? (0, 0)
            current.trigger += row.triggerCount
            current.success += row.successfulTargetActivations
            usageByShortcut[row.shortcutID] = current
        }
        let adopted = registered.compactMap { shortcut -> AdoptedShortcutSummary? in
            guard let counts = usageByShortcut[shortcut.id] else { return nil }
            return AdoptedShortcutSummary(
                shortcutID: shortcut.id, displayCombo: shortcut.displayCombo,
                targetBundleID: shortcut.targetBundleID,
                triggerCount: counts.trigger, successfulActivations: counts.success)
        }

        let reviewID = "\(startBucket)_\(endBucket)_\(isPreview ? "preview" : "final")"
        let record = WeeklyReviewRecord(
            reviewID: reviewID, periodStart: startBucket, periodEnd: endBucket,
            generatedAt: DateBuckets.iso8601(now), isPreview: isPreview)
        let wasCreated = try store.insertWeeklyReview(record)

        let report = WeeklyReport(
            reviewID: reviewID, periodStart: startBucket, periodEnd: endBucket,
            generatedAt: now, isPreview: isPreview,
            totalAnonymousKeystrokes: totalKeys, topCombos: topCombos,
            adoptedShortcuts: adopted, newCandidates: pending.count)
        return Outcome(report: report, wasCreated: wasCreated)
    }

    /// Whether the scheduled time has passed since the last generated period.
    public func isDue(now: Date = Date(), schedule: WeeklySchedule = .default) -> Bool {
        let timeZone = store.collectionTimeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        let weekday = components.weekday ?? 1
        // Calendar weekday: 1 = Sunday … 7 = Saturday. Schedule uses 2 = Monday.
        let scheduledWeekday = schedule.weekday
        let minutesNow = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let scheduledMinutes = schedule.hour * 60 + schedule.minute
        guard weekday == scheduledWeekday, minutesNow >= scheduledMinutes else { return false }

        let window = DateBuckets.previousNaturalWeek(before: now, timeZone: timeZone)
        let startBucket = window.buckets.first ?? ""
        let endBucket = window.buckets.last ?? ""
        guard let last = store.lastWeeklyReviewPeriod() else { return true }
        return !(last.start == startBucket && last.end == endBucket)
    }
}

public struct WeeklySchedule: Equatable, Sendable {
    /// Calendar weekday, 1 = Sunday … 7 = Saturday. Default Monday.
    public let weekday: Int
    public let hour: Int
    public let minute: Int
    public let notificationsEnabled: Bool

    public init(weekday: Int = 2, hour: Int = 9, minute: Int = 0, notificationsEnabled: Bool = false) {
        self.weekday = weekday; self.hour = hour; self.minute = minute
        self.notificationsEnabled = notificationsEnabled
    }

    public static let `default` = WeeklySchedule()
}
