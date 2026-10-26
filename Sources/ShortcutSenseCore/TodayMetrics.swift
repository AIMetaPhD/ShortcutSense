import Foundation

/// Everything the Today dashboard shows, derived from existing aggregates.
///
/// Every field carries the definition the UI must display next to it, because the
/// spec requires each KPI to state its metric, window and empty-state behaviour
/// (`12_UI_DATA_CONTRACT_DELTA.md` §"UI implementation invariants").
public struct TodayMetrics: Equatable, Sendable {
    public let date: String
    public let timeZoneIdentifier: String

    /// Sum of anonymous keystroke counts for the day, excluding excluded apps.
    public let totalKeypresses: Int
    /// Sum of normalized combo counts for the day.
    public let shortcutUses: Int
    /// Distinct bundle identifiers with any signal that day.
    public let appsUsed: Int
    /// Presses counted inside ShortcutSense's own hotkey handler, not inferred.
    public let managedHotkeyTriggers: Int

    /// Per-application keystroke totals, already ranked. Metric is **keystrokes**,
    /// never "time spent" — the app does not measure time.
    public let topApps: [AppKeystrokeTotal]
    /// Normalized combos ranked by count. Only safe command combinations exist here.
    public let topCombos: [ComboTotal]
    /// Seven daily totals ending on `date`, oldest first, for the fallback chart.
    public let sevenDaySeries: [DailyTotal]
    /// Hourly buckets when the user has enabled and populated them; else nil.
    public let hourly: [HourlyBucket]?

    public var hasAnyData: Bool {
        totalKeypresses > 0 || shortcutUses > 0 || appsUsed > 0 || managedHotkeyTriggers > 0
    }
}

public struct AppKeystrokeTotal: Equatable, Sendable {
    public let bundleID: String
    public let keystrokes: Int
    /// Share of the day's total keystrokes, 0…1. Zero when the total is zero.
    public let share: Double

    public init(bundleID: String, keystrokes: Int, share: Double) {
        self.bundleID = bundleID
        self.keystrokes = keystrokes
        self.share = share
    }
}

public struct ComboTotal: Equatable, Sendable {
    public let comboID: String
    public let display: String
    public let count: Int
    /// Applications that produced this combo today, for the filter control.
    public let bundleIDs: [String]

    public init(comboID: String, display: String, count: Int, bundleIDs: [String]) {
        self.comboID = comboID
        self.display = display
        self.count = count
        self.bundleIDs = bundleIDs
    }
}

public struct DailyTotal: Equatable, Sendable {
    public let date: String
    public let keypresses: Int
    public let shortcuts: Int

    public init(date: String, keypresses: Int, shortcuts: Int) {
        self.date = date
        self.keypresses = keypresses
        self.shortcuts = shortcuts
    }
}

public struct HourlyBucket: Equatable, Sendable {
    public let hour: Int
    public let keypresses: Int
    public let shortcuts: Int

    public init(hour: Int, keypresses: Int, shortcuts: Int) {
        self.hour = hour
        self.keypresses = keypresses
        self.shortcuts = shortcuts
    }
}

