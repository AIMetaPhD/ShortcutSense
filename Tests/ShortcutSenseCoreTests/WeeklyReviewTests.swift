import Foundation
import XCTest
@testable import ShortcutSenseCore

/// AC-14 / AC-22: preview vs real reports, idempotency and measured adoption numbers.
final class WeeklyReviewTests: XCTestCase {
    private var temp: TempStore!
    private var service: WeeklyReviewService!

    override func setUpWithError() throws {
        temp = try TempStore()
        service = WeeklyReviewService(store: temp.store)
    }

    override func tearDownWithError() throws {
        temp.tearDown(); temp = nil; service = nil
    }

    private func seedActivity(daysAgo: Int, count: Int, bundle: String = "com.google.Chrome") throws {
        let date = TestDates.base.addingTimeInterval(-Double(daysAgo) * 86_400)
        let bucket = DateBuckets.bucket(for: date, timeZone: TestDates.utc)
        try temp.store.incrementActivity(date: bucket, bundleID: bundle,
                                         field: .unknownOriginActivations, by: count)
    }

    // MARK: - Preview vs final

    func testLessThanSevenDaysOfCollectionProducesPreview() throws {
        // Collection started 3 days ago.
        try temp.store.markFirstCollectionStarted(at: TestDates.day(-3), timeZone: TestDates.utc)
        try seedActivity(daysAgo: 1, count: 4)

        let outcome = try service.generateIfNeeded(now: TestDates.day(0))
        XCTAssertTrue(outcome.report.isPreview, "under seven days must be a preview")
        XCTAssertTrue(outcome.wasCreated)
    }

    func testSevenOrMoreDaysOfCollectionProducesFinalReport() throws {
        try temp.store.markFirstCollectionStarted(at: TestDates.day(-10), timeZone: TestDates.utc)
        try seedActivity(daysAgo: 2, count: 9)

        let outcome = try service.generateIfNeeded(now: TestDates.day(0))
        XCTAssertFalse(outcome.report.isPreview)
        XCTAssertEqual(outcome.report.periodStart, "2026-02-23")
        XCTAssertEqual(outcome.report.periodEnd, "2026-03-01")
    }

    func testNoCollectionHistoryProducesPreviewNotFakeData() throws {
        let outcome = try service.generateIfNeeded(now: TestDates.day(0))
        XCTAssertTrue(outcome.report.isPreview)
        XCTAssertEqual(outcome.report.totalAnonymousKeystrokes, 0)
        XCTAssertTrue(outcome.report.adoptedShortcuts.isEmpty)
    }

    // MARK: - Idempotency

    func testGeneratingTwiceDoesNotDuplicateThePeriod() throws {
        try temp.store.markFirstCollectionStarted(at: TestDates.day(-10), timeZone: TestDates.utc)
        let first = try service.generateIfNeeded(now: TestDates.day(0))
        let second = try service.generateIfNeeded(now: TestDates.day(0).addingTimeInterval(3600))

        XCTAssertTrue(first.wasCreated)
        XCTAssertFalse(second.wasCreated, "the same period must not be created twice")
        XCTAssertEqual(try temp.store.weeklyReviews().count, 1)
    }

    func testRepeatedLaunchesAcrossTheWeekKeepOneRowPerPeriod() throws {
        try temp.store.markFirstCollectionStarted(at: TestDates.day(-20), timeZone: TestDates.utc)
        for hour in 0..<6 {
            _ = try service.generateIfNeeded(now: TestDates.day(0).addingTimeInterval(Double(hour) * 3600))
        }
        XCTAssertEqual(try temp.store.weeklyReviews().count, 1)
    }

    // MARK: - Adoption numbers

    func testAdoptedShortcutUsageIsMeasuredNotEstimated() throws {
        try temp.store.markFirstCollectionStarted(at: TestDates.day(-10), timeZone: TestDates.utc)
        let record = RegisteredShortcut(
            id: "s1", recommendationID: "r1", targetBundleID: "com.google.Chrome",
            keyCode: 8, carbonModifiers: 0x1900, displayCombo: "Control+Option+Shift+C",
            isActive: true, createdAt: "2026-02-20T09:00:00Z", lastErrorCode: nil)
        try temp.store.insertRegisteredShortcut(record)
        try temp.store.recordShortcutTrigger(shortcutID: "s1", date: "2026-02-25")
        try temp.store.recordShortcutTrigger(shortcutID: "s1", date: "2026-02-26")
        try temp.store.recordShortcutSuccessfulActivation(shortcutID: "s1", date: "2026-02-25")

        let outcome = try service.generateIfNeeded(now: TestDates.day(0))
        let adopted = try XCTUnwrap(outcome.report.adoptedShortcuts.first)
        XCTAssertEqual(adopted.triggerCount, 2)
        XCTAssertEqual(adopted.successfulActivations, 1)
        XCTAssertTrue(adopted.isMeasured)
    }

    func testTopCombosAreAggregatedAndReadable() throws {
        try temp.store.markFirstCollectionStarted(at: TestDates.day(-10), timeZone: TestDates.utc)
        let combo = KeyCombo(keyCode: 8, modifiers: .command)
        try temp.store.incrementCombo(date: "2026-02-24", bundleID: "com.google.Chrome",
                                      comboID: combo.comboID, by: 6)
        try temp.store.incrementCombo(date: "2026-02-25", bundleID: "com.google.Chrome",
                                      comboID: combo.comboID, by: 4)
        let outcome = try service.generateIfNeeded(now: TestDates.day(0))
        XCTAssertEqual(outcome.report.topCombos.first?.count, 10)
        XCTAssertEqual(outcome.report.topCombos.first?.display, "Command+C")
    }

    // MARK: - Scheduling

