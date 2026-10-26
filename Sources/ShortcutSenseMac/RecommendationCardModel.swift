import SwiftUI
import ShortcutSenseCore

/// A recommendation prepared for display.
///
/// Every field the card shows is copied from real evidence; nothing is inferred at
/// render time. `observedCount` and `activeDays` are nil for manual marks, which is
/// how the card avoids claiming a click count it does not have.
struct RecommendationCardModel: Identifiable, Equatable {
    let id: String
    let bundleID: String
    let appName: String
    let kind: RecommendationKind
    let confidence: Confidence
    let proposedCombo: KeyCombo?
    let conflict: ConflictResult
    let observedCount: Int?
    let activeDays: Int?
    let provenanceNote: LearnProvenanceNote
    let existingShortcut: String?

    var hasObservedEvidence: Bool { observedCount != nil && activeDays != nil }

    /// Built from the live engine, not from stored fixtures.
    @MainActor
    static func pending() -> [RecommendationCardModel] {
        let controller = AppController.shared
        let store = controller.store
        let window = DateBuckets.rollingWindow(endingAt: Date(), days: 7,
                                               timeZone: store.collectionTimeZone)

        let activity = (try? store.dailyActivity(from: window.buckets.first ?? "",
                                                 to: window.buckets.last ?? "")) ?? []
        var byApp: [String: (unknown: Int, navigation: Int, days: Set<String>)] = [:]
        for row in activity {
            var entry = byApp[row.bundleID] ?? (0, 0, [])
            entry.unknown += row.unknownOriginActivations
            entry.navigation += row.observedKeyboardNavigation
            if row.unknownOriginActivations > 0 || row.observedKeyboardNavigation > 0 {
                entry.days.insert(row.date)
            }
            byApp[row.bundleID] = entry
        }
        let evidence = byApp.map { key, value in
            AppEvidence(bundleID: key, unknownOriginActivations: value.unknown,
                        observedKeyboardNavigation: value.navigation,
                        managedHotkeyActivations: 0, activeDays: value.days.count)
        }

        let registered = (try? store.registeredShortcuts(activeOnly: true)) ?? []
        let all = (try? store.recommendations()) ?? []
        let dismissed = Set(all.filter { rec in
            guard let until = rec.cooldownUntil, let when = DateBuckets.parseISO8601(until) else { return false }
            return when > Date()
        }.map(\.bundleID))

        var allocator = ComboAllocator()
        let engine = RecommendationEngine()
        let launchCandidates = engine.launchFocusCandidates(
            evidence: evidence,
            existingManagedBundleIDs: Set(registered.map(\.targetBundleID)),
            dismissedBundleIDs: dismissed,
            inferredRecommendationsEnabled: true,
            conflictInputs: controller.conflictInputs(targetBundleID: nil),
            comboAllocator: &allocator)

        var cards: [RecommendationCardModel] = launchCandidates
            .filter(\.shouldSurface)
            .map { candidate in
                RecommendationCardModel(
                    id: "launch-\(candidate.bundleID)",
                    bundleID: candidate.bundleID,
                    appName: DisplayName.app(candidate.bundleID),
                    kind: .launchFocus,
                    confidence: candidate.confidence,
                    proposedCombo: candidate.proposedCombo,
                    conflict: candidate.conflict,
                    observedCount: candidate.evidence.unknownOriginActivations,
                    activeDays: candidate.evidence.activeDays,
                    provenanceNote: .verifiedMenuClicks,
                    existingShortcut: nil)
            }

        // Learn cards exist only when the spike proved AX menu observation. Until
        // then the product must not pretend it observed menu clicks.
        if controller.menuObservationSupported {
            let menuStats = (try? store.menuActionStats(from: window.buckets.first ?? "",
                                                        to: window.buckets.last ?? "")) ?? []
            let learns = engine.learnCandidates(
                menuStats: menuStats,
                existingManagedCombos: Set(registered.map(\.combo)),
                explicitMarks: [])
            cards += learns.map { learn in
                RecommendationCardModel(
                    id: "learn-\(learn.bundleID)-\(learn.commandID)",
                    bundleID: learn.bundleID,
                    appName: DisplayName.app(learn.bundleID),
                    kind: learn.kind == .configureGuide ? .configure : .learn,
                    confidence: learn.confidence,
                    proposedCombo: learn.existingShortcut.flatMap(KeyComboCodec.decode),
                    conflict: ConflictResult(status: .unknown, evidence: []),
                    observedCount: learn.observedClickCount,
                    activeDays: learn.activeDays,
                    provenanceNote: learn.provenanceNote,
                    existingShortcut: learn.existingShortcut)
            }
        }

        return cards.sorted { lhs, rhs in
            (lhs.observedCount ?? 0) > (rhs.observedCount ?? 0)
        }
    }

    @MainActor
    static func topPending() -> RecommendationCardModel? { pending().first }
}

/// Compact form used on the Today screen.
struct RecommendationSummaryInline: View {
    let card: RecommendationCardModel

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.appName).font(Theme.Font.cardTitle)
                Text(evidenceLine)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let combo = card.proposedCombo {
                    Text(combo.displayString)
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var evidenceLine: String {
        guard let count = card.observedCount, let days = card.activeDays else {
            return L.isChinese
                ? "根据你的手动标记，不声称点击次数。"
                : "Based on your manual mark — no click count is claimed."
        }
        // Deliberately never says "clicked the Dock": the origin is unknown.
        return L.isChinese
            ? "7 天内激活 \(count) 次，分布在 \(days) 天。来源未知。"
            : "\(count) activations in 7 days on \(days) days. Origin unknown."
    }
}
