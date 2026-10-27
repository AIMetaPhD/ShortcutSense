import Foundation

/// Finds repeated patterns in the T1 sequence.
///
/// Two patterns are recognised, both from the same rows:
///
/// 1. **Repeated menu command** — the user keeps using a static menu item that
///    already has a shortcut. That is a Learn candidate: "⌘N already does this".
/// 2. **Repeated application group** — the same two or three apps come to the front
///    in the same hour on several days. That is a workspace candidate.
///
/// Nothing here invents evidence. A pattern that appears once, or on one day, is not
/// reported; the thresholds are the same 7/2 rule the rest of the product uses, except
/// where noted.
public struct MenuCommandPattern: Equatable, Sendable {
    public let bundleID: String
    public let commandID: String
    public let safeLabel: String?
    public let knownShortcut: String?
    /// Verified clicks, or nil for a manual mark. Never a fabricated count.
    public let observedCount: Int?
    public let activeDays: Int
    public let provenance: MenuProvenance
}

public struct WorkspacePattern: Equatable, Sendable {
    public let bundleIDs: [String]
    /// Days on which this group appeared together in one hour.
    public let activeDays: Int
    /// Total occurrences across the window.
    public let occurrences: Int
}

public enum PatternDiscovery {
    /// Menu commands worth a Learn card.
    ///
    /// Requires 7 verified clicks across 2 days, matching `RecommendationThresholds`.
    /// Manual marks are returned separately with `observedCount == nil`, so the UI
    /// cannot turn one mark into seven clicks.
    public static func menuCommandPatterns(events: [T1Event]) -> [MenuCommandPattern] {
        struct Key: Hashable { let bundle: String; let command: String; let provenance: MenuProvenance }
        var counts: [Key: Int] = [:]
        var days: [Key: Set<String>] = [:]
        var latest: [Key: T1Event] = [:]

        for event in events {
            guard let commandID = event.commandID else { continue }
            let provenance: MenuProvenance = event.kind == .manualMark
                ? .explicitManualMark : .verifiedAXClick
            let key = Key(bundle: event.bundleID, command: commandID, provenance: provenance)
            counts[key, default: 0] += 1
            days[key, default: []].insert(event.date)
            latest[key] = event
        }

        var results: [MenuCommandPattern] = []
        for (key, count) in counts {
            let dayCount = days[key]?.count ?? 0
            let event = latest[key]
            switch key.provenance {
            case .verifiedAXClick:
                guard count >= RecommendationThresholds.candidate,
                      dayCount >= RecommendationThresholds.minimumActiveDays else { continue }
                results.append(MenuCommandPattern(
                    bundleID: key.bundle, commandID: key.command,
                    safeLabel: event?.safeLabel, knownShortcut: event?.knownShortcut,
                    observedCount: count, activeDays: dayCount,
                    provenance: .verifiedAXClick))
            case .explicitManualMark:
                results.append(MenuCommandPattern(
                    bundleID: key.bundle, commandID: key.command,
                    safeLabel: event?.safeLabel, knownShortcut: event?.knownShortcut,
                    observedCount: nil, activeDays: dayCount,
                    provenance: .explicitManualMark))
            }
        }
        return results.sorted {
            ($0.observedCount ?? 0, $0.commandID) > ($1.observedCount ?? 0, $1.commandID)
        }
    }

    /// Application groups that recur.
    ///
    /// Groups are formed per (date, hour) from activation events, then counted across
    /// days. A group must appear on at least two different days, which is the same
    /// evidence bar the launch/focus recommendations use.
    public static func workspacePatterns(events: [T1Event],
                                         minimumDays: Int = 2,
                                         maximumGroupSize: Int = 3) -> [WorkspacePattern] {
        struct Bucket: Hashable { let date: String; let hour: Int }
        var appsByBucket: [Bucket: [String]] = [:]
        for event in events where event.kind == .appActivation {
            appsByBucket[Bucket(date: event.date, hour: event.hour), default: []]
                .append(event.bundleID)
        }

        var occurrences: [Set<String>: Int] = [:]
        var days: [Set<String>: Set<String>] = [:]
        for (bucket, apps) in appsByBucket {
            // De-duplicate while preserving first-seen order, then take up to the
            // maximum group size. A group larger than three is not something a single
            // hotkey should launch.
            var ordered: [String] = []
            for app in apps where !ordered.contains(app) { ordered.append(app) }
            guard ordered.count >= 2 else { continue }
            let group = Set(ordered.prefix(maximumGroupSize))
            guard group.count >= 2 else { continue }
            occurrences[group, default: 0] += 1
            days[group, default: []].insert(bucket.date)
        }

        return occurrences.compactMap { group, count in
            let dayCount = days[group]?.count ?? 0
            guard dayCount >= minimumDays, count >= minimumDays else { return nil }
            return WorkspacePattern(bundleIDs: group.sorted(), activeDays: dayCount,
                                    occurrences: count)
        }
        .sorted { ($0.activeDays, $0.occurrences) > ($1.activeDays, $1.occurrences) }
    }
}
