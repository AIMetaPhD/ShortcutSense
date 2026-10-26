import SwiftUI
import ShortcutSenseCore

/// Opportunities list plus a detail view.
///
/// The apply path goes through `ShortcutActionManager`, so a card only shows
/// "enabled" when the OS actually accepted the registration — not when the button
/// was clicked.
@MainActor
final class OpportunitiesModel: ObservableObject {
    @Published private(set) var cards: [RecommendationCardModel] = []
    @Published private(set) var registered: [RegisteredShortcut] = []
    @Published var actionError: String?
    @Published var selected: RecommendationCardModel?

    func reload() {
        cards = RecommendationCardModel.pending()
        registered = (try? AppController.shared.store.registeredShortcuts(activeOnly: true)) ?? []
    }

    func apply(_ card: RecommendationCardModel) {
        actionError = nil
        guard let combo = card.proposedCombo else {
            actionError = L.isChinese ? "这张卡没有可应用的组合键。" : "This card has no applicable combination."
            return
        }
        let controller = AppController.shared
        let now = DateBuckets.iso8601(Date())
        let recommendation = Recommendation(
            id: card.id, bundleID: card.bundleID, kind: card.kind, targetID: "launch",
            proposedCombo: combo.comboID, confidence: card.confidence,
            status: .pending, createdAt: now, cooldownUntil: nil, updatedAt: now)
        do {
            try controller.store.upsertRecommendation(recommendation)
            // Re-check immediately before registering: menus and other apps change.
            let fresh = ConflictResolver().evaluate(
                combo, inputs: controller.conflictInputs(targetBundleID: card.bundleID))
            _ = try controller.apply(recommendation: recommendation, combo: combo, conflict: fresh)
            reload()
        } catch {
            actionError = "\(error)"
        }
    }

    func dismiss(_ card: RecommendationCardModel) {
        let controller = AppController.shared
        let now = DateBuckets.iso8601(Date())
        let cooldown = Calendar.current.date(
            byAdding: .day, value: RecommendationThresholds.dismissalCooldownDays, to: Date())
        let recommendation = Recommendation(
            id: card.id, bundleID: card.bundleID, kind: card.kind, targetID: "launch",
            proposedCombo: card.proposedCombo?.comboID, confidence: card.confidence,
            status: .dismissed, createdAt: now, cooldownUntil: cooldown.map(DateBuckets.iso8601),
            updatedAt: now)
        try? controller.store.upsertRecommendation(recommendation)
        reload()
    }

    func undo(_ shortcut: RegisteredShortcut) {
        actionError = nil
        do {
            try AppController.shared.undo(shortcutID: shortcut.id)
            reload()
        } catch {
            actionError = "\(error)"
        }
    }
}

struct OpportunitiesDashboard: View {
    @ObservedObject var model: OpportunitiesModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                Text(L.t("nav.opportunities"))
                    .font(.system(size: 24, weight: .bold))

                if let error = model.actionError {
                    Card {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.red)
                    }
                }

                if !model.registered.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                            SectionHeader(title: L.isChinese ? "已启用的热键" : "Active shortcuts")
                            ForEach(model.registered, id: \.id) { shortcut in
                                HStack {
                                    Text(shortcut.displayCombo).font(Theme.Font.mono)
                                    Text("→ \(DisplayName.app(shortcut.targetBundleID))")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button(L.t("common.undo")) { model.undo(shortcut) }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }

                if model.cards.isEmpty {
                    Card {
                        EmptyStateView(
                            symbol: "sparkles",
                            title: L.isChinese ? "暂无推荐" : "No recommendations yet",
                            message: L.isChinese
                                ? "至少需要在 2 个不同日期累计激活 7 次，才会给出建议。"
                                : "ShortcutSense needs at least 7 activations on 2 different days before suggesting a shortcut.")
                    }
                } else {
                    ForEach(model.cards) { card in
                        OpportunityCard(card: card,
                                        onApply: { model.apply(card) },
                                        onDismiss: { model.dismiss(card) },
                                        onDetails: { model.selected = card })
                    }
                }
            }
            .padding(Theme.Spacing.large)
        }
        .background(.background)
        .onAppear { model.reload() }
        .sheet(item: $model.selected) { card in
            OpportunityDetail(card: card,
                              onApply: { model.apply(card); model.selected = nil },
                              onDismiss: { model.dismiss(card); model.selected = nil })
        }
    }
}

struct OpportunityCard: View {
    let card: RecommendationCardModel
    let onApply: () -> Void
    let onDismiss: () -> Void
    let onDetails: () -> Void

    private var kindLabel: String {
        switch card.kind {
        case .launchFocus: return L.isChinese ? "启动/切换应用" : "Launch / Focus app"
        case .learn: return L.isChinese ? "学习已有快捷键" : "Learn existing shortcut"
        case .configure: return L.isChinese ? "引导设置" : "Guided setup"
        }
    }

