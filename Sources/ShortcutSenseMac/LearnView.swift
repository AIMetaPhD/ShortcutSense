import SwiftUI
import ShortcutSenseCore

/// The Learn / workspace screen.
///
/// Three sections, in the order they become useful:
/// 1. T1 opt-in, stated plainly, with what it records.
/// 2. Manual mark: works immediately, before any threshold is met.
/// 3. Automatic suggestions: only appear once real evidence exists.
struct LearnDashboard: View {
    @ObservedObject var model: PatternModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                Text(L.isChinese ? "学习与工作区" : "Learn & Workspaces")
                    .font(.system(size: 24, weight: .bold))

                if let error = model.readError {
                    Card { Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.caption).foregroundStyle(.red) }
                }
                if let error = model.actionError {
                    Card { Label(error, systemImage: "xmark.octagon.fill")
                        .font(Theme.Font.caption).foregroundStyle(.red) }
                }

                t1Section
                if model.t1Enabled {
                    manualMarkSection
                    workspaceSection
                    learnSection
                }
            }
            .padding(Theme.Spacing.large)
        }
        .background(.background)
        .onAppear { model.reload() }
    }

    // MARK: T1

    private var t1Section: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(
                    title: L.isChinese ? "受控行为记录（T1）" : "Controlled activity recording (T1)",
                    subtitle: L.isChinese
                        ? "默认关闭。开启后只记录：应用切到前台、你点击的静态菜单命令、以及你手动标记的项目。不记录窗口标题、网址、文件名或任何输入内容。原始记录 14 天后自动清理。"
                        : "Off by default. When on, it records only: an application coming to the front, static menu commands you click, and items you mark yourself. It records no window titles, URLs, file names or typed content. Raw rows are pruned after 14 days.")
                Toggle(L.isChinese ? "开启受控记录" : "Enable controlled recording",
                       isOn: Binding(get: { model.t1Enabled },
                                     set: { model.setT1Enabled($0) }))
                if model.t1Enabled {
                    HStack(spacing: 8) {
                        Button(L.isChinese ? "清除 T1 历史" : "Clear T1 history") {
                            try? AppController.shared.store.clearT1()
                            model.reload()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Text(L.isChinese
                             ? "只清除自动观测的记录；你手动标记的项目会保留。"
                             : "Removes automatically observed rows; items you marked yourself are kept.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: Manual mark

    private var manualMarkSection: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(
                    title: L.isChinese ? "手动标记" : "Mark an item yourself",
                    subtitle: L.isChinese
                        ? "不需要等到 7 次。打开你想标记的 App 的菜单，让那个 App 在最前面，然后在下面选一项。标记只表示你关心它，不代表点击次数。"
                        : "No need to wait for seven clicks. Open the app you want to mark, bring it to the front, then pick an item below. A mark means you care about it; it is not a click count.")
                if let app = model.frontmostAppName {
                    HStack(spacing: 8) {
                        Text(L.isChinese ? "当前前台：" : "Frontmost: ")
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                        Text(app).font(Theme.Font.cardTitle)
                        Spacer()
                        Button(L.isChinese ? "刷新" : "Refresh") { model.loadFrontmostMenu() }
                            .buttonStyle(.link).font(Theme.Font.caption)
                    }
                }
                if model.menuItemsInFrontmostApp.isEmpty {
                    EmptyStateView(
                        symbol: "menubar.rectangle",
                        title: L.isChinese ? "没有可标记的菜单项" : "No menu items to mark",
                        message: L.isChinese
                            ? "请让 Finder、Chrome 或 Safari 在最前面，然后点刷新。"
                            : "Bring Finder, Chrome or Safari to the front, then refresh.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.menuItemsInFrontmostApp) { item in
                                HStack {
                                    Text(item.label).font(Theme.Font.caption)
                                        .lineLimit(1)
                                    if let display = item.shortcutDisplay {
                                        Text(display)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Theme.accent)
                                    }
                                    Spacer()
                                    Button(L.isChinese ? "标记" : "Mark") { model.mark(item) }
                                        .buttonStyle(.link)
                                        .font(Theme.Font.caption)
                                }
                                .padding(.vertical, 1)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
        }
    }

    // MARK: Workspaces

    private var workspaceSection: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(
                    title: L.isChinese ? "重复的应用组合" : "Repeated application groups",
                    subtitle: L.isChinese
                        ? "同一小时内以相同顺序出现的 2–3 个应用，且出现在至少 2 个不同日期。只保证启动/前置这些应用，不承诺窗口自动布局。"
                        : "Two or three apps that came to the front in the same hour on at least two different days. Only launching and focusing those apps is promised — no window layout.")
                if model.workspaceCards.isEmpty {
                    EmptyStateView(symbol: "square.grid.2x2",
                                   title: L.isChinese ? "还没有重复的应用组合" : "No repeated groups yet",
                                   message: L.isChinese
                                       ? "继续正常使用，满足条件后会自动出现。"
                                       : "Keep using your Mac normally; a group appears once the evidence exists.")
                } else {
                    ForEach(model.workspaceCards) { card in
                        WorkspaceRow(card: card) { model.applyWorkspace(card) }
                    }
                }
            }
        }
    }

    // MARK: Learn

    private var learnSection: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(
                    title: L.isChinese ? "可以学的快捷键" : "Shortcuts you could learn",
                    subtitle: L.isChinese
                        ? "你反复点击的菜单项，其中一些已经有现成快捷键。这里告诉你它们是什么。"
                        : "Menu items you keep clicking, some of which already have a shortcut. This tells you which.")
                if model.learnCards.isEmpty {
                    EmptyStateView(symbol: "lightbulb",
                                   title: L.isChinese ? "还没有足够证据" : "Not enough evidence yet",
                                   message: L.isChinese
                                       ? "自动学习需要 7 次点击、分布在 2 个不同日期。在那之前，可以用上面的手动标记。"
                                       : "Automatic Learn needs 7 clicks across 2 different days. Until then, use the manual mark above.")
                } else {
                    ForEach(model.learnCards) { card in
                        LearnRow(card: card)
                    }
                }
            }
        }
    }
}

