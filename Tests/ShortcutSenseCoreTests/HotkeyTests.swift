import Foundation
import XCTest
@testable import ShortcutSenseCore

/// AC-12 / AC-13: real registration semantics, rollback, restore and undo.
final class ShortcutActionManagerTests: XCTestCase {
    private var temp: TempStore!
    private var backend: FakeHotkeyBackend!
    private var launcher: FakeAppLauncher!
    private var manager: ShortcutActionManager!
    private var clock: TestClock!

    private let combo = KeyCombo(keyCode: 8, modifiers: [.control, .option, .shift])

    override func setUpWithError() throws {
        temp = try TempStore()
        backend = FakeHotkeyBackend()
        launcher = FakeAppLauncher()
        clock = TestClock(TestDates.base)
        manager = ShortcutActionManager(store: temp.store, backend: backend, launcher: launcher,
                                        timeZone: { TestDates.utc },
                                        now: { [unowned self] in self.clock.current })
    }

    override func tearDownWithError() throws {
        temp.tearDown(); temp = nil; backend = nil; launcher = nil; manager = nil; clock = nil
    }

    private func pendingRecommendation(id: String = "r1",
                                       bundle: String = "com.apple.finder") throws -> Recommendation {
        let rec = Recommendation(id: id, bundleID: bundle, kind: .launchFocus, targetID: "launch",
                                 proposedCombo: combo.comboID, confidence: .heuristic,
                                 status: .pending, createdAt: "2026-03-02T09:00:00Z",
                                 cooldownUntil: nil, updatedAt: "2026-03-02T09:00:00Z")
        try temp.store.upsertRecommendation(rec)
        return rec
    }

    private var clear: ConflictResult { ConflictResult(status: .noKnownConflict, evidence: []) }

    // MARK: - Apply

