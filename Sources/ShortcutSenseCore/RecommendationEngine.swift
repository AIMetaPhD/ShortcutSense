import Foundation

/// Aggregated evidence for one application over a rolling window.
public struct AppEvidence: Equatable, Sendable {
    public let bundleID: String
    public let unknownOriginActivations: Int
    public let observedKeyboardNavigation: Int
    public let managedHotkeyActivations: Int
    public let activeDays: Int

    public init(bundleID: String, unknownOriginActivations: Int, observedKeyboardNavigation: Int,
                managedHotkeyActivations: Int, activeDays: Int) {
        self.bundleID = bundleID
        self.unknownOriginActivations = unknownOriginActivations
        self.observedKeyboardNavigation = observedKeyboardNavigation
        self.managedHotkeyActivations = managedHotkeyActivations
        self.activeDays = activeDays
    }
}

public enum RecommendationThresholds {
    /// Enters the candidate pool.
    public static let candidate = 7
    /// High-priority candidate.
    public static let highPriority = 14
    /// Distinct days with evidence required before proactively surfacing a card.
    public static let minimumActiveDays = 2
    /// Default dismissal cool-down.
    public static let dismissalCooldownDays = 28
    /// Existing keyboard navigation above this multiple suppresses proactive surfacing.
    public static let navigationDominanceFactor = 2
}

public enum SuppressionReason: String, Equatable, Sendable {
    case belowThreshold
    case insufficientActiveDays
    case alreadyHasManagedHotkey
    case inDismissalCooldown
    case userDisabledInferredRecommendations
    case keyboardNavigationDominates
    case noSafeComboAvailable
}

