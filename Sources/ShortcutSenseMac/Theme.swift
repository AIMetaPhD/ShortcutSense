import SwiftUI
import ShortcutSenseCore

/// Design tokens for the dashboard.
///
/// Kept in one place so the whole app reads as one product rather than six screens
/// that happen to share a window. Values are chosen for macOS: system font, SF
/// Symbols, grouped material cards, and a single blue accent.
enum Theme {
    // MARK: Palette

    /// Primary accent. Deliberately one hue family: the blue hero, the KPI sparkline
    /// and the selected sidebar row all derive from it.
    static let accent = Color(red: 0.16, green: 0.42, blue: 0.92)
    static let accentSoft = Color(red: 0.16, green: 0.42, blue: 0.92).opacity(0.12)

    /// Sequential ramp for the shortcut heatmap. Monotonic in lightness so the scale
    /// survives greyscale and the common forms of colour-vision deficiency; intensity
    /// never encodes anything except "more presses of this combination".
    static let heatRamp: [Color] = [
        Color(red: 0.16, green: 0.42, blue: 0.92).opacity(0.10),
        Color(red: 0.16, green: 0.42, blue: 0.92).opacity(0.28),
        Color(red: 0.16, green: 0.42, blue: 0.92).opacity(0.50),
        Color(red: 0.16, green: 0.42, blue: 0.92).opacity(0.72),
        Color(red: 0.16, green: 0.42, blue: 0.92).opacity(0.95),
    ]

    static func heat(_ intensity: Double) -> Color {
        guard intensity > 0 else { return Color.secondary.opacity(0.08) }
        let index = min(heatRamp.count - 1, max(0, Int(intensity * Double(heatRamp.count - 1) + 0.5)))
        return heatRamp[index]
    }

    /// Status colours. Each carries a symbol as well, because colour alone is not an
    /// accessible signal.
    static func statusColor(_ status: ConflictStatus) -> Color {
        switch status {
        case .occupied: return .red
        case .potentialConflict: return .orange
        case .noKnownConflict: return .green
        case .unknown: return .secondary
        }
    }

    static func statusSymbol(_ status: ConflictStatus) -> String {
        switch status {
        case .occupied: return "xmark.octagon.fill"
        case .potentialConflict: return "exclamationmark.triangle.fill"
        case .noKnownConflict: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    // MARK: Metrics

    enum Radius {
        static let card: CGFloat = 14
        static let control: CGFloat = 8
        static let pill: CGFloat = 999
    }

    enum Spacing {
        static let tight: CGFloat = 6
        static let small: CGFloat = 10
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let section: CGFloat = 28
    }

    enum Layout {
        static let dashboardMin = CGSize(width: 880, height: 620)
        static let dashboardIdeal = CGSize(width: 1040, height: 760)
        static let popoverWidth: CGFloat = 380
        static let popoverMaxHeight: CGFloat = 560
        static let sidebarWidth: CGFloat = 196
    }

    // MARK: Type

    enum Font {
        /// The single large number on the Today hero.
        static let hero = SwiftUI.Font.system(size: 52, weight: .semibold, design: .rounded)
        static let kpi = SwiftUI.Font.system(size: 26, weight: .semibold, design: .rounded)
        static let sectionTitle = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let cardTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 11)
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
    }
}

// MARK: - Localization

/// Two-language catalogue. Every user-visible string goes through `L.t`, so a missing
/// translation is a visible key rather than a silent English leak.
enum L {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true
    }

    static func t(_ key: String) -> String {
        isChinese ? (zh[key] ?? en[key] ?? key) : (en[key] ?? key)
    }

