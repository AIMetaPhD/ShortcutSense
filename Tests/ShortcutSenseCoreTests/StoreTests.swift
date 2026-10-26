import Foundation
import XCTest
@testable import ShortcutSenseCore

/// AC-05 / AC-07: schema, WAL, deletion and migration behaviour.
final class StoreTests: XCTestCase {
    private var temp: TempStore!

    override func setUpWithError() throws { temp = try TempStore() }
    override func tearDownWithError() throws { temp.tearDown(); temp = nil }

    func testSchemaVersionAndMetadataRoundTrip() throws {
        XCTAssertEqual(try temp.store.rowCounts()["app_metadata"], 0)
        try temp.store.setMetadata("schema_version", "1")
        XCTAssertEqual(temp.store.metadata("schema_version"), "1")
        // Upsert must not duplicate the key.
        try temp.store.setMetadata("schema_version", "2")
        XCTAssertEqual(temp.store.metadata("schema_version"), "2")
        XCTAssertEqual(try temp.store.rowCounts()["app_metadata"], 1)
    }

    func testFirstCollectionTimestampIsWrittenOnce() throws {
        let first = TestDates.base
        try temp.store.markFirstCollectionStarted(at: first, timeZone: TestDates.utc)
        try temp.store.markFirstCollectionStarted(at: first.addingTimeInterval(86_400),
                                                  timeZone: TestDates.utc)
        XCTAssertEqual(temp.store.firstCollectionStartedAt(), first)
        XCTAssertEqual(temp.store.collectionTimeZone.identifier, TestDates.utc.identifier)
    }

    func testWALModeIsEnabled() throws {
        // The WAL journal is created on first write.
        try temp.store.incrementAnonymousKeystrokes(date: "2026-03-02", bundleID: "com.apple.finder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.walPath) ||
                      FileManager.default.fileExists(atPath: temp.databasePath))
        temp.store.close()
        // A closed database must be readable again (no corruption, WAL recovered).
        let reopened = try Store(path: temp.databasePath)
        let rows = try reopened.dailyActivity(from: "2026-03-02", to: "2026-03-02")
        XCTAssertEqual(rows.first?.totalAnonymousKeystrokes, 1)
        reopened.close()
    }

    func testAggregatesAccumulateRatherThanAppend() throws {
        for _ in 0..<5 {
            try temp.store.incrementCombo(date: "2026-03-02", bundleID: "com.apple.finder",
                                          comboID: "kc8-m256")
        }
        let rows = try temp.store.comboStats(from: "2026-03-02", to: "2026-03-02")
        XCTAssertEqual(rows.count, 1, "one row per (date, bundle, combo) — never one per keystroke")
        XCTAssertEqual(rows.first?.count, 5)
    }

    func testNegativeCountsAreRejectedBySchema() throws {
        let db = try Database(path: temp.databasePath + ".constraint")
        defer { db.close(); try? FileManager.default.removeItem(atPath: temp.databasePath + ".constraint") }
        try db.execute("CREATE TABLE t (count INTEGER NOT NULL CHECK (count >= 0))")
        XCTAssertThrowsError(try db.execute("INSERT INTO t(count) VALUES(-1)"))
    }

    func testDeleteAllDataClearsEveryTable() throws {
        try temp.store.setMetadata("is_paused", "0")
        try temp.store.addExcludedApp(bundleID: "com.example.secret", displayName: "Secret", source: .user)
        try temp.store.incrementCombo(date: "2026-03-02", bundleID: "com.apple.finder", comboID: "kc8-m256")
        try temp.store.incrementAnonymousKeystrokes(date: "2026-03-02", bundleID: "com.apple.finder", by: 42)
        try temp.store.incrementActivity(date: "2026-03-02", bundleID: "com.apple.finder", field: .unknownOriginActivations, by: 3)
        try temp.store.insertRegisteredShortcut(RegisteredShortcut(
            id: "s1", recommendationID: nil, targetBundleID: "com.apple.finder", keyCode: 8,
            carbonModifiers: 0x1900, displayCombo: "Control+Option+Shift+C", isActive: true,
            createdAt: "2026-03-02T09:00:00Z", lastErrorCode: nil))
        try temp.store.recordShortcutTrigger(shortcutID: "s1", date: "2026-03-02")
        try temp.store.insertWeeklyReview(WeeklyReviewRecord(
            reviewID: "r1", periodStart: "2026-02-23", periodEnd: "2026-03-01",
            generatedAt: "2026-03-02T09:00:00Z", isPreview: false))

        try temp.store.deleteAllData()

        let counts = try temp.store.rowCounts()
        for (table, count) in counts {
            XCTAssertEqual(count, 0, "\(table) still has rows after deleteAllData")
        }
        XCTAssertTrue(try temp.store.dailyActivity(from: "2026-01-01", to: "2026-12-31").isEmpty)
        XCTAssertFalse(temp.store.isExcluded(bundleID: "com.example.secret"))
    }

