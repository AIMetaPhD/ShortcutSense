import SwiftUI
import ShortcutSenseCore

/// Shortcuts screen: Top 5, per-app filter, time range, and the heatmap.
///
/// The heatmap is the same component used on Today, so the privacy rule (only
/// normalized combinations are representable) is enforced in one place.
@MainActor
final class ShortcutsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        let display: String
        let count: Int
        let bundleIDs: [String]
    }

    enum Range: Int, CaseIterable, Identifiable {
        case today = 1
        case week = 7
        case month = 30
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .today: return L.isChinese ? "今天" : "Today"
            case .week: return L.isChinese ? "7 天" : "7 days"
            case .month: return L.isChinese ? "30 天" : "30 days"
            }
        }
    }

    @Published var range: Range = .week { didSet { reload() } }
    @Published var appFilter: String? { didSet { reload() } }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var availableApps: [String] = []
    @Published var error: String?

    func reload() {
        let store = AppController.shared.store
        let window = DateBuckets.rollingWindow(endingAt: Date(), days: range.rawValue,
                                               timeZone: store.collectionTimeZone)
        let start = window.buckets.first ?? ""
        let end = window.buckets.last ?? ""
        do {
            let stats = try store.comboStats(from: start, to: end)
            availableApps = Array(Set(stats.map(\.bundleID))).sorted()
            var totals: [String: (count: Int, apps: Set<String>)] = [:]
            for stat in stats {
                if let filter = appFilter, stat.bundleID != filter { continue }
                var entry = totals[stat.comboID] ?? (0, [])
                entry.count += stat.count
                entry.apps.insert(stat.bundleID)
                totals[stat.comboID] = entry
            }
            rows = totals
                .map { Row(id: $0.key,
                           display: KeyComboCodec.decode($0.key)?.displayString ?? $0.key,
                           count: $0.value.count,
                           bundleIDs: $0.value.apps.sorted()) }
                .sorted { ($0.count, $1.id) > ($1.count, $0.id) }
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}

struct ShortcutsDashboard: View {
    @ObservedObject var model: ShortcutsModel

    private var heatmapData: [String: Int] {
        Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0.count) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                Text(L.t("nav.shortcuts")).font(.system(size: 24, weight: .bold))

                Card {
                    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        SectionHeader(title: L.t("today.heatmap"),
                                      subtitle: L.t("today.heatmapCaption"))
                        ShortcutHeatmap(combos: heatmapData)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        HStack {
                            SectionHeader(title: L.t("today.top5"))
                            Spacer()
                            Picker("", selection: $model.range) {
                                ForEach(ShortcutsModel.Range.allCases) { range in
                                    Text(range.label).tag(range)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 200)
                        }

                        if !model.availableApps.isEmpty {
                            Picker(L.isChinese ? "应用" : "App",
                                   selection: Binding(
                                    get: { model.appFilter ?? "" },
                                    set: { model.appFilter = $0.isEmpty ? nil : $0 })) {
                                Text(L.isChinese ? "全部应用" : "All apps").tag("")
                                ForEach(model.availableApps, id: \.self) { bundle in
                                    Text(DisplayName.app(bundle)).tag(bundle)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 260, alignment: .leading)
                        }

                        if let error = model.error {
                            Text(error).font(Theme.Font.caption).foregroundStyle(.red)
                        }

                        if model.rows.isEmpty {
                            EmptyStateView(
                                symbol: "command",
                                title: L.isChinese ? "还没有快捷键记录" : "No shortcuts recorded yet",
                                message: L.isChinese
                                    ? "只有在使用 Command 或 Control 组合键时才会记录。普通打字、仅 Option 输入和 Dead Key 都不会被计入。"
                                    : "Only Command or Control combinations are recorded. Plain typing, Option-only input and dead keys are never counted.")
                        } else {
                            let peak = model.rows.map(\.count).max() ?? 1
                            ForEach(Array(model.rows.prefix(5).enumerated()), id: \.element.id) { index, row in
                                ComboRankRow(rank: index + 1,
                                             combo: ComboTotal(comboID: row.id, display: row.display,
                                                               count: row.count, bundleIDs: row.bundleIDs),
                                             peak: peak)
                            }
                            if model.rows.count > 5 {
                                Divider()
                                ForEach(Array(model.rows.dropFirst(5).enumerated()), id: \.element.id) { index, row in
                                    ComboRankRow(rank: index + 6,
                                                 combo: ComboTotal(comboID: row.id, display: row.display,
                                                                   count: row.count, bundleIDs: row.bundleIDs),
                                                 peak: peak)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Theme.Spacing.large)
        }
        .background(.background)
        .onAppear { model.reload() }
    }
}
