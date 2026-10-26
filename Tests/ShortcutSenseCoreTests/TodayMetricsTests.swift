import Foundation
import XCTest
@testable import ShortcutSenseCore

/// AC-UI-03 / AC-UI-05 / AC-UI-07: every dashboard number must come from real
/// aggregates, and every metric must have a defined empty state.
final class TodayMetricsTests: XCTestCase {
    private var temp: TempStore!

    override func setUpWithError() throws { temp = try TempStore() }
    override func tearDownWithError() throws { temp.tearDown(); temp = nil }

    private func metrics(includeHourly: Bool = false) throws -> TodayMetrics {
        try DashboardService.today(for: TestDates.base, store: temp.store,
                                   timeZone: TestDates.utc, includeHourly: includeHourly)
    }

    func testEmptyDatabaseProducesZeroesNotFailures() throws {
        let result = try metrics()
        XCTAssertEqual(result.totalKeypresses, 0)
        XCTAssertEqual(result.shortcutUses, 0)
        XCTAssertEqual(result.appsUsed, 0)
        XCTAssertEqual(result.managedHotkeyTriggers, 0)
        XCTAssertTrue(result.topApps.isEmpty)
        XCTAssertTrue(result.topCombos.isEmpty)
        XCTAssertFalse(result.hasAnyData)
        XCTAssertEqual(result.sevenDaySeries.count, 7, "the fallback chart still needs its window")
    }

    func testKeypressTotalSumsAnonymousCountsOnly() throws {
        try temp.store.incrementAnonymousKeystrokes(date: TestDates.bucket(0),
                                                    bundleID: "com.apple.Safari", by: 10)
        try temp.store.incrementAnonymousKeystrokes(date: TestDates.bucket(0),
                                                    bundleID: "com.google.Chrome", by: 5)
        XCTAssertEqual(try metrics().totalKeypresses, 15)
    }

    func testShortcutUsesSumsComboCounts() throws {
        let combo = KeyCombo(keyCode: 8, modifiers: .command)
        try temp.store.incrementCombo(date: TestDates.bucket(0), bundleID: "com.apple.Safari",
                                      comboID: combo.comboID, by: 7)
        let result = try metrics()
        XCTAssertEqual(result.shortcutUses, 7)
        XCTAssertEqual(result.topCombos.first?.display, "Command+C")
    }

    func testAppsUsedCountsOnlyAppsWithSignal() throws {
        try temp.store.incrementAnonymousKeystrokes(date: TestDates.bucket(0),
                                                    bundleID: "com.apple.Safari", by: 1)
        try temp.store.incrementActivity(date: TestDates.bucket(0),
                                         bundleID: "com.apple.finder",
                                         field: .unknownOriginActivations, by: 1)
        try temp.store.incrementAnonymousKeystrokes(date: TestDates.bucket(0),
                                                    bundleID: "com.example.zero", by: 0)
        XCTAssertEqual(try metrics().appsUsed, 2)
    }

    func testManagedTriggersComeFromUsageNotInference() throws {
        let record = RegisteredShortcut(
            id: "s1", recommendationID: nil, targetBundleID: "com.apple.finder",
            keyCode: 8, carbonModifiers: 0x1900, displayCombo: "Control+Option+Shift+C",
            isActive: true, createdAt: "2026-03-02T09:00:00Z", lastErrorCode: nil)
        try temp.store.insertRegisteredShortcut(record)
        try temp.store.recordShortcutTrigger(shortcutID: "s1", date: TestDates.bucket(0))
        try temp.store.recordShortcutTrigger(shortcutID: "s1", date: TestDates.bucket(0))
        // An activation without a trigger must not inflate the count.
        try temp.store.incrementActivity(date: TestDates.bucket(0), bundleID: "com.apple.finder",
                                         field: .managedHotkeyActivations, by: 9)
        XCTAssertEqual(try metrics().managedHotkeyTriggers, 2)
    }

    func testTopAppsAreRankedByKeystrokesWithShares() throws {
        try temp.store.incrementAnonymousKeystrokes(date: TestDates.bucket(0),
                                                    bundleID: "com.apple.Safari", by: 30)
        try temp.store.incrementAnonymousKeystrokes(date: TestDates.bucket(0),
                                                    bundleID: "com.google.Chrome", by: 10)
        let apps = try metrics().topApps
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps[0].bundleID, "com.apple.Safari")
        XCTAssertEqual(apps[0].keystrokes, 30)
        XCTAssertEqual(apps[0].share, 0.75, accuracy: 0.001)
        XCTAssertEqual(apps[1].share, 0.25, accuracy: 0.001)
    }

    func testSevenDaySeriesEndsOnTheSelectedDay() throws {
        for offset in 0..<7 {
            try temp.store.incrementAnonymousKeystrokes(
                date: TestDates.bucket(-offset), bundleID: "com.apple.Safari", by: offset + 1)
        }
        let series = try metrics().sevenDaySeries
        XCTAssertEqual(series.count, 7)
        XCTAssertEqual(series.last?.date, TestDates.bucket(0))
        XCTAssertEqual(series.last?.keypresses, 1)
        XCTAssertEqual(series.first?.date, TestDates.bucket(-6))
    }

    func testHourlyIsNilUnlessRequested() throws {
        XCTAssertNil(try metrics(includeHourly: false).hourly,
                     "the UI must not be handed hour data it is not allowed to show")
        try temp.store.incrementHourly(date: TestDates.bucket(0),
                                       timeZoneIdentifier: TestDates.utc.identifier,
                                       hour: 9, keypresses: 4, shortcuts: 1)
        XCTAssertNil(try metrics(includeHourly: false).hourly)
        XCTAssertEqual(try metrics(includeHourly: true).hourly?.first?.keypresses, 4)
    }

    /// Metric definitions are keys, not English prose: the Mac layer localizes them
    /// so a Chinese locale never shows an English sentence.
    func testMetricDefinitionsAreLocalizationKeys() {
        let keys = [MetricDefinition.keypresses, MetricDefinition.shortcutUses,
                    MetricDefinition.appsUsed, MetricDefinition.managedTriggers,
                    MetricDefinition.topAppsMetric, MetricDefinition.heatmapMetric]
        for key in keys {
            XCTAssertTrue(key.hasPrefix("metric."), "\(key) must be a localization key")
        }
    }
}