struct WorkspaceRow: View {
    let card: PatternModel.WorkspaceCard
    let onApply: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 3) {
                Text(card.names.joined(separator: " + "))
                    .font(Theme.Font.cardTitle)
                Text(L.isChinese
                     ? "\(card.activeDays) 个不同日期出现，共 \(card.occurrences) 次"
                     : "Seen on \(card.activeDays) different days, \(card.occurrences) times")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                if let combo = card.proposedCombo {
                    HStack(spacing: 6) {
                        Text(combo.displayString).font(Theme.Font.mono)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Theme.accentSoft, in: Capsule())
                        if let conflict = card.conflict {
                            ConflictBadge(conflict: conflict)
                        }
                    }
                }
            }
            Spacer()
            Button(L.t("common.apply"), action: onApply)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(card.conflict?.isEligibleForAutomaticApply != true)
        }
        .padding(.vertical, 2)
    }
}

struct LearnRow: View {
    let card: PatternModel.LearnCard

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(card.appName) · \(card.label)")
                    .font(Theme.Font.cardTitle)
                if let count = card.observedCount {
                    Text(L.isChinese
                         ? "点击 \(count) 次，分布在 \(card.activeDays) 天"
                         : "Clicked \(count) times across \(card.activeDays) days")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L.isChinese
                         ? "根据你的手动标记 —— 不声称点击次数"
                         : "Based on your manual mark — no click count is claimed")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
                if let display = card.shortcutDisplay {
                    Text(L.isChinese
                         ? "这个命令已有快捷键：\(display)"
                         : "This command already has a shortcut: \(display)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.accent)
                } else {
                    Text(L.isChinese
                         ? "这个命令没有快捷键。macOS 不允许本应用替其他应用添加快捷键，需要在系统设置里手动添加。"
                         : "This command has no shortcut. macOS does not let one app add shortcuts to another; add it in System Settings.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
