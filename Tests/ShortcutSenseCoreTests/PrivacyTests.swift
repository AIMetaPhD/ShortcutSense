import Foundation
import XCTest
@testable import ShortcutSenseCore

/// AC-04 / AC-05 / AC-06: the privacy gate fails closed and text never reaches disk.
final class PrivacyGateTests: XCTestCase {
    private let gate = PrivacyGate()

    private func context(_ mutate: (inout CaptureContext) -> Void = { _ in }) -> CaptureContext {
        var base = CaptureContext(
            hasInputMonitoringPermission: true,
            foregroundBundleID: "com.apple.finder",
            excludedBundleIDs: ["com.1password.1password"])
        mutate(&base)
        return base
    }

    func testAllowsWhenEveryConditionIsHealthy() {
        XCTAssertEqual(gate.decide(context()), .allow(bundleID: "com.apple.finder"))
    }

    func testFailsClosedForEachUnsafeCondition() {
        XCTAssertEqual(gate.decide(context { $0.hasInputMonitoringPermission = false }),
                       .drop(reason: .noInputMonitoringPermission))
        XCTAssertEqual(gate.decide(context { $0.isPaused = true }), .drop(reason: .paused))
        XCTAssertEqual(gate.decide(context { $0.isScreenLocked = true }), .drop(reason: .screenLocked))
        XCTAssertEqual(gate.decide(context { $0.isSecureInputEnabled = true }), .drop(reason: .secureInput))
        XCTAssertEqual(gate.decide(context { $0.foregroundBundleID = nil }), .drop(reason: .unknownForegroundApp))
        XCTAssertEqual(gate.decide(context { $0.foregroundBundleID = "" }), .drop(reason: .unknownForegroundApp))
        XCTAssertEqual(gate.decide(context { $0.foregroundBundleID = PrivacyGate.ownBundleID }),
                       .drop(reason: .ownApplication))
    }

    func testExcludedApplicationIsDropped() {
        XCTAssertEqual(gate.decide(context { $0.foregroundBundleID = "com.1password.1password" }),
                       .drop(reason: .excludedApp))
    }

    func testMenuObservationRequiresAllowlistedApp() {
        XCTAssertEqual(gate.decideMenuObservation(context(), bundleID: "com.apple.finder"),
                       .allow(bundleID: "com.apple.finder"))
        XCTAssertEqual(gate.decideMenuObservation(context(), bundleID: "com.example.notes"),
                       .drop(reason: .excludedApp))
        XCTAssertEqual(gate.decideMenuObservation(context { $0.isSecureInputEnabled = true },
                                                  bundleID: "com.apple.finder"),
                       .drop(reason: .secureInput))
    }

    func testDefaultExclusionsCoverSensitiveApplications() {
        let ids = Set(SensitiveApps.defaults.map(\.bundleID))
        for required in ["com.1password.1password", "com.bitwarden.desktop", "com.lastpass.LastPass",
                         "com.apple.keychainaccess", "com.apple.Terminal", "com.googlecode.iterm2"] {
            XCTAssertTrue(ids.contains(required), "missing default exclusion \(required)")
        }
        XCTAssertTrue(SensitiveApps.terminalClassBundleIDs.isSubset(of: ids))
    }
}

/// AC-05 / AC-06: capture pipeline classification and on-disk evidence.
final class CapturePrivacyTests: XCTestCase {
    private var temp: TempStore!
    private var pipeline: CapturePipeline!
    private var clock: TestClock!

    override func setUpWithError() throws {
        temp = try TempStore()
        clock = TestClock(TestDates.base)
        pipeline = CapturePipeline(
            store: temp.store,
            context: CaptureContext(hasInputMonitoringPermission: true,
                                    foregroundBundleID: "com.apple.finder"),
            now: { [unowned self] in self.clock.current },
            timeZone: { TestDates.utc })
    }

    override func tearDownWithError() throws {
        temp.tearDown(); temp = nil; pipeline = nil; clock = nil
    }