/// AC-UI-06: the hourly table is additive, opt-in, and deletable.
final class HourlyAggregateTests: XCTestCase {
    private var temp: TempStore!

    override func setUpWithError() throws { temp = try TempStore() }
    override func tearDownWithError() throws { temp.tearDown(); temp = nil }

    func testHourlyCollectionIsOffByDefault() {
        XCTAssertFalse(temp.store.hourlyCollectionEnabled,
                       "a conservative launch default is required by the data contract")
    }

    func testHourlyCollectionCanBeEnabledAndDisabled() throws {
        try temp.store.setHourlyCollectionEnabled(true)
        XCTAssertTrue(temp.store.hourlyCollectionEnabled)
        try temp.store.setHourlyCollectionEnabled(false)
        XCTAssertFalse(temp.store.hourlyCollectionEnabled)
    }

    func testHourBucketMustBeInRange() throws {
        try temp.store.incrementHourly(date: "2026-03-02", timeZoneIdentifier: "UTC",
                                       hour: 24, keypresses: 5)
        try temp.store.incrementHourly(date: "2026-03-02", timeZoneIdentifier: "UTC",
                                       hour: -1, keypresses: 5)
        XCTAssertTrue(try temp.store.hourlyActivity(date: "2026-03-02",
                                                    timeZoneIdentifier: "UTC").isEmpty)
    }

    func testHourlyRowsAccumulatePerBucket() throws {
        for _ in 0..<3 {
            try temp.store.incrementHourly(date: "2026-03-02", timeZoneIdentifier: "UTC",
                                           hour: 14, keypresses: 2, shortcuts: 1)
        }
        let rows = try temp.store.hourlyActivity(date: "2026-03-02", timeZoneIdentifier: "UTC")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.keypresses, 6)
        XCTAssertEqual(rows.first?.shortcuts, 3)
    }

    func testHoursInDifferentTimeZonesDoNotCollide() throws {
        try temp.store.incrementHourly(date: "2026-03-02", timeZoneIdentifier: "UTC",
                                       hour: 9, keypresses: 1)
        try temp.store.incrementHourly(date: "2026-03-02", timeZoneIdentifier: "Asia/Tokyo",
                                       hour: 9, keypresses: 2)
        XCTAssertEqual(try temp.store.hourlyActivity(date: "2026-03-02",
                                                     timeZoneIdentifier: "UTC").first?.keypresses, 1)
        XCTAssertEqual(try temp.store.hourlyActivity(date: "2026-03-02",
                                                     timeZoneIdentifier: "Asia/Tokyo").first?.keypresses, 2)
    }

    func testPruningRemovesOldHoursButKeepsDaily() throws {
        try temp.store.incrementHourly(date: "2026-01-01", timeZoneIdentifier: "UTC",
                                       hour: 9, keypresses: 4)
        try temp.store.incrementHourly(date: TestDates.bucket(0),
                                       timeZoneIdentifier: "UTC", hour: 9, keypresses: 4)
        try temp.store.incrementAnonymousKeystrokes(date: "2026-01-01",
                                                    bundleID: "com.apple.Safari", by: 4)
        try temp.store.pruneHourly(olderThan: 30, now: TestDates.base, timeZone: TestDates.utc)
        XCTAssertTrue(try temp.store.hourlyActivity(date: "2026-01-01",
                                                    timeZoneIdentifier: "UTC").isEmpty)
        XCTAssertEqual(try temp.store.hourlyActivity(date: TestDates.bucket(0),
                                                     timeZoneIdentifier: "UTC").count, 1)
        XCTAssertFalse(try temp.store.dailyActivity(from: "2026-01-01",
                                                    to: "2026-01-01").isEmpty,
                       "pruning hourly history must not touch daily aggregates")
    }

    func testDeleteAllDataClearsHourlyToo() throws {
        try temp.store.incrementHourly(date: TestDates.bucket(0), timeZoneIdentifier: "UTC",
                                       hour: 9, keypresses: 4)
        try temp.store.deleteAllData()
        XCTAssertTrue(try temp.store.hourlyActivity(date: TestDates.bucket(0),
                                                    timeZoneIdentifier: "UTC").isEmpty)
        XCTAssertEqual(try temp.store.rowCounts()["hourly_keyboard_activity"], 0)
    }

    func testMigrationToV2IsIdempotent() throws {
        temp.store.close()
        for _ in 0..<3 {
            let store = try Store(path: temp.databasePath)
            XCTAssertNotNil(try? store.hourlyActivity(date: "2026-03-02", timeZoneIdentifier: "UTC"))
            store.close()
        }
    }

    func testSchemaVersionIsTwo() throws {
        XCTAssertEqual(try temp.store.debugPragmaInt("user_version"), 2)
    }
}
