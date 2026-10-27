import SwiftUI
import ShortcutSenseCore

/// Weekly Review. A report is `Preview` until seven full days of collection exist,
/// and the coverage line always states the real period and generation time.
@MainActor
final class WeeklyModel: ObservableObject {
    @Published private(set) var report: WeeklyReport?
    @Published private(set) var error: String?
    @Published private(set) var firstCollectionAt: Date?
    /// Elapsed time since the first collection. **Not** the number of days that have
    /// data: a Mac that was asleep for a week has elapsed days but no records.
    @Published private(set) var daysSinceFirstCollection: Double = 0
    /// Distinct day buckets that actually hold a record.
    @Published private(set) var daysWithData: Int = 0
    @Published var generating = false

    func reload() {
        let service = AppController.shared.weeklyService
        firstCollectionAt = AppController.shared.store.firstCollectionStartedAt()
        if let first = firstCollectionAt {
            daysSinceFirstCollection = Date().timeIntervalSince(first) / 86_400
        } else {
            daysSinceFirstCollection = 0
        }
        let window = DateBuckets.rollingWindow(
            endingAt: Date(), days: 7,
            timeZone: AppController.shared.store.collectionTimeZone)
        let rows = (try? AppController.shared.store.dailyActivity(
            from: window.buckets.first ?? "", to: window.buckets.last ?? "")) ?? []
        daysWithData = Set(rows.filter {
            $0.totalAnonymousKeystrokes > 0 || $0.observedKeyboardNavigation > 0
                || $0.unknownOriginActivations > 0 || $0.managedHotkeyActivations > 0
        }.map(\.date)).count
        do {
            report = try service.generateIfNeeded().report
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    func generateNow() {
        generating = true
        defer { generating = false }
        reload()
    }
}

struct WeeklyDashboard: View {
    @ObservedObject var model: WeeklyModel
    @StateObject private var ai = AIAnalysisModel()
    @State private var analysisTarget: RecommendationCardModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                HStack {
                    Text(L.t("nav.weekly")).font(.system(size: 24, weight: .bold))
                    Spacer()
                    Button(L.isChinese ? "立即生成" : "Generate now") { model.generateNow() }
                        .buttonStyle(.bordered)
                }

                if let error = model.error {
                    Card { Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.caption).foregroundStyle(.red) }
                }

                if let report = model.report {
                    if report.isPreview {
                        previewBanner
                    }
                    summary(report)
                    if !report.adoptedShortcuts.isEmpty {
                        adopted(report)
                    }
                } else {
                    Card { EmptyStateView(symbol: "calendar", title: L.t("common.empty")) }
                }

                aiCard
                coverageCard
            }
            .padding(Theme.Spacing.large)
        }
        .background(.background)
        .onAppear { model.reload() }
    }

    private var previewBanner: some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t("common.preview")).font(Theme.Font.sectionTitle)
                    Text(L.isChinese
                         ? "真实采集不足 7 天。下面的数字不是一周的结果，也不会被描述成一周的结果。"
                         : "Fewer than 7 days of real collection. The numbers below are not a weekly result and are not described as one.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func summary(_ report: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(report.periodStart) → \(report.periodEnd)")
                        .font(.system(size: 16, weight: .semibold))
                    Text(L.isChinese
                         ? "生成于 \(report.generatedAt.formatted()) —— 实际时间，不是声称的定时执行。"
                         : "Generated at \(report.generatedAt.formatted()) — the real time, not a claimed schedule.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    HStack(spacing: Theme.Spacing.large) {
                        stat(L.isChinese ? "匿名按键" : "Anonymous keystrokes",
                             "\(report.totalAnonymousKeystrokes)")
                        stat(L.isChinese ? "待处理推荐" : "Pending recommendations",
                             "\(report.newCandidates)")
                    }
                }
            }

            if !report.topCombos.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionHeader(title: L.isChinese ? "最常用快捷键" : "Most used shortcuts")
                        ForEach(report.topCombos, id: \.comboID) { combo in
                            HStack {
                                Text(combo.display).font(Theme.Font.mono)
                                Spacer()
                                Text("\(combo.count)").font(Theme.Font.mono).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    private func adopted(_ report: WeeklyReport) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(
                    title: L.isChinese ? "已采纳热键（实测）" : "Adopted shortcuts (measured)",
                    subtitle: L.isChinese
                        ? "触发次数在 ShortcutSense 自己的 handler 内统计；成功激活另计，两者不必相等。"
                        : "Trigger counts are recorded inside ShortcutSense's own handler. Successful activations are counted separately and need not match.")
                ForEach(report.adoptedShortcuts, id: \.shortcutID) { adopted in
                    HStack {
                        Text(adopted.displayCombo).font(Theme.Font.mono)
                        Text("→ \(DisplayName.app(adopted.targetBundleID))")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(L.isChinese
                             ? "\(adopted.triggerCount) 次触发 / \(adopted.successfulActivations) 次确认激活"
                             : "\(adopted.triggerCount) presses / \(adopted.successfulActivations) confirmed activations")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(L.isChinese
                     ? "节省的时间标记为“预估”，因为没有测量基准。"
                     : "Time saved is labelled estimated, because there is no measured baseline.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Analysis entry for the current top recommendation. Only offered when there is
    /// a real candidate; it never fabricates a sample to have something to analyse.
    private var aiCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if let target = analysisTarget {
                    AIExplanationPanel(model: ai, request: AIExplanationRequest(card: target))
                } else {
                    SectionHeader(
                        title: L.isChinese ? "本地 AI 分析" : "Local AI analysis",
                        subtitle: L.isChinese
                            ? "当前没有可分析的候选。推荐需要至少 7 次激活、分布在 2 个不同日期；没有样本时不会生成分析。"
                            : "There is no candidate to analyse. Recommendations need at least 7 activations across 2 different days; without a sample no analysis is produced.")
                }
            }
        }
        .onAppear { loadAnalysisTarget() }
    }

    private func loadAnalysisTarget() {
        guard analysisTarget == nil else { return }
        analysisTarget = (try? RecommendationCardModel.pending())?.first
    }

    private var coverageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.isChinese ? "覆盖范围" : "Coverage").font(Theme.Font.sectionTitle)
                if let first = model.firstCollectionAt {
                    Text(L.isChinese
                         ? "首次采集于 \(first.formatted())，至今 \(String(format: "%.1f", model.daysSinceFirstCollection)) 天。有数据的天数：\(model.daysWithData)。"
                         : "First collection \(first.formatted()); \(String(format: "%.1f", model.daysSinceFirstCollection)) days ago. Days with data: \(model.daysWithData).")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L.isChinese ? "尚未开始采集。" : "Collection has not started.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
                Text(L.isChinese
                     ? "未运行、休眠或离线时不会声称已定时生成；下次启动后会补算，并显示真实生成时间。"
                     : "When the app was not running, asleep or offline, it never claims a scheduled run; it catches up on next launch and shows the real generation time.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Theme.Font.kpi).monospacedDigit()
            Text(title).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
