import Foundation
import XCTest
@testable import ShortcutSenseCore

/// AC-08 / AC-09 / AC-10: thresholds, active days, and semantic honesty.
final class RecommendationEngineTests: XCTestCase {
    private let engine = RecommendationEngine()

    /// Conflict inputs where every source is readable and clean, so a candidate can
    /// reach `no_known_conflict`.
    private var cleanInputs: ConflictInputs {
        ConflictInputs(targetMenuCombos: [], foregroundMenuCombos: [], symbolichotkeys: [])
    }

    private func evidence(_ bundle: String, unknown: Int, days: Int,
                          navigation: Int = 0, managed: Int = 0) -> AppEvidence {
        AppEvidence(bundleID: bundle, unknownOriginActivations: unknown,
                    observedKeyboardNavigation: navigation,
                    managedHotkeyActivations: managed, activeDays: days)
    }

    private func candidates(_ apps: [AppEvidence],
                            existing: Set<String> = [],
                            dismissed: Set<String> = [],
                            inferredEnabled: Bool = true,
                            inputs: ConflictInputs? = nil) -> [LaunchFocusCandidate] {
        var allocator = ComboAllocator()
        return engine.launchFocusCandidates(
            evidence: apps, existingManagedBundleIDs: existing,
            dismissedBundleIDs: dismissed,
            inferredRecommendationsEnabled: inferredEnabled,
            conflictInputs: inputs ?? cleanInputs, comboAllocator: &allocator)
    }

    // MARK: - Threshold fixtures (6 / 7 / 13 / 14)

    func testSixActivationsProduceNoCandidate() {
        XCTAssertTrue(candidates([evidence("com.app.foo", unknown: 6, days: 3)]).isEmpty)
    }

    func testSevenActivationsOnThreeDaysProducesNormalCandidate() {
        let result = candidates([evidence("com.app.foo", unknown: 7, days: 3)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.priority, .normal)
        XCTAssertTrue(result.first?.shouldSurface == true)
    }

    func testThirteenActivationsStayNormalPriority() {
        let result = candidates([evidence("com.app.foo", unknown: 13, days: 4)])
        XCTAssertEqual(result.first?.priority, .normal)
    }

    func testFourteenActivationsAreHighPriority() {
        let result = candidates([evidence("com.app.foo", unknown: 14, days: 2)])
        XCTAssertEqual(result.first?.priority, .high)
    }

    func testSevenActivationsOnOneDayIsCandidateButNotSurfaced() {
        let result = candidates([evidence("com.app.foo", unknown: 7, days: 1)])
        XCTAssertTrue(result.isEmpty,
                      "activeDays < 2 must not enter the pool at all (contract §D)")
    }

    // MARK: - Semantic honesty

    func testLaunchFocusConfidenceIsNeverVerified() {
        let result = candidates([evidence("com.app.foo", unknown: 30, days: 6)])
        XCTAssertEqual(result.first?.confidence, .heuristic)
        XCTAssertNotEqual(result.first?.confidence, .verified)
    }

    func testHeavyKeyboardNavigationSuppressesProactiveSurfacing() {
        // 15 navigations with the keyboard, 7 unknown-origin activations.
        let result = candidates([evidence("com.app.foo", unknown: 7, days: 3, navigation: 15)])
        XCTAssertEqual(result.first?.shouldSurface, false)
        XCTAssertEqual(result.first?.suppression, .keyboardNavigationDominates)
    }

    func testNavigationAtOrBelowTwiceWeakEvidenceStillSurfaces() {
        let result = candidates([evidence("com.app.foo", unknown: 7, days: 3, navigation: 14)])
        XCTAssertEqual(result.first?.shouldSurface, true)
    }

    func testDisabledInferenceSuppressesSurfacing() {
        let result = candidates([evidence("com.app.foo", unknown: 20, days: 5)], inferredEnabled: false)
        XCTAssertEqual(result.first?.shouldSurface, false)
        XCTAssertEqual(result.first?.suppression, .userDisabledInferredRecommendations)
    }

    func testAlreadyManagedAppIsSkipped() {
        XCTAssertTrue(candidates([evidence("com.app.foo", unknown: 20, days: 5)],
                                 existing: ["com.app.foo"]).isEmpty)
    }

    func testDismissedAppIsSkippedDuringCooldown() {
        XCTAssertTrue(candidates([evidence("com.app.foo", unknown: 20, days: 5)],
                                 dismissed: ["com.app.foo"]).isEmpty)
    }

    // MARK: - Combo allocation

    func testCandidatesNeverReceiveDuplicates() {
        let apps = (0..<5).map { evidence("com.app.app\($0)", unknown: 9, days: 3) }
        let result = candidates(apps)
        let combos = result.map(\.proposedCombo)
        XCTAssertEqual(Set(combos).count, combos.count, "each candidate needs a distinct combo")
    }

    func testProposedCombosUseTheSafePrefix() {
        let result = candidates([evidence("com.app.foo", unknown: 9, days: 3)])
        XCTAssertEqual(result.first?.proposedCombo.modifiers, SystemShortcuts.candidatePrefix)
    }

    func testNoCandidateWhenConflictsCannotBeCleared() {
        // Unreadable sources must not be treated as "free".
        let inputs = ConflictInputs(targetMenuCombos: nil, foregroundMenuCombos: nil, symbolichotkeys: nil)
        let result = candidates([evidence("com.app.foo", unknown: 9, days: 3)], inputs: inputs)
        XCTAssertEqual(result.first?.shouldSurface, false)
        XCTAssertEqual(result.first?.suppression, .noSafeComboAvailable)
    }
}

/// AC-11: four-state conflict detection with layered evidence.
final class ConflictResolverTests: XCTestCase {
    private let resolver = ConflictResolver()

