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

    enum Section: String, CaseIterable, Identifiable {
        case today = "Today"
        case shortcuts = "Shortcuts"
        case opportunities = "Opportunities"
        case conflicts = "Conflict Check"
        case weekly = "Weekly Review"
        case settings = "Settings"

        var id: String { rawValue }

        var localized: String {
            switch self {
            case .today: return loc("Today", "今日")
            case .shortcuts: return loc("Shortcuts", "快捷键")
            case .opportunities: return loc("Opportunities", "推荐")
            case .conflicts: return loc("Conflict Check", "冲突检查")
            case .weekly: return loc("Weekly Review", "每周回顾")
            case .settings: return loc("Settings", "设置")
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                NavigationLink(value: section) { Text(section.localized) }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                switch selection {
                case .today: TodayView()
                case .shortcuts: ShortcutsView()
                case .opportunities: OpportunitiesView()
                case .conflicts: ConflictView()
                case .weekly: WeeklyView()
                case .settings: SettingsView()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 780, minHeight: 520)
    }
}

// MARK: - Today

@MainActor
struct TodayView: View {
    @State private var activity: [DailyAppActivity] = []
    @State private var paused = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(loc("Today", "今日")).font(.largeTitle.bold())
                    Spacer()
                    Toggle(loc("Pause collection", "暂停采集"), isOn: Binding(
                        get: { paused },
                        set: { paused = $0; AppController.shared.isPaused = $0; reload() }))
                        .toggleStyle(.switch)
                }

                Text(loc("ShortcutSense stores only daily totals per application. It never stores what you typed, window titles, URLs, clipboard contents or passwords.",
                         "ShortcutSense 仅按应用保存每日汇总。不会保存你输入的内容、窗口标题、网址、剪贴板或密码。"))
                    .font(.callout).foregroundStyle(.secondary)

                Divider()

                if activity.isEmpty {
                    Text(loc("No data yet. Grant Input Monitoring to begin.",
                             "暂无数据。授权“输入监控”后开始采集。"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activity, id: \.bundleID) { row in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.bundleID).font(.headline)
                                Text(loc("Anonymous keystrokes: \(row.totalAnonymousKeystrokes)",
                                         "匿名按键总数：\(row.totalAnonymousKeystrokes)"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(loc("Unknown origin: \(row.unknownOriginActivations)",
                                         "来源未知：\(row.unknownOriginActivations)"))
                                Text(loc("Keyboard navigation: \(row.observedKeyboardNavigation)",
                                         "键盘导航：\(row.observedKeyboardNavigation)"))
                                Text(loc("Managed hotkey: \(row.managedHotkeyActivations)",
                                         "本应用热键：\(row.managedHotkeyActivations)"))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let controller = AppController.shared
        paused = controller.isPaused
        let today = DateBuckets.bucket(for: Date(), timeZone: .current)
        activity = (try? controller.store.dailyActivity(from: today, to: today)) ?? []
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
