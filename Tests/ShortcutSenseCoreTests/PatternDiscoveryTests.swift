import Foundation
import XCTest
@testable import ShortcutSenseCore

private func t1(_ day: Int, hour: Int = 9, seq: Int, kind: T1EventKind,
                bundle: String, command: String? = nil,
                label: String? = nil, shortcut: String? = nil) -> T1Event {
    T1Event(date: TestDates.bucket(day), hour: hour, sequence: seq, kind: kind,
            bundleID: bundle, commandID: command, safeLabel: label, knownShortcut: shortcut)
}

/// G-C: Learn candidates must come from verified clicks at the 7/2 threshold, and a
/// manual mark must never be inflated into a click count.
final class MenuCommandPatternTests: XCTestCase {
    private func clicks(_ count: Int, day: Int, startSeq: Int = 1) -> [T1Event] {
        (0..<count).map { index in
            t1(day, seq: startSeq + index, kind: .verifiedMenuCommand,
               bundle: "com.apple.finder", command: "file|new window",
               label: "New Finder Window", shortcut: "kc45-m256")
        }
    }

    func testSevenClicksOnTwoDaysQualifies() {
        let patterns = PatternDiscovery.menuCommandPatterns(
            events: clicks(4, day: 0) + clicks(3, day: 1, startSeq: 5))
        XCTAssertEqual(patterns.count, 1)
        XCTAssertEqual(patterns.first?.observedCount, 7)
        XCTAssertEqual(patterns.first?.activeDays, 2)
        XCTAssertEqual(patterns.first?.provenance, .verifiedAXClick)
    }

    func testSixClicksDoNotQualify() {
        XCTAssertTrue(PatternDiscovery.menuCommandPatterns(
            events: clicks(3, day: 0) + clicks(3, day: 1, startSeq: 4)).isEmpty)
    }

    func testSevenClicksOnOneDayDoNotQualify() {
        XCTAssertTrue(PatternDiscovery.menuCommandPatterns(events: clicks(7, day: 0)).isEmpty,
                      "activeDays < 2 must not produce a Learn card")
    }

    func testManualMarkCarriesNoClickCount() {
        let marks = [t1(0, seq: 1, kind: .manualMark, bundle: "com.apple.finder",
                        command: "file|new window", label: "New Finder Window",
                        shortcut: "kc45-m256")]
        let patterns = PatternDiscovery.menuCommandPatterns(events: marks)
        XCTAssertEqual(patterns.count, 1)
        XCTAssertNil(patterns.first?.observedCount, "one mark must never read as seven clicks")
        XCTAssertEqual(patterns.first?.provenance, .explicitManualMark)
    }

    func testVerifiedAndManualAreKeptApart() {
        let events = clicks(7, day: 0) + clicks(7, day: 1, startSeq: 8)
            + [t1(2, seq: 1, kind: .manualMark, bundle: "com.apple.finder",
                  command: "file|new window", label: "New Finder Window")]
        let patterns = PatternDiscovery.menuCommandPatterns(events: events)
        XCTAssertEqual(patterns.count, 2, "verified and manual evidence are separate rows")
        XCTAssertEqual(patterns.filter { $0.provenance == .verifiedAXClick }.first?.observedCount, 14)
        XCTAssertNil(patterns.filter { $0.provenance == .explicitManualMark }.first?.observedCount)
    }

    func testDifferentCommandsAreSeparate() {
        var events = clicks(7, day: 0) + clicks(7, day: 1, startSeq: 8)
        events += (0..<7).map { index in
            t1(0, seq: 20 + index, kind: .verifiedMenuCommand,
               bundle: "com.apple.finder", command: "edit|copy", label: "Copy")
        }
        XCTAssertEqual(PatternDiscovery.menuCommandPatterns(events: events).count, 1,
                       "edit|copy appears on one day only")
    }
}

/// G-C: a workspace suggestion needs the same group on at least two different days.
final class WorkspacePatternTests: XCTestCase {
    func testGroupOnTwoDaysQualifies() {
        var events: [T1Event] = []
        for day in [0, 1] {
            events.append(t1(day, hour: 9, seq: 1, kind: .appActivation, bundle: "com.apple.Safari"))
            events.append(t1(day, hour: 9, seq: 2, kind: .appActivation, bundle: "com.google.Chrome"))
        }
        let patterns = PatternDiscovery.workspacePatterns(events: events)
        XCTAssertEqual(patterns.count, 1)
        XCTAssertEqual(patterns.first?.bundleIDs, ["com.apple.Safari", "com.google.Chrome"])
        XCTAssertEqual(patterns.first?.activeDays, 2)
    }

    func testGroupOnOneDayOnlyDoesNotQualify() {
        let events = [
            t1(0, seq: 1, kind: .appActivation, bundle: "com.apple.Safari"),
            t1(0, seq: 2, kind: .appActivation, bundle: "com.google.Chrome"),
        ]
        XCTAssertTrue(PatternDiscovery.workspacePatterns(events: events).isEmpty)
    }

    func testSingleAppIsNotAWorkspace() {
        var events: [T1Event] = []
        for day in [0, 1, 2] {
            events.append(t1(day, seq: 1, kind: .appActivation, bundle: "com.apple.Safari"))
            events.append(t1(day, seq: 2, kind: .appActivation, bundle: "com.apple.Safari"))
        }
        XCTAssertTrue(PatternDiscovery.workspacePatterns(events: events).isEmpty)
    }