    static let en: [String: String] = [
        "app.name": "ShortcutSense",
        "nav.today": "Today",
        "nav.shortcuts": "Shortcuts",
        "nav.opportunities": "Opportunities",
        "nav.conflicts": "Conflict Check",
        "nav.weekly": "Weekly Review",
        "nav.settings": "Settings",

        "status.collecting": "Collecting",
        "status.paused": "Paused",
        "status.permissions": "Permissions required",
        "status.blocked": "Not collecting",

        "today.title": "My Keyboard Habits",
        "today.heroCaption": "anonymous keystrokes today",
        "today.kpi.shortcutUses": "Shortcut uses",
        "today.kpi.appsUsed": "Apps used",
        "today.kpi.managed": "Managed shortcut triggers",
        "today.heatmap": "Shortcut Heatmap",
        "today.heatmapCaption": "Only shortcut combinations are shown. Per-key character counts are unavailable by design.",
        "today.top5": "Top 5 shortcuts",
        "today.timeline": "Activity Timeline",
        "today.timelineFallback": "7-day totals — hourly history is off",
        "today.topApps": "Top Apps",
        "today.topAppsMetric": "Ranked by keystrokes, not by time spent.",
        "today.opportunity": "This week's opportunity",
        "today.empty": "No data for this day yet.",

        "common.empty": "Nothing to show yet",
        "common.apply": "Apply",
        "common.undo": "Undo",
        "common.dismiss": "Dismiss",
        "common.details": "Details",
        "common.cancel": "Cancel",
        "common.retry": "Try again",
        "common.estimated": "estimated",
        "common.measured": "measured",
        "common.preview": "Preview",
        "common.learnMore": "Learn more",
        "metric.keypresses": "Anonymous keystroke count for the selected day. Excluded applications are not counted.",
        "metric.shortcutUses": "Normalized Command/Control combinations recorded that day. Ordinary typing is never included.",
        "metric.appsUsed": "Applications with at least one collected signal that day. Not every app you opened.",
        "metric.managedTriggers": "Presses of hotkeys ShortcutSense registered, counted inside its own handler.",
        "metric.topApps": "Ranked by keystrokes, not by time spent.",
        "metric.heatmap": "Only shortcut combinations are shown. Per-key character counts are unavailable by design.",
        "chart.less": "less",
        "chart.more": "more",
        "chart.dayShortcut": "shortcut uses",

        "perm.inputMonitoring": "Input Monitoring",
        "perm.accessibility": "Accessibility",
        "perm.granted": "Granted",
        "perm.denied": "Not granted",
        "perm.request": "Request",
        "perm.openSettings": "Open Settings",
    ]

    static let zh: [String: String] = [
        "app.name": "ShortcutSense",
        "nav.today": "今日",
        "nav.shortcuts": "快捷键",
        "nav.opportunities": "推荐",
        "nav.conflicts": "冲突检查",
        "nav.weekly": "每周回顾",
        "nav.settings": "设置",

        "status.collecting": "采集中",
        "status.paused": "已暂停",
        "status.permissions": "需要授权",
        "status.blocked": "未采集",

        "today.title": "我的键盘习惯",
        "today.heroCaption": "今日匿名按键数",
        "today.kpi.shortcutUses": "快捷键触发次数",
        "today.kpi.appsUsed": "已活跃应用数",
        "today.kpi.managed": "已采用热键触发",
        "today.heatmap": "快捷键热力图",
        "today.heatmapCaption": "仅显示快捷键组合。按设计不提供单键字符统计。",
        "today.top5": "最常用 5 个快捷键",
        "today.timeline": "活动时间线",
        "today.timelineFallback": "近 7 天总计 —— 小时级记录未开启",
        "today.topApps": "应用排行",
        "today.topAppsMetric": "按按键数排序，不是使用时长。",
        "today.opportunity": "本周优化机会",
        "today.empty": "今天还没有数据。",

        "common.empty": "暂无内容",
        "common.apply": "应用",
        "common.undo": "撤销",
        "common.dismiss": "忽略",
        "common.details": "详情",
        "common.cancel": "取消",
        "common.retry": "重试",
        "common.estimated": "预估",
        "common.measured": "实测",
        "common.preview": "预览",
        "common.learnMore": "了解更多",
        "metric.keypresses": "所选日期的匿名按键总数。已排除的应用不计入。",
        "metric.shortcutUses": "当天记录到的规范化 Command / Control 组合键次数。不含普通打字。",
        "metric.appsUsed": "当天至少有一个采集信号的应用数。不代表你打开过的全部应用。",
        "metric.managedTriggers": "ShortcutSense 自己注册的热键被按下的次数，在 handler 内统计。",
        "metric.topApps": "按按键数排序，不是使用时长。",
        "metric.heatmap": "仅显示快捷键组合。按设计不提供单键字符统计。",
        "chart.less": "少",
        "chart.more": "多",
        "chart.dayShortcut": "次快捷键",

        "perm.inputMonitoring": "输入监控",
        "perm.accessibility": "辅助功能",
        "perm.granted": "已授权",
        "perm.denied": "未授权",
        "perm.request": "申请",
        "perm.openSettings": "打开设置",
    ]
}