    func testTextTypingProducesOnlyAnonymousCounts() throws {
        // "SecretPass123" typed into a password field.
        let text = Array("SecretPass123")
        for character in text {
            guard let code = KeyCodeNames.keyCode(forLetter: character)
                    ?? KeyCodeNames.digitKeyCodes[character] else {
                XCTFail("test fixture uses a character without a virtual key code: \(character)")
                continue
            }
            pipeline.handle(RawKeyEvent(keyCode: code, modifiers: []))
        }
        let activity = try temp.store.dailyActivity(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertEqual(activity.first?.totalAnonymousKeystrokes, text.count)

        // No combination was recorded, so no per-key identity exists on disk.
        let combos = try temp.store.comboStats(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertTrue(combos.isEmpty, "text input must never create combo rows")
    }

    func testOptionProducedCharactersAreNotTreatedAsShortcuts() throws {
        // Option+e is a dead key on a US layout; Option+letter produces text.
        for character in ["e", "u", "n"] {
            let code = KeyCodeNames.keyCode(forLetter: Character(character))!
            pipeline.handle(RawKeyEvent(keyCode: code, modifiers: .option))
        }
        let combos = try temp.store.comboStats(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertTrue(combos.isEmpty, "Option-only input is text, not a command")
        let activity = try temp.store.dailyActivity(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertEqual(activity.first?.totalAnonymousKeystrokes, 3)
    }

    func testCommandShortcutIsAggregatedByIdentity() throws {
        let copy = KeyCombo(keyCode: KeyCodeNames.keyCode(forLetter: "c")!, modifiers: .command)
        for _ in 0..<4 {
            pipeline.handle(RawKeyEvent(keyCode: copy.keyCode, modifiers: copy.modifiers))
        }
        let combos = try temp.store.comboStats(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertEqual(combos.count, 1)
        XCTAssertEqual(combos.first?.comboID, copy.comboID)
        XCTAssertEqual(combos.first?.count, 4)
    }

    func testModifierOnlyPressesRecordNothing() throws {
        for code in KeyCombo.modifierKeyCodes {
            pipeline.handle(RawKeyEvent(keyCode: code, modifiers: .command))
        }
        let combos = try temp.store.comboStats(from: TestDates.bucket(0), to: TestDates.bucket(0))
        let activity = try temp.store.dailyActivity(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertTrue(combos.isEmpty)
        XCTAssertTrue(activity.isEmpty)
    }

    func testSecureInputDropsEverything() throws {
        pipeline.updateContext { $0.isSecureInputEnabled = true }
        for character in ["s", "e", "c"] {
            pipeline.handle(RawKeyEvent(keyCode: KeyCodeNames.keyCode(forLetter: Character(character))!,
                                        modifiers: []))
        }
        pipeline.handle(RawKeyEvent(keyCode: 8, modifiers: .command))
        XCTAssertTrue(try temp.store.dailyActivity(from: TestDates.bucket(0), to: TestDates.bucket(0)).isEmpty)
        XCTAssertTrue(try temp.store.comboStats(from: TestDates.bucket(0), to: TestDates.bucket(0)).isEmpty)
    }

    func testExcludedApplicationRecordsNothing() throws {
        pipeline.updateContext { $0.excludedBundleIDs = ["com.1password.1password"] }
        pipeline.updateContext { $0.foregroundBundleID = "com.1password.1password" }
        for character in ["p", "w"] {
            pipeline.handle(RawKeyEvent(keyCode: KeyCodeNames.keyCode(forLetter: Character(character))!,
                                        modifiers: []))
        }
        XCTAssertTrue(try temp.store.dailyActivity(from: TestDates.bucket(0), to: TestDates.bucket(0)).isEmpty)
    }

    func testPausedRecordsNothingAndResumeWorks() throws {
        pipeline.updateContext { $0.isPaused = true }
        pipeline.handle(RawKeyEvent(keyCode: 8, modifiers: .command))
        XCTAssertTrue(try temp.store.comboStats(from: TestDates.bucket(0), to: TestDates.bucket(0)).isEmpty)

        pipeline.updateContext { $0.isPaused = false }
        pipeline.handle(RawKeyEvent(keyCode: 8, modifiers: .command))
        XCTAssertEqual(try temp.store.comboStats(from: TestDates.bucket(0), to: TestDates.bucket(0)).first?.count, 1)
    }

    func testNoRawKeyDataAppearsInAnyDatabaseFile() throws {
        // Type a long, distinctive password-like string, then scan the raw files.
        let secret = "CorrectHorseBatteryStaple"
        for character in secret.lowercased() {
            guard let code = KeyCodeNames.keyCode(forLetter: character) else { continue }
            pipeline.handle(RawKeyEvent(keyCode: code, modifiers: []))
        }
        pipeline.handle(RawKeyEvent(keyCode: 8, modifiers: .command))
        temp.store.close()

        for path in [temp.databasePath, temp.walPath, temp.shmPath] {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.lowercased().contains(secret.lowercased()),
                           "typed text leaked into \(URL(fileURLWithPath: path).lastPathComponent)")
        }
    }

    func testExportAfterTypingContainsNoText() throws {
        for character in "hunter2" {
            guard let code = KeyCodeNames.keyCode(forLetter: character)
                    ?? KeyCodeNames.digitKeyCodes[character] else { continue }
            pipeline.handle(RawKeyEvent(keyCode: code, modifiers: []))
        }
        let payload = try temp.store.exportAggregates(from: TestDates.bucket(0), to: TestDates.bucket(0))
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        XCTAssertFalse(json.contains("hunter2"))
        XCTAssertFalse(json.lowercased().contains("\"h\""), "export must not contain per-key identity")
    }
}

/// A password field can gain focus between two UI polls. The gate must therefore be
/// re-evaluated against live state at the moment of each keystroke.
final class LiveStatePrivacyTests: XCTestCase {
    private var temp: TempStore!
    private var pipeline: CapturePipeline!
    private var secureInputActive = false
    private var locked = false

    override func setUpWithError() throws {
        temp = try TempStore()
        secureInputActive = false
        locked = false
        pipeline = CapturePipeline(
            store: temp.store,
            context: CaptureContext(hasInputMonitoringPermission: true,
                                    foregroundBundleID: "com.apple.Safari"),
            now: { TestDates.base },
            timeZone: { TestDates.utc })
        pipeline.refreshVolatileState = { [unowned self] context in
            context.isSecureInputEnabled = self.secureInputActive
            context.isScreenLocked = self.locked
        }
    }

    override func tearDownWithError() throws {
        temp.tearDown(); temp = nil; pipeline = nil
    }

    func testSecureInputActivatedBetweenPollsDropsTheVeryNextKey() throws {
        let code = KeyCodeNames.keyCode(forLetter: "s")!
        pipeline.handle(RawKeyEvent(keyCode: code, modifiers: []))
        XCTAssertEqual(try temp.store.dailyActivity(from: TestDates.bucket(0),
                                                    to: TestDates.bucket(0)).first?.totalAnonymousKeystrokes, 1)

        // Password field gains focus without any poll having run.
        secureInputActive = true
        for character in ["e", "c", "r", "e", "t"] {
            pipeline.handle(RawKeyEvent(keyCode: KeyCodeNames.keyCode(forLetter: Character(character))!,
                                        modifiers: []))
        }
        XCTAssertEqual(try temp.store.dailyActivity(from: TestDates.bucket(0),
                                                    to: TestDates.bucket(0)).first?.totalAnonymousKeystrokes, 1,
                       "no keystroke may be counted once secure input is active")
    }

    func testLockBetweenPollsDropsTheVeryNextKey() throws {
        locked = true
        pipeline.handle(RawKeyEvent(keyCode: 8, modifiers: .command))
        XCTAssertTrue(try temp.store.comboStats(from: TestDates.bucket(0), to: TestDates.bucket(0)).isEmpty)

        locked = false
        pipeline.handle(RawKeyEvent(keyCode: 8, modifiers: .command))
        XCTAssertEqual(try temp.store.comboStats(from: TestDates.bucket(0),
                                                 to: TestDates.bucket(0)).first?.count, 1)
    }

    func testRefreshCanAlsoRevokePermissionImmediately() throws {
        pipeline.refreshVolatileState = { context in
            context.hasInputMonitoringPermission = false
        }
        pipeline.handle(RawKeyEvent(keyCode: 8, modifiers: .command))
        XCTAssertTrue(try temp.store.comboStats(from: TestDates.bucket(0), to: TestDates.bucket(0)).isEmpty)
    }
}

/// Observed on a real Mac (2026-10-27): granting Input Monitoring created an
/// activation row for `com.apple.accessibility.universalAccessAuthWarn` — the
/// consent dialog itself. System UI is not user behaviour and must not be counted.
final class SystemUICaptureTests: XCTestCase {
    private var temp: TempStore!
    private var pipeline: CapturePipeline!

    override func setUpWithError() throws {
        temp = try TempStore()
        try temp.store.seedDefaultExclusions(SensitiveApps.defaults)
        pipeline = CapturePipeline(
            store: temp.store,
            context: CaptureContext(
                hasInputMonitoringPermission: true,
                foregroundBundleID: "com.apple.finder",
                excludedBundleIDs: Set(temp.store.excludedBundleIDs())),
            now: { TestDates.base }, timeZone: { TestDates.utc })
    }

    override func tearDownWithError() throws {
        temp.tearDown(); temp = nil; pipeline = nil
    }

    func testConsentDialogIsNotCountedAsAnActivation() throws {
        pipeline.handleAppActivation(bundleID: "com.apple.accessibility.universalAccessAuthWarn")
        let rows = try temp.store.dailyActivity(from: TestDates.bucket(0), to: TestDates.bucket(0))
        XCTAssertTrue(rows.isEmpty, "the permission dialog must not appear as an app")
    }

    func testOtherSystemUIProcessesAreExcluded() throws {
        for bundle in ["com.apple.notificationcenterui", "com.apple.controlcenter",
                       "com.apple.UserNotificationCenter", "com.apple.Spotlight"] {
            pipeline.handleAppActivation(bundleID: bundle)
        }
        XCTAssertTrue(try temp.store.dailyActivity(from: TestDates.bucket(0),
                                                   to: TestDates.bucket(0)).isEmpty)
    }

    func testOrdinaryAppsAreStillCounted() throws {
        pipeline.handleAppActivation(bundleID: "com.apple.finder")
        XCTAssertEqual(try temp.store.dailyActivity(from: TestDates.bucket(0),
                                                    to: TestDates.bucket(0)).count, 1)
    }
}

/// Observed on the owner's Mac: `com.openai.codex` produced keystroke rows during a
/// normal session. Input to an AI coding tool is predominantly code, prompts and
/// credentials, so it must be excluded like a terminal.
final class CodeToolCaptureTests: XCTestCase {
    private var temp: TempStore!
    private var pipeline: CapturePipeline!

    override func setUpWithError() throws {
        temp = try TempStore()
        try temp.store.seedDefaultExclusions(SensitiveApps.defaults)
        pipeline = CapturePipeline(
            store: temp.store,
            context: CaptureContext(
                hasInputMonitoringPermission: true,
                foregroundBundleID: "com.apple.Safari",
                excludedBundleIDs: Set(temp.store.excludedBundleIDs())),
            now: { TestDates.base }, timeZone: { TestDates.utc })
    }

    override func tearDownWithError() throws {
        temp.tearDown(); temp = nil; pipeline = nil
    }

    func testAICodingToolIsNotRecorded() throws {
        pipeline.updateContext { $0.foregroundBundleID = "com.openai.codex" }
        for character in ["k", "e", "y"] {
            pipeline.handle(RawKeyEvent(keyCode: KeyCodeNames.keyCode(forLetter: Character(character))!,
                                        modifiers: []))
        }
        XCTAssertTrue(try temp.store.dailyActivity(from: TestDates.bucket(0),
                                                   to: TestDates.bucket(0)).isEmpty)
    }

    func testEditorsAndIDEsAreNotRecorded() throws {
        for bundle in ["com.microsoft.VSCode", "com.anthropic.claude",
                       "com.todesktop.230313mzl4w4u92", "com.postmanlabs.postman"] {
            pipeline.updateContext { $0.foregroundBundleID = bundle }
            pipeline.handle(RawKeyEvent(keyCode: 8, modifiers: .command))
            pipeline.handleAppActivation(bundleID: bundle)
        }
        XCTAssertTrue(try temp.store.comboStats(from: TestDates.bucket(0),
                                                to: TestDates.bucket(0)).isEmpty)
        XCTAssertTrue(try temp.store.dailyActivity(from: TestDates.bucket(0),
                                                   to: TestDates.bucket(0)).isEmpty)
    }

    func testOrdinaryAppsAreStillRecorded() throws {
        pipeline.updateContext { $0.foregroundBundleID = "com.google.Chrome" }
        pipeline.handle(RawKeyEvent(keyCode: KeyCodeNames.keyCode(forLetter: "a")!, modifiers: []))
        XCTAssertEqual(try temp.store.dailyActivity(from: TestDates.bucket(0),
                                                    to: TestDates.bucket(0)).first?.totalAnonymousKeystrokes, 1)
    }
}

/// Muse-3 round 2: the terminal-class list must be a subset of the code-tool list,
/// so the two can never disagree about whether an app is excluded.
final class ExclusionListConsistencyTests: XCTestCase {
    func testTerminalClassIsASubsetOfCodeTools() {
        let codeTools = SensitiveApps.codeAndCredentialToolBundleIDs
        for bundle in SensitiveApps.terminalClassBundleIDs {
            XCTAssertTrue(codeTools.contains(bundle),
                          "\(bundle) is offered as re-includable but is not excluded at all")
        }
    }

    func testEveryCodeToolIsActuallyExcludedByDefault() {
        let defaults = Set(SensitiveApps.defaults.map(\.bundleID))
        for bundle in SensitiveApps.codeAndCredentialToolBundleIDs {
            XCTAssertTrue(defaults.contains(bundle), "\(bundle) is not in the default exclusions")
        }
    }

    func testHighRiskClassesAreCovered() {
        let defaults = Set(SensitiveApps.defaults.map(\.bundleID))
        // One representative per class Muse-3 named as missing.
        for bundle in ["com.apple.dt.Xcode", "com.jetbrains.intellij", "dev.zed.Zed",
                       "com.mitchellh.ghostty", "com.dashlane.dashlane",
                       "com.keepersecurity.passwordmanager", "com.enpass.Enpass"] {
            XCTAssertTrue(defaults.contains(bundle), "missing high-risk app: \(bundle)")
        }
    }

    func testOrdinaryAppsAreNotExcluded() {
        let defaults = Set(SensitiveApps.defaults.map(\.bundleID))
        for bundle in ["com.apple.Safari", "com.google.Chrome", "com.apple.finder",
                       "com.apple.mail", "com.apple.Notes"] {
            XCTAssertFalse(defaults.contains(bundle), "\(bundle) should not be excluded")
        }
    }

    func testFnBitIsTheCarbonValueAndConversionUsesTheCGValue() {
        // The two must not be confused: 0x8000 is Carbon, 0x00800000 is CG.
        XCTAssertEqual(ComboModifiers.function.rawValue, 0x8000)
        let converted = ComboModifiers(appleEventFlagsRawValue: 0x0080_0000)
        XCTAssertEqual(converted, .function)
        XCTAssertNotEqual(ComboModifiers(rawValue: 0x0080_0000), .function,
                          "the CG bit must never be stored as-is")
    }
}
