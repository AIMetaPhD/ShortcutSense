import SwiftUI
import ShortcutSenseCore

/// SwiftUI root. Deliberately plain: every string shown here is a fact the core
/// can back up. Nothing claims a measurement that was not made.
enum NSHostingViewFactory {
    @MainActor
    static func makeRootView() -> NSView {
        NSHostingView(rootView: RootView())
    }
}

@MainActor
struct RootView: View {
    @State private var selection: Section = .today
    @StateObject private var today = TodayModel()
    @StateObject private var opportunities = OpportunitiesModel()
    @State private var windowWidth: CGFloat = Theme.Layout.dashboardIdeal.width

    enum Section: String, CaseIterable, Identifiable {
        case today, shortcuts, opportunities, conflicts, weekly, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: return L.t("nav.today")
            case .shortcuts: return L.t("nav.shortcuts")
            case .opportunities: return L.t("nav.opportunities")
            case .conflicts: return L.t("nav.conflicts")
            case .weekly: return L.t("nav.weekly")
            case .settings: return L.t("nav.settings")
            }
        }

        var symbol: String {
            switch self {
            case .today: return "square.grid.2x2"
            case .shortcuts: return "command"
            case .opportunities: return "sparkles"
            case .conflicts: return "exclamationmark.triangle"
            case .weekly: return "calendar"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: Theme.Layout.dashboardMin.width,
               minHeight: Theme.Layout.dashboardMin.height)
        .background(.background)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 12))
                            .frame(width: 16)
                        Text(section.title).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .background(
                        selection == section ? Theme.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .foregroundStyle(selection == section ? Theme.accent : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == section ? [.isSelected] : [])
            }
            Spacer()
            StatusPill(status: TodayModel.status(for: AppController.shared))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .padding(.top, Theme.Spacing.medium)
        .padding(.horizontal, 8)
        .frame(width: Theme.Layout.sidebarWidth)
        .background(.background.secondary)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .today:
            TodayDashboard(model: today)
        case .shortcuts:
            ShortcutsView()
        case .opportunities:
            OpportunitiesDashboard(model: opportunities)
        case .conflicts:
            ConflictView()
        case .weekly:
            WeeklyView()
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - Shortcuts

@MainActor
struct ShortcutsView: View {
    @State private var combos: [ComboRow] = []

    struct ComboRow: Identifiable {
        let id: String
        let display: String
        let count: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("Shortcuts", "快捷键")).font(.largeTitle.bold())
            Text(loc("Command and Control combinations are counted per application. Option-only typing, dead keys and plain text are never counted as shortcuts.",
                     "仅统计 Command / Control 组合键，按应用汇总。仅 Option 的输入、Dead Key 和普通文字不会被当作快捷键。"))
                .font(.callout).foregroundStyle(.secondary)

            if combos.isEmpty {
                Text(loc("No shortcuts recorded yet.", "尚未记录快捷键。")).foregroundStyle(.secondary)
            } else {
                Table(combos) {
                    TableColumn(loc("Shortcut", "组合键")) { row in Text(row.display) }
                    TableColumn(loc("Count (7 days)", "次数（7 天）")) { row in Text("\(row.count)") }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let window = DateBuckets.rollingWindow(endingAt: Date(), days: 7, timeZone: .current)
        let stats = (try? AppController.shared.store.comboStats(
            from: window.buckets.first ?? "", to: window.buckets.last ?? "")) ?? []
        var totals: [String: Int] = [:]
        for stat in stats { totals[stat.comboID, default: 0] += stat.count }
        combos = totals
            .map { ComboRow(id: $0.key,
                            display: KeyComboCodec.decode($0.key)?.displayString ?? $0.key,
                            count: $0.value) }
            .sorted { $0.count > $1.count }
    }
}