    func testApplyPersistsOnlyAfterRegistrationSucceeds() throws {
        let rec = try pendingRecommendation()
        let record = try manager.apply(recommendation: rec, combo: combo, conflict: clear)

        XCTAssertTrue(backend.isRegistered(shortcutID: record.id))
        let stored = try temp.store.registeredShortcuts(activeOnly: true)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.combo, combo)
        XCTAssertEqual(try temp.store.recommendation(id: "r1")?.status, .applied)
    }

    func testRegistrationFailureIsSurfacedAndNothingIsStored() throws {
        let rec = try pendingRecommendation()
        backend.nextRegisterError = -9878 // eventHotKeyExistsErr

        XCTAssertThrowsError(try manager.apply(recommendation: rec, combo: combo, conflict: clear)) { error in
            XCTAssertEqual(error as? HotkeyRegistrationError, .carbonError(-9878))
        }
        XCTAssertTrue(try temp.store.registeredShortcuts().isEmpty,
                      "a failed registration must never appear as active in the database")
        XCTAssertEqual(try temp.store.recommendation(id: "r1")?.status, .pending)
    }

    func testConflictThatIsNotClearBlocksApply() throws {
        let rec = try pendingRecommendation()
        for status in [ConflictStatus.occupied, .potentialConflict, .unknown] {
            XCTAssertThrowsError(try manager.apply(
                recommendation: rec, combo: combo,
                conflict: ConflictResult(status: status, evidence: [])))
        }
        XCTAssertEqual(backend.registerCallCount, 0, "no OS call should be attempted")
    }

    func testDuplicateComboIsRejectedBeforeTouchingCarbon() throws {
        let rec = try pendingRecommendation()
        _ = try manager.apply(recommendation: rec, combo: combo, conflict: clear)
        let callsAfterFirst = backend.registerCallCount

        let second = try pendingRecommendation(id: "r2", bundle: "com.google.Chrome")
        XCTAssertThrowsError(try manager.apply(recommendation: second, combo: combo, conflict: clear)) { error in
            XCTAssertEqual(error as? HotkeyRegistrationError, .alreadyRegistered(combo))
        }
        XCTAssertEqual(backend.registerCallCount, callsAfterFirst)
    }

    func testPersistenceFailureRollsBackTheRegistration() throws {
        let rec = try pendingRecommendation()
        temp.store.failNextRegisteredShortcutInsert = true

        XCTAssertThrowsError(try manager.apply(recommendation: rec, combo: combo, conflict: clear)) { error in
            guard case .persistenceFailed = error as? HotkeyRegistrationError else {
                return XCTFail("expected persistenceFailed, got \(error)")
            }
        }
        XCTAssertEqual(backend.unregisterCallCount, 1, "registration must be rolled back")
        XCTAssertTrue(backend.registered.isEmpty)
        XCTAssertTrue(try temp.store.registeredShortcuts().isEmpty)
    }

    // MARK: - Undo

    func testUndoReleasesTheHotkeyAndClearsTheRow() throws {
        let rec = try pendingRecommendation()
        let record = try manager.apply(recommendation: rec, combo: combo, conflict: clear)

        try manager.undo(shortcutID: record.id)

        XCTAssertFalse(backend.isRegistered(shortcutID: record.id))
        XCTAssertTrue(try temp.store.registeredShortcuts().isEmpty)
        let updated = try temp.store.recommendation(id: "r1")
        XCTAssertEqual(updated?.status, .undone)
        XCTAssertNotNil(updated?.cooldownUntil, "undo starts the dismissal cool-down")
    }

    func testUndoKeepsRowActiveWhenTheOSRefusesToRelease() throws {
        let rec = try pendingRecommendation()
        let record = try manager.apply(recommendation: rec, combo: combo, conflict: clear)
        backend.nextUnregisterError = -50

        XCTAssertThrowsError(try manager.undo(shortcutID: record.id))
        let stored = try temp.store.registeredShortcuts()
        XCTAssertEqual(stored.count, 1, "the row must stay while the OS still holds the hotkey")
        XCTAssertEqual(stored.first?.lastErrorCode, -50)
        XCTAssertEqual(try temp.store.recommendation(id: "r1")?.status, .applied)
    }

    func testUndoOfUnknownShortcutThrows() {
        XCTAssertThrowsError(try manager.undo(shortcutID: "nope")) { error in
            XCTAssertEqual(error as? HotkeyRegistrationError, .unknownShortcut("nope"))
        }
    }

    // MARK: - Restore

    func testRestoreReRegistersPersistedShortcuts() throws {
        let rec = try pendingRecommendation()
        let record = try manager.apply(recommendation: rec, combo: combo, conflict: clear)

        // Simulate a relaunch: a fresh manager with an empty backend over the same DB.
        let relaunchedBackend = FakeHotkeyBackend()
        let relaunched = ShortcutActionManager(store: temp.store, backend: relaunchedBackend,
                                               launcher: launcher, timeZone: { TestDates.utc },
                                               now: { [unowned self] in self.clock.current })
        let outcome = relaunched.restoreOnLaunch()

        XCTAssertEqual(outcome.restored, [record.id])
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertTrue(relaunchedBackend.isRegistered(shortcutID: record.id))
        XCTAssertEqual(try temp.store.registeredShortcuts(activeOnly: true).count, 1,
                       "restore must not duplicate rows")
    }

    func testRestoreMarksFailureWhenCarbonRejects() throws {
        let rec = try pendingRecommendation()
        let record = try manager.apply(recommendation: rec, combo: combo, conflict: clear)

        let relaunchedBackend = FakeHotkeyBackend()
        relaunchedBackend.nextRegisterError = -9878
        let relaunched = ShortcutActionManager(store: temp.store, backend: relaunchedBackend,
                                               launcher: launcher, timeZone: { TestDates.utc },
                                               now: { [unowned self] in self.clock.current })
        let outcome = relaunched.restoreOnLaunch()

        XCTAssertTrue(outcome.restored.isEmpty)
        XCTAssertEqual(outcome.failed.first?.id, record.id)
        let stored = try temp.store.registeredShortcuts()
        XCTAssertEqual(stored.first?.isActive, false)
        XCTAssertEqual(stored.first?.lastErrorCode, -9878, "the OSStatus must be visible")
    }

    func testRestoreFailsVisiblyWhenTargetAppIsGone() throws {
        let rec = try pendingRecommendation()
        let record = try manager.apply(recommendation: rec, combo: combo, conflict: clear)

        launcher.installed.remove("com.apple.finder")
        let relaunchedBackend = FakeHotkeyBackend()
        let relaunched = ShortcutActionManager(store: temp.store, backend: relaunchedBackend,
                                               launcher: launcher, timeZone: { TestDates.utc },
                                               now: { [unowned self] in self.clock.current })
        let outcome = relaunched.restoreOnLaunch()

        XCTAssertEqual(outcome.failed.first?.id, record.id)
        XCTAssertEqual(relaunchedBackend.registerCallCount, 0)
        XCTAssertEqual(try temp.store.registeredShortcuts().first?.isActive, false)
    }

    func testRepeatedRestoreIsIdempotent() throws {
        let rec = try pendingRecommendation()
        _ = try manager.apply(recommendation: rec, combo: combo, conflict: clear)
        let relaunchedBackend = FakeHotkeyBackend()
        let relaunched = ShortcutActionManager(store: temp.store, backend: relaunchedBackend,
                                               launcher: launcher, timeZone: { TestDates.utc },
                                               now: { [unowned self] in self.clock.current })
        _ = relaunched.restoreOnLaunch()
        let second = relaunched.restoreOnLaunch()
        XCTAssertEqual(second.failed.count, 0)
        XCTAssertEqual(try temp.store.registeredShortcuts().count, 1)
    }

    // MARK: - Trigger counts

    func testEachPressCountsExactlyOnce() throws {
        let rec = try pendingRecommendation()
        let record = try manager.apply(recommendation: rec, combo: combo, conflict: clear)
        for _ in 0..<5 { backend.press(shortcutID: record.id) }
        let usage = try temp.store.shortcutUsage(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertEqual(usage.first?.triggerCount, 5)
    }

    func testTriggerInvokesTargetActivation() throws {
        let rec = try pendingRecommendation(bundle: "com.google.Chrome")
        let record = try manager.apply(recommendation: rec, combo: combo, conflict: clear)
        backend.press(shortcutID: record.id)
        XCTAssertEqual(launcher.activateCalls, ["com.google.Chrome"])
    }
}