    private var confidenceLabel: String {
        switch card.confidence {
        case .verified: return L.isChinese ? "已验证" : "Verified"
        case .heuristic: return L.isChinese ? "启发式推断" : "Heuristic"
        case .unknown: return L.isChinese ? "来源未知" : "Unknown origin"
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack {
                    Image(systemName: "app.fill").foregroundStyle(Theme.accent)
                    Text(card.appName).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(kindLabel)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }

                // The origin is genuinely unknown; the copy must not imply a click.
                Text(evidenceLine)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if let combo = card.proposedCombo {
                    HStack(spacing: 6) {
                        Text(combo.displayString)
                            .font(Theme.Font.mono)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.accentSoft, in: Capsule())
                        ConflictBadge(conflict: card.conflict)
                    }
                }

                HStack(spacing: Theme.Spacing.small) {
                    Text(confidenceLabel)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L.t("common.details"), action: onDetails)
                        .buttonStyle(.link)
                    Button(L.t("common.dismiss"), action: onDismiss)
                    if card.proposedCombo != nil {
                        Button(L.t("common.apply"), action: onApply)
                            .buttonStyle(.borderedProminent)
                            .disabled(!card.conflict.isEligibleForAutomaticApply)
                    }
                }
            }
        }
    }

    private var evidenceLine: String {
        guard let count = card.observedCount, let days = card.activeDays else {
            return L.isChinese
                ? "根据你的手动标记。不声称观测到的点击次数。"
                : "Based on your manual mark. No observed click count is claimed."
        }
        return L.isChinese
            ? "7 天内激活 \(count) 次，分布在 \(days) 个不同日期。来源未知——可能是鼠标、Dock、启动器或系统自动切换。"
            : "\(count) activations in 7 days across \(days) different days. The origin is unknown — it could be the mouse, the Dock, a launcher or automatic focus."
    }
}

struct ConflictBadge: View {
    let conflict: ConflictResult

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Theme.statusSymbol(conflict.status))
                .font(.system(size: 9))
            Text(label)
                .font(Theme.Font.caption)
        }
        .foregroundStyle(Theme.statusColor(conflict.status))
        .accessibilityLabel(label)
    }

    private var label: String {
        switch conflict.status {
        case .occupied: return L.isChinese ? "已被占用" : "Occupied"
        case .potentialConflict: return L.isChinese ? "潜在冲突" : "Potential conflict"
        case .noKnownConflict: return L.isChinese ? "未发现已知冲突" : "No known conflict"
        case .unknown: return L.isChinese ? "未知" : "Unknown"
        }
    }
}

struct OpportunityDetail: View {
    let card: RecommendationCardModel
    let onApply: () -> Void
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack {
                Text(card.appName).font(.system(size: 20, weight: .bold))
                Spacer()
                Button(L.t("common.cancel")) { dismiss() }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.isChinese ? "为什么推荐" : "Why this is recommended")
                        .font(Theme.Font.sectionTitle)
                    Text(explanation)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let combo = card.proposedCombo {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L.isChinese ? "拟议组合键" : "Proposed combination")
                            .font(Theme.Font.sectionTitle)
                        Text(combo.displayString).font(Theme.Font.mono)
                        ConflictBadge(conflict: card.conflict)
                        ForEach(card.conflict.evidence, id: \.detail) { evidence in
                            Text("• \(evidence.source) — \(evidence.detail)")
                                .font(Theme.Font.caption)
                                .foregroundStyle(.secondary)
                        }
                        if card.conflict.evidence.isEmpty {
                            Text(L.isChinese
                                 ? "可读取的来源中未发现占用。这不保证该组合一定空闲。"
                                 : "Nothing found in the sources ShortcutSense can read. That is not a guarantee the combination is free.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.isChinese ? "已知限制" : "Known limitations")
                        .font(Theme.Font.sectionTitle)
                    ForEach(limitations, id: \.self) { line in
                        Text("• \(line)")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Button(L.t("common.dismiss"), action: onDismiss)
                Spacer()
                if card.proposedCombo != nil {
                    Button(L.t("common.apply")) { onApply(); dismiss() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!card.conflict.isEligibleForAutomaticApply)
                }
            }
            Text(L.isChinese
                 ? "预计效果为 \(L.t("common.estimated"))，不是实测节省时间。真实效果会在采纳后的周报中显示。"
                 : "The expected effect is \(L.t("common.estimated")), not a measured time saving. Real effect appears in the weekly review after adoption.")
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Spacing.large)
        .frame(width: 560)
    }

    private var explanation: String {
        guard let count = card.observedCount, let days = card.activeDays else {
            return L.isChinese
                ? "你手动标记了这个操作。这不是行为统计，只表示你关心它。"
                : "You marked this action manually. That is not a behavioural count; it only shows you care about it."
        }
        return L.isChinese
            ? "\(card.appName) 在 7 天内被切换到前台 \(count) 次，分布在 \(days) 个日期。ShortcutSense 无法判断你是怎么切过去的，所以这个来源标记为未知。"
            : "\(card.appName) came to the front \(count) times in 7 days across \(days) days. ShortcutSense cannot tell how you switched, so the origin is marked unknown."
    }

    private var limitations: [String] {
        var lines: [String] = []
        lines.append(L.isChinese
                     ? "来源未知不等于鼠标点击；也可能来自 Dock、启动器或系统自动切换。"
                     : "Unknown origin does not mean a mouse click; it could be the Dock, a launcher or automatic focus.")
        if card.proposedCombo != nil {
            lines.append(L.isChinese
                         ? "冲突检查只覆盖系统热键、已启用的符号热键和可读取的应用菜单。第三方工具可能占用该组合。"
                         : "The conflict check covers system hotkeys, enabled symbolic hotkeys and readable app menus. A third-party tool may still own the combination.")
        }
        lines.append(L.isChinese
                     ? "ShortcutSense 不会修改其他应用的快捷键设置。"
                     : "ShortcutSense never modifies another application's shortcut settings.")
        return lines
    }
}
