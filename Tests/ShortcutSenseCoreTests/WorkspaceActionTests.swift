import Foundation
import XCTest
@testable import ShortcutSenseCore

/// G-C: a workspace hotkey launches two or three installed apps, and nothing else.
/// The whitelist is enforced in the manager, not in the UI.
final class WorkspaceActionTests: XCTestCase {
    private var temp: TempStore!
    private var backend: FakeHotkeyBackend!
    private var launcher: FakeAppLauncher!
    private var manager: ShortcutActionManager!
    private let combo = KeyCombo(keyCode: 8, modifiers: [.control, .option, .shift])

    override func setUpWithError() throws {
        temp = try TempStore()
        backend = FakeHotkeyBackend()
        launcher = FakeAppLauncher(installed: ["com.apple.Safari", "com.apple.finder",
                                               "com.google.Chrome"],
                                   running: [])
        manager = ShortcutActionManager(store: temp.store, backend: backend, launcher: launcher,
                                        timeZone: { TestDates.utc },
                                        now: { TestDates.base })
    }

    override func tearDownWithError() throws {
        temp.tearDown(); temp = nil; backend = nil; launcher = nil; manager = nil
    }

    private var clear: ConflictResult { ConflictResult(status: .noKnownConflict, evidence: []) }

    func testWorkspaceLaunchesEveryMemberInOrder() throws {
        let record = try manager.applyWorkspace(
            bundleIDs: ["com.apple.Safari", "com.google.Chrome"],
            displayName: "Writing", combo: combo, conflict: clear, recommendation: nil)
        backend.press(shortcutID: record.id)
        XCTAssertEqual(launcher.activateCalls, ["com.apple.Safari", "com.google.Chrome"])
        XCTAssertEqual(record.actionKind, .launchWorkspace)
        XCTAssertEqual(record.targetBundleIDs, ["com.apple.Safari", "com.google.Chrome"])
    }

    func testSingleBundleIsRejected() {
        XCTAssertThrowsError(try manager.applyWorkspace(
            bundleIDs: ["com.apple.Safari"], displayName: "x",
            combo: combo, conflict: clear, recommendation: nil)) { error in
            XCTAssertEqual(error as? WorkspaceError, .invalidSize(1))
        }
        XCTAssertEqual(backend.registerCallCount, 0, "nothing may be registered")
    }

    func testMoreThanThreeIsRejected() {
        XCTAssertThrowsError(try manager.applyWorkspace(
            bundleIDs: ["com.apple.Safari", "com.apple.finder", "com.google.Chrome", "com.apple.mail"],
            displayName: "x", combo: combo, conflict: clear, recommendation: nil)) { error in
            XCTAssertEqual(error as? WorkspaceError, .invalidSize(4))
        }
    }

    func testUninstalledMemberIsRejectedBeforeRegistering() {
        XCTAssertThrowsError(try manager.applyWorkspace(
            bundleIDs: ["com.apple.Safari", "com.example.missing"],
            displayName: "x", combo: combo, conflict: clear, recommendation: nil)) { error in
            XCTAssertEqual(error as? WorkspaceError, .notInstalled("com.example.missing"))
        }
        XCTAssertEqual(backend.registerCallCount, 0)
    }

    func testConflictThatIsNotClearBlocksWorkspace() {
        for status in [ConflictStatus.occupied, .potentialConflict, .unknown] {
            XCTAssertThrowsError(try manager.applyWorkspace(
                bundleIDs: ["com.apple.Safari", "com.google.Chrome"],
                displayName: "x", combo: combo,
                conflict: ConflictResult(status: status, evidence: []),
                recommendation: nil))
        }
        XCTAssertEqual(backend.registerCallCount, 0)
    }

    func testUndoReleasesAWorkspaceHotkey() throws {
        let record = try manager.applyWorkspace(
            bundleIDs: ["com.apple.Safari", "com.google.Chrome"],
            displayName: "Writing", combo: combo, conflict: clear, recommendation: nil)
        XCTAssertTrue(backend.isRegistered(shortcutID: record.id))
        try manager.undo(shortcutID: record.id)
        XCTAssertFalse(backend.isRegistered(shortcutID: record.id))
        XCTAssertTrue(try temp.store.registeredShortcuts().isEmpty)
        XCTAssertTrue(launcher.activateCalls.isEmpty)
    }

    func testWorkspaceSurvivesRestore() throws {
        let record = try manager.applyWorkspace(
            bundleIDs: ["com.apple.Safari", "com.google.Chrome"],
            displayName: "Writing", combo: combo, conflict: clear, recommendation: nil)
        let relaunchedBackend = FakeHotkeyBackend()
        let relaunched = ShortcutActionManager(store: temp.store, backend: relaunchedBackend,
                                               launcher: launcher, timeZone: { TestDates.utc },
                                               now: { TestDates.base })
        let outcome = relaunched.restoreOnLaunch()
        XCTAssertEqual(outcome.restored, [record.id])
        relaunchedBackend.press(shortcutID: record.id)
        XCTAssertEqual(launcher.activateCalls, ["com.apple.Safari", "com.google.Chrome"])
    }

    func testTriggerCountsOncePerPressForAWorkspace() throws {
        let record = try manager.applyWorkspace(
            bundleIDs: ["com.apple.Safari", "com.google.Chrome"],
            displayName: "Writing", combo: combo, conflict: clear, recommendation: nil)
        for _ in 0..<3 { backend.press(shortcutID: record.id) }
        let usage = try temp.store.shortcutUsage(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertEqual(usage.first?.triggerCount, 3, "one press is one trigger, not one per app")
    }

    func testMigrationToV3KeepsExistingRows() throws {
        // A v2 row written before the columns existed must read back as a launch app.
        let legacy = RegisteredShortcut(
            id: "old", recommendationID: nil, targetBundleID: "com.apple.finder",
            keyCode: 8, carbonModifiers: 0x1900, displayCombo: "X", isActive: true,
            createdAt: "2026-03-02T09:00:00Z", lastErrorCode: nil,
            actionKind: .launchApp, actionPayload: "com.apple.finder")
        try temp.store.insertRegisteredShortcut(legacy)
        temp.store.close()
        let reopened = try Store(path: temp.databasePath)
        defer { reopened.close() }
        let rows = try reopened.registeredShortcuts()
        XCTAssertEqual(rows.first?.actionKind, .launchApp)
        XCTAssertEqual(rows.first?.targetBundleIDs, ["com.apple.finder"])
    }

    func testSchemaVersionIsThree() throws {
        XCTAssertEqual(try temp.store.debugPragmaInt("user_version"), 3)
    }
}