public enum CandidatePriority: Int, Comparable, Sendable {
    case normal = 0
    case high = 1
    public static func < (lhs: CandidatePriority, rhs: CandidatePriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LaunchFocusCandidate: Equatable, Sendable {
    public let bundleID: String
    public let priority: CandidatePriority
    public let confidence: Confidence
    public let proposedCombo: KeyCombo
    public let conflict: ConflictResult
    public let evidence: AppEvidence
    /// True when the card should be shown proactively. False means "candidate but
    /// not surfaced" (e.g. insufficient active days, or navigation already dominant).
    public let shouldSurface: Bool
    public let suppression: SuppressionReason?
}

public struct RecommendationEngine: Sendable {
    public let resolver: ConflictResolver

    public init(resolver: ConflictResolver = ConflictResolver()) {
        self.resolver = resolver
    }

    /// Builds launch/focus candidates.
    ///
    /// Evidence rules (07_DATA_CONTRACT §D):
    /// - `unknown_origin` activations ≥ 7 and ≥ 2 active days to enter the pool.
    /// - ≥ 14 is high priority.
    /// - Never `verified` confidence: the origin is a heuristic.
    /// - Existing observed keyboard navigation at > 2× the weak evidence suppresses
    ///   proactive surfacing (the user already has a keyboard path).
    public func launchFocusCandidates(
        evidence: [AppEvidence],
        existingManagedBundleIDs: Set<String>,
        dismissedBundleIDs: Set<String>,
        inferredRecommendationsEnabled: Bool,
        conflictInputs: ConflictInputs,
        comboAllocator: inout ComboAllocator
    ) -> [LaunchFocusCandidate] {
        var candidates: [LaunchFocusCandidate] = []

        for app in evidence.sorted(by: { $0.bundleID < $1.bundleID }) {
            let count = app.unknownOriginActivations
            guard count >= RecommendationThresholds.candidate else { continue }
            guard app.activeDays >= RecommendationThresholds.minimumActiveDays else { continue }
            guard !existingManagedBundleIDs.contains(app.bundleID) else { continue }
            guard !dismissedBundleIDs.contains(app.bundleID) else { continue }

            var suppression: SuppressionReason?
            if !inferredRecommendationsEnabled {
                suppression = .userDisabledInferredRecommendations
            } else if app.observedKeyboardNavigation > RecommendationThresholds.navigationDominanceFactor * count {
                suppression = .keyboardNavigationDominates
            }

            let priority: CandidatePriority = count >= RecommendationThresholds.highPriority ? .high : .normal

            guard let combo = comboAllocator.nextAvailable(inputs: conflictInputs) else {
                candidates.append(LaunchFocusCandidate(
                    bundleID: app.bundleID, priority: priority, confidence: .heuristic,
                    proposedCombo: KeyCombo(keyCode: 0, modifiers: []),
                    conflict: ConflictResult(status: .unknown, evidence: []),
                    evidence: app, shouldSurface: false, suppression: .noSafeComboAvailable))
                continue
            }
            let conflict = resolver.evaluate(combo, inputs: conflictInputs)
            guard conflict.isEligibleForAutomaticApply else {
                candidates.append(LaunchFocusCandidate(
                    bundleID: app.bundleID, priority: priority, confidence: .heuristic,
                    proposedCombo: combo, conflict: conflict,
                    evidence: app, shouldSurface: false, suppression: .noSafeComboAvailable))
                continue
            }
            comboAllocator.claim(combo)
            candidates.append(LaunchFocusCandidate(
                bundleID: app.bundleID, priority: priority, confidence: .heuristic,
                proposedCombo: combo, conflict: conflict, evidence: app,
                shouldSurface: suppression == nil, suppression: suppression))
        }
        return candidates
    }

    /// Learn candidates require *verified* menu-click data. A single manual mark is
    /// never counted as seven clicks; it produces an onboarding suggestion instead.
    public func learnCandidates(
        menuStats: [MenuActionStat],
        existingManagedCombos: Set<KeyCombo>,
        explicitMarks: [ExplicitMenuMark]
    ) -> [LearnCandidate] {
        var verified: [String: (stat: MenuActionStat, count: Int, days: Set<String>)] = [:]
        for stat in menuStats where stat.provenance == .verifiedAXClick {
            let key = "\(stat.bundleID)|\(stat.commandID)"
            var entry = verified[key] ?? (stat, 0, [])
            entry.count += stat.count
            entry.days.insert(stat.date)
            verified[key] = entry
        }

        var results: [LearnCandidate] = []
        for (_, entry) in verified.sorted(by: { $0.key < $1.key }) {
            let stat = entry.stat
            guard entry.count >= RecommendationThresholds.candidate else { continue }
            guard entry.days.count >= RecommendationThresholds.minimumActiveDays else { continue }
            guard let shortcut = stat.knownShortcut, !shortcut.isEmpty else {
                results.append(LearnCandidate(
                    bundleID: stat.bundleID, commandID: stat.commandID,
                    safeLabel: stat.safeLabel, existingShortcut: nil,
                    kind: .configureGuide, observedClickCount: entry.count,
                    activeDays: entry.days.count, confidence: .verified))
                continue
            }
            // Skip teaching a shortcut the user already uses often.
            let combo = KeyComboCodec.decode(shortcut)
            if let combo, existingManagedCombos.contains(combo) { continue }
            results.append(LearnCandidate(
                bundleID: stat.bundleID, commandID: stat.commandID,
                safeLabel: stat.safeLabel, existingShortcut: shortcut,
                kind: .learnExistingShortcut, observedClickCount: entry.count,
                activeDays: entry.days.count, confidence: .verified))
        }

        for mark in explicitMarks {
            let already = results.contains { $0.bundleID == mark.bundleID && $0.commandID == mark.commandID }
            if already { continue }
            results.append(LearnCandidate(
                bundleID: mark.bundleID, commandID: mark.commandID,
                safeLabel: mark.safeLabel, existingShortcut: mark.knownShortcut,
                kind: mark.knownShortcut == nil ? .configureGuide : .learnExistingShortcut,
                observedClickCount: nil, activeDays: nil, confidence: .heuristic,
                provenanceNote: .explicitManualMark))
        }
        return results
    }
}

public enum LearnKind: String, Sendable {
    case learnExistingShortcut = "learn_existing_shortcut"
    case configureGuide = "configure_guide"
}

public enum LearnProvenanceNote: String, Sendable {
    case verifiedMenuClicks = "verified_menu_clicks"
    case explicitManualMark = "explicit_manual_mark"
}

public struct ExplicitMenuMark: Equatable, Sendable {
    public let bundleID: String
    public let commandID: String
    public let safeLabel: String?
    public let knownShortcut: String?
    public init(bundleID: String, commandID: String, safeLabel: String?, knownShortcut: String?) {
        self.bundleID = bundleID; self.commandID = commandID
        self.safeLabel = safeLabel; self.knownShortcut = knownShortcut
    }
}

public struct LearnCandidate: Equatable, Sendable {
    public let bundleID: String
    public let commandID: String
    public let safeLabel: String?
    public let existingShortcut: String?
    public let kind: LearnKind
    /// Non-nil only for verified AX click data. Manual marks never carry a count.
    public let observedClickCount: Int?
    public let activeDays: Int?
    public let confidence: Confidence
    public var provenanceNote: LearnProvenanceNote = .verifiedMenuClicks

    public init(bundleID: String, commandID: String, safeLabel: String?, existingShortcut: String?,
                kind: LearnKind, observedClickCount: Int?, activeDays: Int?, confidence: Confidence,
                provenanceNote: LearnProvenanceNote = .verifiedMenuClicks) {
        self.bundleID = bundleID; self.commandID = commandID; self.safeLabel = safeLabel
        self.existingShortcut = existingShortcut; self.kind = kind
        self.observedClickCount = observedClickCount; self.activeDays = activeDays
        self.confidence = confidence; self.provenanceNote = provenanceNote
    }
}

/// Hands out candidate combos without reusing one already claimed in this pass.
public struct ComboAllocator: Sendable {
    private var claimed: Set<KeyCombo> = []
    private let pool: [KeyCombo]

    public init(pool: [KeyCombo] = SystemShortcuts.candidateCombos()) {
        self.pool = pool
    }

    public mutating func claim(_ combo: KeyCombo) { claimed.insert(combo) }

    public mutating func nextAvailable(inputs: ConflictInputs) -> KeyCombo? {
        pool.first { combo in
            !claimed.contains(combo) && inputs.registeredCombos.contains(combo) == false
        }
    }
}

/// Encodes a `KeyCombo` to/from the `combo_id` string used in the database.
public enum KeyComboCodec {
    public static func encode(_ combo: KeyCombo) -> String { combo.comboID }

    public static func decode(_ id: String) -> KeyCombo? {
        // Format: kc<keyCode>-m<modifiers>
        guard id.hasPrefix("kc"), let dash = id.firstIndex(of: "-"), id[id.index(after: dash)] == "m" else {
            return nil
        }
        let keyPart = id[id.index(id.startIndex, offsetBy: 2)..<dash]
        let modPart = id[id.index(dash, offsetBy: 2)...]
        guard let keyCode = UInt16(keyPart), let modifiers = UInt32(modPart) else { return nil }
        return KeyCombo(keyCode: keyCode, modifiers: ComboModifiers(rawValue: modifiers))
    }
}
