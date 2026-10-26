import Foundation
import XCTest
@testable import ShortcutSenseCore

/// AC-10 / AC-22: activation attribution is bounded, heuristic and never double-counted.
final class AttributionBufferTests: XCTestCase {
    func testNavigationWithinWindowClassifiesAsKeyboardNavigation() {
        var buffer = AttributionBuffer()
        buffer.noteNavigation(comboID: "kc48-m256", at: 100.0)
        XCTAssertEqual(buffer.classifyActivation(bundleID: "com.apple.finder", at: 100.4),
                       .observedKeyboardNavigation(comboID: "kc48-m256"))
    }

    func testNavigationOutsideWindowBecomesUnknownOrigin() {
        var buffer = AttributionBuffer()
        buffer.noteNavigation(comboID: "kc48-m256", at: 100.0)
        XCTAssertEqual(buffer.classifyActivation(bundleID: "com.apple.finder", at: 102.0), .unknownOrigin)
    }

    func testManagedHotkeyMatchesTarget() {
        var buffer = AttributionBuffer()
        let token = buffer.noteManagedHotkey(targetBundleID: "com.google.Chrome", shortcutID: "s1", at: 10.0)
        XCTAssertEqual(buffer.classifyActivation(bundleID: "com.google.Chrome", at: 10.8),
                       .managedHotkey(shortcutID: "s1", token: token))
    }

    func testManagedHotkeyForDifferentTargetIsUnknown() {
        var buffer = AttributionBuffer()
        _ = buffer.noteManagedHotkey(targetBundleID: "com.google.Chrome", shortcutID: "s1", at: 10.0)
        XCTAssertEqual(buffer.classifyActivation(bundleID: "com.apple.finder", at: 10.2), .unknownOrigin)
    }

    func testTokenIsConsumedOnlyOnce() {
        var buffer = AttributionBuffer()
        _ = buffer.noteManagedHotkey(targetBundleID: "com.google.Chrome", shortcutID: "s1", at: 10.0)
        _ = buffer.classifyActivation(bundleID: "com.google.Chrome", at: 10.1)
        XCTAssertEqual(buffer.classifyActivation(bundleID: "com.google.Chrome", at: 10.2), .unknownOrigin)
    }

    func testManagedHotkeyTakesPrecedenceOverNavigation() {
        var buffer = AttributionBuffer()
        buffer.noteNavigation(comboID: "kc48-m256", at: 5.0)
        let token = buffer.noteManagedHotkey(targetBundleID: "com.google.Chrome", shortcutID: "s1", at: 5.2)
        XCTAssertEqual(buffer.classifyActivation(bundleID: "com.google.Chrome", at: 5.3),
                       .managedHotkey(shortcutID: "s1", token: token))
    }

    func testExpireClearsStaleEntries() {
        var buffer = AttributionBuffer()
        buffer.noteNavigation(comboID: "kc48-m256", at: 1.0)
        buffer.expire(at: 3.0)
        XCTAssertNil(buffer.lastNavigation)
        XCTAssertEqual(buffer.classifyActivation(bundleID: "com.apple.finder", at: 3.0), .unknownOrigin)
    }
}

/// End-to-end pipeline attribution, backed by real SQLite.
final class AttributionPersistenceTests: XCTestCase {
    private var temp: TempStore!
    private var pipeline: CapturePipeline!
    private var clock: TestClock!

    override func setUpWithError() throws {
        temp = try TempStore()
        clock = TestClock(TestDates.base)
        pipeline = CapturePipeline(
            store: temp.store,
            context: CaptureContext(hasInputMonitoringPermission: true),
            now: { [unowned self] in self.clock.current },
            timeZone: { TestDates.utc })
    }

    override func tearDownWithError() throws {
        temp.tearDown(); temp = nil; pipeline = nil; clock = nil
    }

    func testCmdTabThenActivationCountsAsKeyboardNavigation() throws {
        pipeline.updateContext { $0.foregroundBundleID = "com.apple.finder" }
        pipeline.handle(RawKeyEvent(keyCode: 48, modifiers: .command))
        pipeline.handleAppActivation(bundleID: "com.google.Chrome")

        let rows = try temp.store.dailyActivity(from: TestDates.bucket(0), to: TestDates.bucket(0))
        let chrome = rows.first { $0.bundleID == "com.google.Chrome" }
        XCTAssertEqual(chrome?.observedKeyboardNavigation, 1)
        XCTAssertEqual(chrome?.unknownOriginActivations, 0)
    }