public enum DashboardService {
    /// Builds the dashboard model for one local day.
    ///
    /// `includeHourly` is only true when the user enabled hourly collection; the
    /// table is otherwise empty and the UI must fall back to the 7-day series rather
    /// than claim minute-level detail.
    public static func today(for date: Date, store: Store, timeZone: TimeZone,
                             includeHourly: Bool = false) throws -> TodayMetrics {
        let day = DateBuckets.bucket(for: date, timeZone: timeZone)
        let window = DateBuckets.rollingWindow(endingAt: date, days: 7, timeZone: timeZone)
        let windowStart = window.buckets.first ?? day
        let windowEnd = window.buckets.last ?? day

        let activity = try store.dailyActivity(from: day, to: day)
        let combos = try store.comboStats(from: day, to: day)
        let usage = try store.shortcutUsage(from: day, to: day)
        let weekActivity = try store.dailyActivity(from: windowStart, to: windowEnd)
        let weekCombos = try store.comboStats(from: windowStart, to: windowEnd)

        let totalKeypresses = activity.reduce(0) { $0 + $1.totalAnonymousKeystrokes }
        let managedTriggers = usage.reduce(0) { $0 + $1.triggerCount }

        // `daily_combo_stats` holds only normalized Command/Control combinations, so
        // summing it cannot expose ordinary characters.
        let shortcutUses = combos.reduce(0) { $0 + $1.count }
        let appsUsed = Set(activity.filter {
            $0.totalAnonymousKeystrokes > 0 || $0.observedKeyboardNavigation > 0
                || $0.unknownOriginActivations > 0 || $0.managedHotkeyActivations > 0
        }.map(\.bundleID)).count

        var perApp: [String: Int] = [:]
        for row in activity { perApp[row.bundleID, default: 0] += row.totalAnonymousKeystrokes }
        let topApps = perApp
            .filter { $0.value > 0 }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { entry in
                AppKeystrokeTotal(bundleID: entry.key, keystrokes: entry.value,
                                  share: totalKeypresses > 0 ? Double(entry.value) / Double(totalKeypresses) : 0)
            }

        var perCombo: [String: (count: Int, apps: Set<String>)] = [:]
        for row in combos {
            var entry = perCombo[row.comboID] ?? (0, [])
            entry.count += row.count
            entry.apps.insert(row.bundleID)
            perCombo[row.comboID] = entry
        }
        let topCombos = perCombo
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            .map { entry in
                ComboTotal(comboID: entry.key,
                           display: KeyComboCodec.decode(entry.key)?.displayString ?? entry.key,
                           count: entry.value.count,
                           bundleIDs: entry.value.apps.sorted())
            }

        var weekByDate: [String: DailyTotal] = [:]
        for bucket in window.buckets {
            weekByDate[bucket] = DailyTotal(date: bucket, keypresses: 0, shortcuts: 0)
        }
        for row in weekActivity {
            guard var entry = weekByDate[row.date] else { continue }
            entry = DailyTotal(date: entry.date,
                               keypresses: entry.keypresses + row.totalAnonymousKeystrokes,
                               shortcuts: entry.shortcuts)
            weekByDate[row.date] = entry
        }
        for row in weekCombos {
            guard var entry = weekByDate[row.date] else { continue }
            entry = DailyTotal(date: entry.date, keypresses: entry.keypresses,
                               shortcuts: entry.shortcuts + row.count)
            weekByDate[row.date] = entry
        }
        let sevenDaySeries = window.buckets.compactMap { weekByDate[$0] }

        let hourly = includeHourly
            ? try store.hourlyActivity(date: day, timeZoneIdentifier: timeZone.identifier)
            : nil

        return TodayMetrics(
            date: day, timeZoneIdentifier: timeZone.identifier,
            totalKeypresses: totalKeypresses, shortcutUses: shortcutUses,
            appsUsed: appsUsed, managedHotkeyTriggers: managedTriggers,
            topApps: topApps, topCombos: topCombos,
            sevenDaySeries: sevenDaySeries, hourly: hourly)
    }
}

// MARK: - Metric definitions shown next to each number

/// Metric definitions shown next to each number.
///
/// Localized at the presentation layer: the core holds the keys, and the Mac target
/// maps them through `L.t` so a Chinese locale never shows an English definition.
public enum MetricDefinition {
    public static func windowLabel(for metrics: TodayMetrics) -> String {
        metrics.date
    }

    public static let keypresses = "metric.keypresses"
    public static let shortcutUses = "metric.shortcutUses"
    public static let appsUsed = "metric.appsUsed"
    public static let managedTriggers = "metric.managedTriggers"
    public static let topAppsMetric = "metric.topApps"
    public static let heatmapMetric = "metric.heatmap"

    /// Resolves a metric key in the active locale. The core cannot localize on its
    /// own, so the app supplies the strings.
    public static func localized(_ key: String,
                                 _ resolve: (String) -> String) -> String {
        resolve(key)
    }
}