    func testSystemGlobalShortcutIsOccupied() {
        let result = resolver.evaluate(KeyCombo(keyCode: 48, modifiers: .command),
                                       inputs: ConflictInputs())
        XCTAssertEqual(result.status, .occupied)
        XCTAssertFalse(result.isEligibleForAutomaticApply)
        XCTAssertTrue(result.evidence.contains { $0.scope == .systemGlobal })
    }

    func testSpotlightAndScreenshotAreOccupied() {
        for combo in [KeyCombo(keyCode: 49, modifiers: .command),
                      KeyCombo(keyCode: 20, modifiers: [.command, .shift]),
                      KeyCombo(keyCode: 21, modifiers: [.command, .shift]),
                      KeyCombo(keyCode: 23, modifiers: [.command, .shift])] {
            XCTAssertEqual(resolver.evaluate(combo, inputs: ConflictInputs()).status, .occupied,
                           "\(combo.displayString) must be blocked")
        }
    }

    func testCommandQWMAreHighRiskButNotGlobal() {
        for (code, label) in [(12, "Cmd+Q"), (13, "Cmd+W"), (4, "Cmd+H"), (46, "Cmd+M")] {
            let result = resolver.evaluate(KeyCombo(keyCode: UInt16(code), modifiers: .command),
                                           inputs: ConflictInputs())
            XCTAssertEqual(result.status, .potentialConflict, "\(label)")
            XCTAssertFalse(result.isEligibleForAutomaticApply, "\(label) must not be auto-applied")
            XCTAssertTrue(result.evidence.allSatisfy { $0.scope == .appMenuHighRisk },
                          "\(label) must not be described as a global grab")
        }
    }

    func testRegisteredComboIsOccupied() {
        let combo = KeyCombo(keyCode: 8, modifiers: [.control, .option, .shift])
        let result = resolver.evaluate(combo, inputs: ConflictInputs(registeredCombos: [combo]))
        XCTAssertEqual(result.status, .occupied)
    }

    func testUserReportedThirdPartyIsUnknown() {
        let combo = KeyCombo(keyCode: 8, modifiers: [.control, .option, .shift])
        let result = resolver.evaluate(combo, inputs: ConflictInputs(userReportedTaken: [combo]))
        XCTAssertEqual(result.status, .unknown)
        XCTAssertFalse(result.isEligibleForAutomaticApply)
    }

    func testEnabledSymbolicHotkeyIsOccupied() {
        let combo = KeyCombo(keyCode: 49, modifiers: [.control, .option])
        let result = resolver.evaluate(combo, inputs: ConflictInputs(symbolichotkeys: [combo]))
        XCTAssertEqual(result.status, .occupied)
    }