    func testActivationWithoutPrecedingKeyIsUnknownOrigin() throws {
        pipeline.updateContext { $0.foregroundBundleID = "com.apple.finder" }
        pipeline.handleAppActivation(bundleID: "com.google.Chrome")
        let rows = try temp.store.dailyActivity(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertEqual(rows.first { $0.bundleID == "com.google.Chrome" }?.unknownOriginActivations, 1)
        XCTAssertEqual(rows.first { $0.bundleID == "com.google.Chrome" }?.observedKeyboardNavigation, 0)
    }

    func testExcludedTargetActivationIsNotCounted() throws {
        pipeline.updateContext { $0.foregroundBundleID = "com.apple.finder" }
        pipeline.updateContext { $0.excludedBundleIDs = ["com.1password.1password"] }
        pipeline.handleAppActivation(bundleID: "com.1password.1password")
        let rows = try temp.store.dailyActivity(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertTrue(rows.allSatisfy { $0.bundleID != "com.1password.1password" },
                      "excluded app must never appear in aggregates")
        XCTAssertTrue(rows.isEmpty)
    }

    func testActivationWhilePausedIsNotCounted() throws {
        pipeline.updateContext { $0.isPaused = true }
        pipeline.handleAppActivation(bundleID: "com.google.Chrome")
        XCTAssertTrue(try temp.store.dailyActivity(from: TestDates.bucket(0), to: TestDates.bucket(0)).isEmpty)
    }

    func testManagedHotkeyIsCountedOncePerPressAndOncePerActivation() throws {
        // Registration + trigger through the real action manager, then the app
        // activation notification that macOS delivers afterwards.
        let backend = FakeHotkeyBackend()
        let launcher = FakeAppLauncher()
        let manager = ShortcutActionManager(store: temp.store, backend: backend, launcher: launcher,
                                            timeZone: { TestDates.utc },
                                            now: { [unowned self] in self.clock.current })
        let combo = KeyCombo(keyCode: 8, modifiers: [.control, .option, .shift])
        let recommendation = Recommendation(
            id: "r1", bundleID: "com.apple.finder", kind: .launchFocus, targetID: "launch",
            proposedCombo: combo.comboID, confidence: .heuristic, status: .pending,
            createdAt: "2026-03-02T09:00:00Z", cooldownUntil: nil, updatedAt: "2026-03-02T09:00:00Z")
        try temp.store.upsertRecommendation(recommendation)
        let record = try manager.apply(
            recommendation: recommendation, combo: combo,
            conflict: ConflictResult(status: .noKnownConflict, evidence: []))

        manager.onTrigger = { [unowned self] shortcutID, target in
            self.pipeline.noteManagedHotkey(shortcutID: shortcutID, targetBundleID: target)
        }
        // Finder is the foreground app, so each press re-activates an already
        // running app and macOS posts an activation notification for it.
        launcher.running = ["com.apple.finder"]
        for _ in 0..<5 {
            backend.press(shortcutID: record.id)
            pipeline.handleAppActivation(bundleID: "com.apple.finder")
        }

        let usage = try temp.store.shortcutUsage(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.triggerCount, 5, "one trigger per physical press")
        XCTAssertEqual(usage.first?.successfulTargetActivations, 5,
                       "successful activations counted from the activation notification")

        let activity = try temp.store.dailyActivity(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertEqual(activity.first { $0.bundleID == "com.apple.finder" }?.managedHotkeyActivations, 5)
        XCTAssertEqual(activity.first { $0.bundleID == "com.apple.finder" }?.unknownOriginActivations, 0)
    }

    func testTriggerWithoutSuccessfulActivationIsVisibleAsMismatch() throws {
        let backend = FakeHotkeyBackend()
        let launcher = FakeAppLauncher(installed: ["com.apple.finder"], running: [])
        let manager = ShortcutActionManager(store: temp.store, backend: backend, launcher: launcher,
                                            timeZone: { TestDates.utc },
                                            now: { [unowned self] in self.clock.current })
        let combo = KeyCombo(keyCode: 9, modifiers: [.control, .option, .shift])
        let recommendation = Recommendation(
            id: "r2", bundleID: "com.apple.finder", kind: .launchFocus, targetID: "launch",
            proposedCombo: combo.comboID, confidence: .heuristic, status: .pending,
            createdAt: "2026-03-02T09:00:00Z", cooldownUntil: nil, updatedAt: "2026-03-02T09:00:00Z")
        try temp.store.upsertRecommendation(recommendation)
        let record = try manager.apply(recommendation: recommendation, combo: combo,
                                       conflict: ConflictResult(status: .noKnownConflict, evidence: []))

        // Press five times. The launcher reports the app as already running, but no
        // activation notification is delivered to the pipeline, so only the handler
        // counter moves. Successful activations must stay at zero rather than being
        // inferred from the launcher's return value.
        launcher.running = ["com.apple.finder"]
        for _ in 0..<5 { backend.press(shortcutID: record.id) }

        let usage = try temp.store.shortcutUsage(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertEqual(usage.first?.triggerCount, 5)
        XCTAssertEqual(usage.first?.successfulTargetActivations, 0,
                       "launch is not the same as an observed activation")
        XCTAssertLessThanOrEqual(usage.first?.successfulTargetActivations ?? 0, 4)
    }
}

/// Muse-3 round 2 could not see the Store SQL or the onTrigger wiring, so it could
/// not confirm the no-double-count property end to end. These tests close that gap
/// by driving the real registration path against real SQLite.
final class TriggerAccountingIntegrationTests: XCTestCase {
    private var temp: TempStore!
    private var backend: FakeHotkeyBackend!
    private var launcher: FakeAppLauncher!
    private var manager: ShortcutActionManager!
    private var pipeline: CapturePipeline!

    override func setUpWithError() throws {
        temp = try TempStore()
        backend = FakeHotkeyBackend()
        launcher = FakeAppLauncher(installed: ["com.apple.finder"], running: ["com.apple.finder"])
        manager = ShortcutActionManager(store: temp.store, backend: backend, launcher: launcher,
                                        timeZone: { TestDates.utc }, now: { TestDates.base })
        pipeline = CapturePipeline(
            store: temp.store,
            context: CaptureContext(hasInputMonitoringPermission: true),
            now: { TestDates.base }, timeZone: { TestDates.utc })
        // Exactly the wiring AppController performs.
        manager.onTrigger = { [unowned self] shortcutID, target in
            self.pipeline.noteManagedHotkey(shortcutID: shortcutID, targetBundleID: target)
        }
    }

    override func tearDownWithError() throws {
        temp.tearDown(); temp = nil; backend = nil; launcher = nil; manager = nil; pipeline = nil
    }

    private func apply() throws -> RegisteredShortcut {
        let combo = KeyCombo(keyCode: 8, modifiers: [.control, .option, .shift])
        let rec = Recommendation(id: "r1", bundleID: "com.apple.finder", kind: .launchFocus,
                                 targetID: "launch", proposedCombo: combo.comboID,
                                 confidence: .heuristic, status: .pending,
                                 createdAt: "2026-03-02T09:00:00Z", cooldownUntil: nil,
                                 updatedAt: "2026-03-02T09:00:00Z")
        try temp.store.upsertRecommendation(rec)
        return try manager.apply(recommendation: rec, combo: combo,
                                 conflict: ConflictResult(status: .noKnownConflict, evidence: []))
    }

    func testFivePressesWithFiveNotificationsNeverExceedFive() throws {
        let record = try apply()
        for _ in 0..<5 {
            backend.press(shortcutID: record.id)                     // handler + onTrigger
            pipeline.handleAppActivation(bundleID: "com.apple.finder") // activation observer
        }
        let usage = try temp.store.shortcutUsage(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertEqual(usage.first?.triggerCount, 5)
        XCTAssertEqual(usage.first?.successfulTargetActivations, 5,
                       "each press is matched by exactly one activation notification")

        let activity = try temp.store.dailyActivity(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertEqual(activity.first?.managedHotkeyActivations, 5)
    }

    func testPressesWithoutNotificationsCountOnlyTriggers() throws {
        let record = try apply()
        for _ in 0..<5 { backend.press(shortcutID: record.id) }
        let usage = try temp.store.shortcutUsage(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertEqual(usage.first?.triggerCount, 5)
        XCTAssertEqual(usage.first?.successfulTargetActivations, 0)
    }

    func testAnUnrelatedActivationDoesNotCreditTheShortcut() throws {
        let record = try apply()
        backend.press(shortcutID: record.id)
        // A different app comes forward: the token must not be reused.
        pipeline.handleAppActivation(bundleID: "com.google.Chrome")
        let usage = try temp.store.shortcutUsage(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertEqual(usage.first?.triggerCount, 1)
        XCTAssertEqual(usage.first?.successfulTargetActivations, 0)
    }

    func testOneTokenCannotBeConsumedTwice() throws {
        let record = try apply()
        backend.press(shortcutID: record.id)
        pipeline.handleAppActivation(bundleID: "com.apple.finder")
        pipeline.handleAppActivation(bundleID: "com.apple.finder")
        let usage = try temp.store.shortcutUsage(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertEqual(usage.first?.triggerCount, 1)
        XCTAssertEqual(usage.first?.successfulTargetActivations, 1,
                       "the second activation has no token and must be unknown_origin")
    }
}
