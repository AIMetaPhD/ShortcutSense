import SwiftUI
import ShortcutSenseCore

enum NSHostingViewFactory {
    @MainActor
    static func makeRootView() -> NSView {
        NSHostingView(rootView: RootView())
    }
}

/// The dashboard shell: sidebar navigation plus the selected screen.
///
/// Every screen is bound to a view model that reads the real store; there is no
/// sample-data path outside previews.
@MainActor
struct RootView: View {
    @State private var selection: Section = .today
    @StateObject private var today = TodayModel()
    @StateObject private var shortcuts = ShortcutsModel()
    @StateObject private var opportunities = OpportunitiesModel()
    @StateObject private var conflicts = ConflictModel()
    @StateObject private var weekly = WeeklyModel()
    @StateObject private var settings = SettingsModel()
    @State private var showWelcome = false

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

        /// ⌘1…⌘6 navigate; the number is also the accessibility shortcut hint.
        var number: Int {
            switch self {
            case .today: return 1
            case .shortcuts: return 2
            case .opportunities: return 3
            case .conflicts: return 4
            case .weekly: return 5
            case .settings: return 6
            }
        }

        var keyEquivalent: KeyEquivalent {
            switch number {
            case 1: return "1"
            case 2: return "2"
            case 3: return "3"
            case 4: return "4"
            case 5: return "5"
            default: return "6"
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
        .sheet(isPresented: $showWelcome) {
            WelcomeSheet(
                onOpenSettings: {
                    showWelcome = false
                    selection = .settings
                    settings.refresh()
                },
                onDismiss: { showWelcome = false })
        }
        .background(navigationShortcuts)
        .onAppear {
            showWelcome = !UserDefaults.standard.bool(forKey: "hasSeenWelcome")
        }
        .onChange(of: selection) { _, newValue in
            // Re-read on navigation so a screen never shows stale rows.
            switch newValue {
            case .today: today.reload(force: true)
            case .shortcuts: shortcuts.reload()
            case .opportunities: opportunities.reload()
            case .conflicts: conflicts.evaluate()
            case .weekly: weekly.reload()
            case .settings: settings.refresh()
            }
        }
    }

    /// Hidden buttons that provide ⌘1…⌘6. Using real buttons rather than a key handler
    /// keeps the shortcuts discoverable to the system and to assistive technology.
    private var navigationShortcuts: some View {
        ZStack {
            ForEach(Section.allCases) { section in
                Button("") { selection = section }
                    .keyboardShortcut(section.keyEquivalent, modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
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
                        Spacer(minLength: 0)
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
                .accessibilityLabel(section.title)
                .accessibilityHint("⌘\(section.number)")
                .accessibilityAddTraits(selection == section ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
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
        case .today: TodayDashboard(model: today)
        case .shortcuts: ShortcutsDashboard(model: shortcuts)
        case .opportunities: OpportunitiesDashboard(model: opportunities)
        case .conflicts: ConflictDashboard(model: conflicts)
        case .weekly: WeeklyDashboard(model: weekly)
        case .settings: SettingsDashboard(model: settings)
        }
    }
}

/// First-run explanation. States exactly what is collected before any permission is
/// requested, so consent is informed rather than a reflex.
struct WelcomeSheet: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("app.name")).font(.system(size: 20, weight: .bold))
                    Text(L.isChinese ? "隐私优先的快捷键助手" : "A privacy-first shortcut coach")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.isChinese ? "它会记录什么" : "What it records")
                        .font(Theme.Font.sectionTitle)
                    ForEach(recorded, id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle.fill")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.isChinese ? "它绝不记录什么" : "What it never records")
                        .font(Theme.Font.sectionTitle)
                    ForEach(notRecorded, id: \.self) { line in
                        Label(line, systemImage: "xmark.circle.fill")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(L.isChinese
                 ? "只有你授予「输入监控」后才会开始统计。随时可以在菜单栏或设置里暂停。"
                 : "Nothing is counted until you grant Input Monitoring. You can pause at any time from the menu bar or Settings.")
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(L.isChinese ? "稍后再说" : "Not now", action: onDismiss)
                Spacer()
                Button(L.isChinese ? "去授权" : "Grant access") {
                    UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
                    onOpenSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 520)
        .onDisappear {
            UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
        }
    }

    private var recorded: [String] {
        L.isChinese
            ? ["每天的匿名按键总数，按应用分组",
               "Command / Control 组合键的次数",
               "应用被切换到前台的次数，以及能否判断来源",
               "你采用的热键，以及它被真实按下的次数"]
            : ["Daily anonymous keystroke totals, grouped by app",
               "Counts of Command / Control combinations",
               "How often an app came to the front, and whether the origin was knowable",
               "Hotkeys you adopted, and how often they were really pressed"]
    }

    private var notRecorded: [String] {
        L.isChinese
            ? ["你输入的任何文字或按键序列",
               "窗口标题、网址、剪贴板",
               "密码，或安全输入框中的任何内容",
               "单个字母的按键频率"]
            : ["Any text you type, or any key sequence",
               "Window titles, URLs, clipboard",
               "Passwords, or anything typed in a secure field",
               "Per-letter key frequency"]
    }
}