    func testTargetMenuBindingIsPotentialConflict() {
        let combo = KeyCombo(keyCode: 8, modifiers: [.control, .option, .shift])
        let result = resolver.evaluate(combo, inputs: ConflictInputs(targetMenuCombos: [combo]))
        XCTAssertEqual(result.status, .potentialConflict)
    }

    func testCleanAndFullyReadableIsNoKnownConflict() {
        let combo = KeyCombo(keyCode: 8, modifiers: [.control, .option, .shift])
        let result = resolver.evaluate(combo, inputs: ConflictInputs(
            targetMenuCombos: [], foregroundMenuCombos: [], symbolichotkeys: []))
        XCTAssertEqual(result.status, .noKnownConflict)
        XCTAssertTrue(result.isEligibleForAutomaticApply)
    }

    func testUnreadableSourcesDegradeToUnknownNotFree() {
        let combo = KeyCombo(keyCode: 8, modifiers: [.control, .option, .shift])
        XCTAssertEqual(resolver.evaluate(combo, inputs: ConflictInputs()).status, .unknown)
        XCTAssertEqual(resolver.evaluate(combo, inputs: ConflictInputs(
            targetMenuCombos: [], foregroundMenuCombos: [])).status, .unknown)
    }

    func testStatusEnumHasExactlyFourStates() {
        XCTAssertEqual(Set([ConflictStatus.occupied, .potentialConflict, .noKnownConflict, .unknown]).count, 4)
    }
}

/// AC-10: Learn candidates require verified data; manual marks never invent counts.
final class LearnCandidateTests: XCTestCase {
    private let engine = RecommendationEngine()

    private func stat(_ command: String, count: Int, day: Int,
                      provenance: MenuProvenance = .verifiedAXClick,
                      shortcut: String? = "kc8-m256") -> MenuActionStat {
        MenuActionStat(date: TestDates.bucket(day), bundleID: "com.apple.finder",
                       commandID: command, safeLabel: "New Finder Window",
                       knownShortcut: shortcut, provenance: provenance, count: count)
    }

    func testVerifiedSevenClicksOnTwoDaysProducesLearnCandidate() {
        let result = engine.learnCandidates(
            menuStats: [stat("new_window", count: 4, day: 0), stat("new_window", count: 3, day: 1)],
            existingManagedCombos: [], explicitMarks: [])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.kind, .learnExistingShortcut)
        XCTAssertEqual(result.first?.observedClickCount, 7)
        XCTAssertEqual(result.first?.confidence, .verified)
    }

    func testSevenClicksOnOneDayDoesNotQualify() {
        let result = engine.learnCandidates(
            menuStats: [stat("new_window", count: 7, day: 0)],
            existingManagedCombos: [], explicitMarks: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testOnlyFourVerifiedHitsOutOfSevenClicksReportsFour() {
        // Contract §F.3: never report seven when only four were identified.
        let result = engine.learnCandidates(
            menuStats: [stat("new_window", count: 4, day: 0), stat("new_window", count: 0, day: 1)],
            existingManagedCombos: [], explicitMarks: [])
        XCTAssertTrue(result.isEmpty, "four verified clicks is below the seven threshold")
    }

    func testManualMarkNeverCarriesAClickCount() {
        let result = engine.learnCandidates(
            menuStats: [],
            existingManagedCombos: [],
            explicitMarks: [ExplicitMenuMark(bundleID: "com.apple.finder", commandID: "new_window",
                                             safeLabel: "New Finder Window", knownShortcut: "kc45-m256")])
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result.first?.observedClickCount)
        XCTAssertNil(result.first?.activeDays)
        XCTAssertEqual(result.first?.provenanceNote, .explicitManualMark)
        XCTAssertEqual(result.first?.confidence, .heuristic)
    }

    func testMenuActionWithoutShortcutBecomesConfigureGuide() {
        let result = engine.learnCandidates(
            menuStats: [stat("empty_trash", count: 4, day: 0, shortcut: nil),
                        stat("empty_trash", count: 3, day: 2, shortcut: nil)],
            existingManagedCombos: [], explicitMarks: [])
        XCTAssertEqual(result.first?.kind, .configureGuide)
        XCTAssertNil(result.first?.existingShortcut)
    }
}