    func testGroupIsCappedAtThreeApps() {
        var events: [T1Event] = []
        let apps = ["a.one", "b.two", "c.three", "d.four", "e.five"]
        for day in [0, 1] {
            for (index, app) in apps.enumerated() {
                events.append(t1(day, seq: index + 1, kind: .appActivation, bundle: app))
            }
        }
        let patterns = PatternDiscovery.workspacePatterns(events: events)
        XCTAssertEqual(patterns.first?.bundleIDs.count, 3,
                       "a hotkey must not launch more than three apps")
    }

    func testDifferentHoursAreDifferentSessions() {
        let events = [
            t1(0, hour: 9, seq: 1, kind: .appActivation, bundle: "com.apple.Safari"),
            t1(0, hour: 14, seq: 1, kind: .appActivation, bundle: "com.apple.Safari"),
            t1(0, hour: 9, seq: 2, kind: .appActivation, bundle: "com.google.Chrome"),
            t1(1, hour: 9, seq: 1, kind: .appActivation, bundle: "com.apple.Safari"),
            t1(1, hour: 9, seq: 2, kind: .appActivation, bundle: "com.google.Chrome"),
        ]
        let patterns = PatternDiscovery.workspacePatterns(events: events)
        XCTAssertEqual(patterns.count, 1)
        XCTAssertEqual(patterns.first?.activeDays, 2)
    }

    func testMenuEventsDoNotCreateWorkspaces() {
        var events: [T1Event] = []
        for day in [0, 1] {
            events.append(t1(day, seq: 1, kind: .verifiedMenuCommand,
                             bundle: "com.apple.finder", command: "a"))
            events.append(t1(day, seq: 2, kind: .verifiedMenuCommand,
                             bundle: "com.google.Chrome", command: "b"))
        }
        XCTAssertTrue(PatternDiscovery.workspacePatterns(events: events).isEmpty)
    }
}

/// T1 storage: opt-in, prunable, and cleared with the rest of the data.
final class T1StorageTests: XCTestCase {
    private var temp: TempStore!

    override func setUpWithError() throws { temp = try TempStore() }
    override func tearDownWithError() throws { temp = nil }

    func testT1IsOffByDefault() {
        XCTAssertFalse(temp.store.t1CollectionEnabled,
                       "menu observation must require an explicit opt-in")
    }

    func testEnablingAndDisabling() throws {
        try temp.store.setT1CollectionEnabled(true)
        XCTAssertTrue(temp.store.t1CollectionEnabled)
        try temp.store.setT1CollectionEnabled(false)
        XCTAssertFalse(temp.store.t1CollectionEnabled)
    }

    func testEventsRoundTripInSequenceOrder() throws {
        try temp.store.recordT1Event(date: "2026-03-02", timeZoneIdentifier: "UTC", hour: 9,
                                     sequence: 2, kind: .verifiedMenuCommand,
                                     bundleID: "com.apple.finder", commandID: "c",
                                     safeLabel: "Copy", knownShortcut: "kc8-m256")
        try temp.store.recordT1Event(date: "2026-03-02", timeZoneIdentifier: "UTC", hour: 9,
                                     sequence: 1, kind: .appActivation, bundleID: "com.apple.finder")
        let rows = try temp.store.t1Events(from: "2026-03-02", to: "2026-03-02")
        XCTAssertEqual(rows.map(\.sequence), [1, 2])
        XCTAssertEqual(rows.last?.safeLabel, "Copy")
    }

    func testPruningKeepsRecentRows() throws {
        try temp.store.recordT1Event(date: "2026-01-01", timeZoneIdentifier: "UTC", hour: 9,
                                     sequence: 1, kind: .appActivation, bundleID: "a.old")
        try temp.store.recordT1Event(date: TestDates.bucket(0), timeZoneIdentifier: "UTC", hour: 9,
                                     sequence: 1, kind: .appActivation, bundleID: "a.new")
        try temp.store.pruneT1(olderThan: 14, now: TestDates.base, timeZone: TestDates.utc)
        XCTAssertEqual(try temp.store.t1Events(from: "2026-01-01", to: "2026-01-01").count, 0)
        XCTAssertEqual(try temp.store.t1Events(from: TestDates.bucket(0), to: TestDates.bucket(0)).count, 1)
    }

    func testClearT1AlsoRemovesVerifiedMenuCounts() throws {
        try temp.store.incrementMenuAction(date: "2026-03-02", bundleID: "com.apple.finder",
                                           commandID: "c", safeLabel: "Copy",
                                           knownShortcut: nil, provenance: .verifiedAXClick)
        try temp.store.incrementMenuAction(date: "2026-03-02", bundleID: "com.apple.finder",
                                           commandID: "d", safeLabel: "Paste",
                                           knownShortcut: nil, provenance: .explicitManualMark)
        try temp.store.clearT1()
        let rows = try temp.store.menuActionStats(from: "2026-03-02", to: "2026-03-02")
        XCTAssertEqual(rows.count, 1, "a manual mark is the user's own decision and survives")
        XCTAssertEqual(rows.first?.provenance, .explicitManualMark)
    }

    func testDeleteAllDataClearsT1() throws {
        try temp.store.recordT1Event(date: TestDates.bucket(0), timeZoneIdentifier: "UTC",
                                     hour: 9, sequence: 1, kind: .appActivation, bundleID: "a")
        try temp.store.deleteAllData()
        XCTAssertEqual(try temp.store.rowCounts()["t1_sessions"], 0)
    }

    func testSchemaVersionIsCurrent() throws {
        XCTAssertEqual(try temp.store.debugPragmaInt("user_version"), Int64(SchemaVersion.current))
    }
}