/// AC-12: key classification rules used to decide what may become a shortcut.
final class KeyComboTests: XCTestCase {
    func testCommandAndControlCombosAreShortcuts() {
        for modifiers in [ComboModifiers.command, .control, [.command, .shift], [.control, .option]] {
            guard case .commandShortcut = KeyCombo.classify(keyCode: 8, modifiers: modifiers) else {
                XCTFail("\(modifiers) should classify as a command shortcut")
                continue
            }
        }
    }

    func testOptionOnlyIsTextInput() {
        XCTAssertEqual(KeyCombo.classify(keyCode: 14, modifiers: .option), .textInput)
        XCTAssertEqual(KeyCombo.classify(keyCode: 14, modifiers: [.option, .shift]), .textInput)
    }

    func testPlainLettersAreTextInput() {
        for letter in ["a", "i", " "] {
            let code = letter == " " ? 49 : KeyCodeNames.keyCode(forLetter: Character(letter))!
            XCTAssertEqual(KeyCombo.classify(keyCode: code, modifiers: []), .textInput)
        }
    }

    func testModifierKeysAreNeverShortcuts() {
        for code in KeyCombo.modifierKeyCodes {
            XCTAssertEqual(KeyCombo.classify(keyCode: code, modifiers: .command), .modifierOnly)
        }
    }

    func testComboIDIsStableAndOrderIndependent() {
        let a = KeyCombo(keyCode: 8, modifiers: [.control, .option, .shift])
        let b = KeyCombo(keyCode: 8, modifiers: [.shift, .option, .control])
        XCTAssertEqual(a.comboID, b.comboID)
        XCTAssertEqual(KeyComboCodec.decode(a.comboID), a)
    }

    func testDisplayStringIsHumanReadable() {
        let combo = KeyCombo(keyCode: KeyCodeNames.keyCode(forLetter: "c")!,
                             modifiers: [.control, .option, .shift])
        XCTAssertEqual(combo.displayString, "Control+Option+Shift+C")
    }
}

/// The apply path must be atomic: a failed save may not leave an active row behind,
/// because `restoreOnLaunch` would later bring that phantom shortcut to life.
final class ApplyAtomicityTests: XCTestCase {
    private var temp: TempStore!
    private var backend: FakeHotkeyBackend!
    private var manager: ShortcutActionManager!

    override func setUpWithError() throws {
        temp = try TempStore()
        backend = FakeHotkeyBackend()
        manager = ShortcutActionManager(store: temp.store, backend: backend,
                                        launcher: FakeAppLauncher(),
                                        timeZone: { TestDates.utc },
                                        now: { TestDates.base })
    }

    override func tearDownWithError() throws {
        temp.tearDown(); temp = nil; backend = nil; manager = nil
    }