    func testScheduleIsDueOnlyAfterTheScheduledMinute() throws {
        try temp.store.markFirstCollectionStarted(at: TestDates.day(-10), timeZone: TestDates.utc)
        // TestDates.base is Monday 09:00 UTC.
        XCTAssertTrue(service.isDue(now: TestDates.base, schedule: WeeklySchedule(weekday: 2, hour: 9, minute: 0)))
        XCTAssertFalse(service.isDue(now: TestDates.base.addingTimeInterval(-60),
                                     schedule: WeeklySchedule(weekday: 2, hour: 9, minute: 0)))
        XCTAssertFalse(service.isDue(now: TestDates.base, schedule: WeeklySchedule(weekday: 2, hour: 10, minute: 0)))
    }

    func testNotDueOnAnotherWeekday() throws {
        try temp.store.markFirstCollectionStarted(at: TestDates.day(-10), timeZone: TestDates.utc)
        // 2026-03-03 is a Tuesday.
        XCTAssertFalse(service.isDue(now: TestDates.day(1), schedule: WeeklySchedule(weekday: 2, hour: 9, minute: 0)))
    }

    func testAfterGenerationTheSamePeriodIsNoLongerDue() throws {
        try temp.store.markFirstCollectionStarted(at: TestDates.day(-10), timeZone: TestDates.utc)
        _ = try service.generateIfNeeded(now: TestDates.base)
        XCTAssertFalse(service.isDue(now: TestDates.base.addingTimeInterval(600),
                                     schedule: WeeklySchedule(weekday: 2, hour: 9, minute: 0)))
    }

    func testMissedScheduleIsCaughtUpOnNextLaunch() throws {
        try temp.store.markFirstCollectionStarted(at: TestDates.day(-10), timeZone: TestDates.utc)
        // Simulate a Mac asleep at 09:00: nothing generated.
        XCTAssertTrue(try temp.store.weeklyReviews().isEmpty)
        // Next launch at 14:30 the same day: generation still happens, and the real
        // generation time is recorded rather than the scheduled time.
        let late = TestDates.base.addingTimeInterval(5.5 * 3600)
        let outcome = try service.generateIfNeeded(now: late)
        XCTAssertTrue(outcome.wasCreated)
        XCTAssertEqual(outcome.report.generatedAt, late)
    }
}

/// AC-08: day bucketing across DST and time zone changes.
final class DateBucketsTests: XCTestCase {
    func testBucketUsesTheGivenTimeZone() {
        // 2026-03-02 23:30 UTC is 2026-03-03 in Tokyo.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let instant = TestDates.base.addingTimeInterval(14.5 * 3600)
        XCTAssertEqual(DateBuckets.bucket(for: instant, timeZone: TestDates.utc), "2026-03-02")
        XCTAssertEqual(DateBuckets.bucket(for: instant, timeZone: tokyo), "2026-03-03")
    }

    func testRollingWindowHasExactlySevenBuckets() {
        let window = DateBuckets.rollingWindow(endingAt: TestDates.base, days: 7, timeZone: TestDates.utc)
        XCTAssertEqual(window.buckets.count, 7)
        XCTAssertEqual(window.buckets.first, "2026-02-24")
        XCTAssertEqual(window.buckets.last, "2026-03-02")
    }

    func testDSTSpringForwardKeepsDailyBuckets() {
        // US DST begins 2026-03-08. A seven-day window crossing it must still yield
        // seven distinct day buckets.
        let newYork = TimeZone(identifier: "America/New_York")!
        let afterDST = TestDates.day(8)
        let window = DateBuckets.rollingWindow(endingAt: afterDST, days: 7, timeZone: newYork)
        XCTAssertEqual(window.buckets.count, 7)
        XCTAssertEqual(Set(window.buckets).count, 7, "DST must not duplicate or skip a bucket")
    }

    func testDSTFallBackKeepsDailyBuckets() {
        // US DST ends 2026-11-01.
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 4
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let instant = calendar.date(from: components)!
        let newYork = TimeZone(identifier: "America/New_York")!
        let window = DateBuckets.rollingWindow(endingAt: instant, days: 7, timeZone: newYork)
        XCTAssertEqual(Set(window.buckets).count, 7)
    }

    func testPreviousNaturalWeekIsMondayToSunday() {
        let window = DateBuckets.previousNaturalWeek(before: TestDates.base, timeZone: TestDates.utc)
        XCTAssertEqual(window.buckets.first, "2026-02-23") // Monday
        XCTAssertEqual(window.buckets.last, "2026-03-01")  // Sunday
        XCTAssertEqual(window.buckets.count, 7)
    }

    func testPreviousNaturalWeekFromSundayStillPointsToLastFullWeek() {
        // 2026-03-01 is a Sunday; the last *completed* week is 2026-02-16…2026-02-22.
        let sunday = TestDates.day(-1)
        let window = DateBuckets.previousNaturalWeek(before: sunday, timeZone: TestDates.utc)
        XCTAssertEqual(window.buckets.first, "2026-02-16")
        XCTAssertEqual(window.buckets.last, "2026-02-22")
    }

    func testFullDayCheckRequiresRealElapsedTime() {
        XCTAssertFalse(DateBuckets.hasFullDaysSinceFirstCollection(nil, now: TestDates.base,
                                                                   days: 7, timeZone: TestDates.utc))
        XCTAssertFalse(DateBuckets.hasFullDaysSinceFirstCollection(
            TestDates.base.addingTimeInterval(-6.9 * 86_400), now: TestDates.base,
            days: 7, timeZone: TestDates.utc))
        XCTAssertTrue(DateBuckets.hasFullDaysSinceFirstCollection(
            TestDates.base.addingTimeInterval(-7.1 * 86_400), now: TestDates.base,
            days: 7, timeZone: TestDates.utc))
    }
}