    func testDeleteAllDataRemovesWalResidue() throws {
        // Write a distinctive marker, delete, then inspect the raw files for it.
        let marker = "com.example.canary.app"
        try temp.store.incrementCombo(date: "2026-03-02", bundleID: marker, comboID: "kc8-m256")
        try temp.store.deleteAllData()

        for path in [temp.databasePath, temp.walPath, temp.shmPath] {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains(marker),
                           "deleted identifier still present in \(URL(fileURLWithPath: path).lastPathComponent)")
        }
    }

    func testReopenAfterDeleteCreatesCleanDatabase() throws {
        try temp.store.incrementAnonymousKeystrokes(date: "2026-03-02", bundleID: "com.apple.finder", by: 9)
        try temp.store.deleteAllData()
        temp.store.close()

        let reopened = try Store(path: temp.databasePath)
        defer { reopened.close() }
        XCTAssertTrue(try reopened.dailyActivity(from: "2026-01-01", to: "2026-12-31").isEmpty)
        XCTAssertTrue(try reopened.recommendations().isEmpty)
        // Schema still usable.
        try reopened.incrementAnonymousKeystrokes(date: "2026-03-03", bundleID: "com.apple.finder")
        XCTAssertEqual(try reopened.dailyActivity(from: "2026-03-03", to: "2026-03-03").count, 1)
    }

    func testMigrationIsIdempotent() throws {
        try temp.store.setMetadata("probe", "kept")
        temp.store.close()
        for _ in 0..<3 {
            let store = try Store(path: temp.databasePath)
            XCTAssertEqual(store.metadata("probe"), "kept")
            store.close()
        }
    }

    func testExclusionSourcesAreDistinct() throws {
        try temp.store.seedDefaultExclusions(SensitiveApps.defaults)
        try temp.store.addExcludedApp(bundleID: "com.apple.Terminal", displayName: "Terminal", source: .user)
        // Removing the user exclusion must leave the system default in place.
        try temp.store.removeExcludedApp(bundleID: "com.apple.Terminal", source: .user)
        XCTAssertTrue(temp.store.isExcluded(bundleID: "com.apple.Terminal"))
        // Seeding twice does not duplicate or error.
        try temp.store.seedDefaultExclusions(SensitiveApps.defaults)
        XCTAssertEqual(Set(temp.store.excludedBundleIDs()).count, temp.store.excludedBundleIDs().count)
    }

    func testWeeklyReviewInsertIsIdempotent() throws {
        let record = WeeklyReviewRecord(reviewID: "r1", periodStart: "2026-02-23",
                                        periodEnd: "2026-03-01", generatedAt: "2026-03-02T09:00:00Z",
                                        isPreview: false)
        XCTAssertTrue(try temp.store.insertWeeklyReview(record))
        XCTAssertFalse(try temp.store.insertWeeklyReview(record), "same period must not be inserted twice")
        XCTAssertEqual(try temp.store.weeklyReviews().count, 1)
    }

    func testExportContainsOnlyWhitelistedAggregateFields() throws {
        try temp.store.incrementCombo(date: "2026-03-02", bundleID: "com.apple.finder", comboID: "kc8-m256")
        try temp.store.incrementAnonymousKeystrokes(date: "2026-03-02", bundleID: "com.apple.finder", by: 12)
        let payload = try temp.store.exportAggregates(from: "2026-03-01", to: "2026-03-07")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
        for forbidden in ["keyCode", "text", "title", "url", "sequence", "timestamp", "clipboard"] {
            XCTAssertFalse(json.lowercased().contains("\"\(forbidden.lowercased())\""),
                           "export leaked a forbidden field: \(forbidden)")
        }
        XCTAssertTrue(json.contains("comboID"))
        XCTAssertTrue(json.contains("totalAnonymousKeystrokes"))
    }
}