    func testFailedSaveLeavesNeitherRowNorAppliedStatus() throws {
        let combo = KeyCombo(keyCode: 8, modifiers: [.control, .option, .shift])
        let rec = Recommendation(id: "r1", bundleID: "com.apple.finder", kind: .launchFocus,
                                 targetID: "launch", proposedCombo: combo.comboID,
                                 confidence: .heuristic, status: .pending,
                                 createdAt: "2026-03-02T09:00:00Z", cooldownUntil: nil,
                                 updatedAt: "2026-03-02T09:00:00Z")
        try temp.store.upsertRecommendation(rec)
        temp.store.failNextRegisteredShortcutInsert = true

        XCTAssertThrowsError(try manager.apply(
            recommendation: rec, combo: combo,
            conflict: ConflictResult(status: .noKnownConflict, evidence: [])))

        XCTAssertTrue(try temp.store.registeredShortcuts().isEmpty,
                      "no phantom active row may survive a failed save")
        XCTAssertEqual(try temp.store.recommendation(id: "r1")?.status, .pending,
                       "the recommendation must not be marked applied")
        XCTAssertTrue(backend.registered.isEmpty)

        // Relaunch must find nothing to restore.
        let relaunched = ShortcutActionManager(store: temp.store, backend: FakeHotkeyBackend(),
                                               launcher: FakeAppLauncher(),
                                               timeZone: { TestDates.utc }, now: { TestDates.base })
        XCTAssertTrue(relaunched.restoreOnLaunch().restored.isEmpty)
    }

    func testDeletingDataReleasesEveryLiveHotkey() throws {
        let combo = KeyCombo(keyCode: 8, modifiers: [.control, .option, .shift])
        let rec = Recommendation(id: "r1", bundleID: "com.apple.finder", kind: .launchFocus,
                                 targetID: "launch", proposedCombo: combo.comboID,
                                 confidence: .heuristic, status: .pending,
                                 createdAt: "2026-03-02T09:00:00Z", cooldownUntil: nil,
                                 updatedAt: "2026-03-02T09:00:00Z")
        try temp.store.upsertRecommendation(rec)
        let record = try manager.apply(recommendation: rec, combo: combo,
                                       conflict: ConflictResult(status: .noKnownConflict, evidence: []))
        XCTAssertTrue(backend.isRegistered(shortcutID: record.id))

        // What AppController.deleteAllData() does, in order.
        manager.releaseAllRegistrations()
        try temp.store.deleteAllData()

        XCTAssertFalse(backend.isRegistered(shortcutID: record.id),
                       "an OS grab must not outlive deleted data")
        XCTAssertTrue(try temp.store.registeredShortcuts().isEmpty)
    }

    func testFailingUnregisterKeepsTheRecordForRetry() {
        // A backend that refuses to release must leave `isRegistered` true, so undo
        // can be retried instead of silently orphaning the OS grab.
        let combo = KeyCombo(keyCode: 9, modifiers: [.control, .option])
        _ = backend.register(combo, shortcutID: "s1", handler: {})
        backend.nextUnregisterError = -50
        if case .failure(let error) = backend.unregister(shortcutID: "s1") {
            XCTAssertEqual(error, .carbonError(-50))
        } else {
            XCTFail("a failing UnregisterEventHotKey must be reported")
        }
        XCTAssertTrue(backend.isRegistered(shortcutID: "s1"),
                      "the registration must remain known while the OS still holds it")
        // Retry succeeds and only then is the record dropped.
        if case .failure(let error) = backend.unregister(shortcutID: "s1") {
            XCTFail("retry should succeed, got \(error)")
        }
        XCTAssertFalse(backend.isRegistered(shortcutID: "s1"))
    }

    func testManualMarkRespectsTheGate() throws {
        let pipeline = CapturePipeline(
            store: temp.store,
            context: CaptureContext(hasInputMonitoringPermission: true,
                                    isPaused: true,
                                    foregroundBundleID: "com.apple.finder"),
            now: { TestDates.base }, timeZone: { TestDates.utc })
        pipeline.handleManualMark(bundleID: "com.apple.finder", commandID: "x",
                                  safeLabel: "New Window", knownShortcut: nil)
        XCTAssertTrue(try temp.store.menuActionStats(from: TestDates.bucket(0),
                                                     to: TestDates.bucket(0)).isEmpty)

        pipeline.updateContext { $0.isPaused = false }
        // `com.apple.finder` is on the menu allow-list, so the same mark now records.
        pipeline.handleManualMark(bundleID: "com.apple.finder", commandID: "x",
                                  safeLabel: "New Window", knownShortcut: nil)
        XCTAssertEqual(try temp.store.menuActionStats(from: TestDates.bucket(0),
                                                      to: TestDates.bucket(0)).count, 1)

        // A non-allow-listed app is refused even while unpaused.
        pipeline.handleManualMark(bundleID: "com.example.other", commandID: "y",
                                  safeLabel: "Do Thing", knownShortcut: nil)
        XCTAssertEqual(try temp.store.menuActionStats(from: TestDates.bucket(0),
                                                      to: TestDates.bucket(0)).count, 1)
    }
}
