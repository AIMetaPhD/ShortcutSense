import SwiftUI
import ShortcutSenseCore

/// The compact menu-bar panel (`09_UI_UX_PRODUCT_REQUIREMENTS.md` §2.1).
///
/// 380 pt wide, scrollable, and every control does something real: Open Dashboard
/// brings up the window, Pause toggles the pipeline, Settings selects the Settings
/// screen. Nothing here is a placeholder.
struct MenuBarPanel: View {
    @ObservedObject var model: TodayModel
    let onOpenDashboard: (_ section: RootView.Section) -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            header

            if let metrics = model.metrics {
                compactToday(metrics)
                if let card = model.pendingRecommendation {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L.t("nav.opportunities")).font(Theme.Font.cardTitle)
                        RecommendationSummaryInline(card: card)
                    }
                }
            } else {
                EmptyStateView(symbol: "hourglass", title: L.t("common.empty"))
            }

            if model.status == .permissionsRequired {
                permissionsCallout
            }

            Divider()
            actions
        }
        .padding(Theme.Spacing.medium)
        .frame(width: Theme.Layout.popoverWidth)
        .frame(maxHeight: Theme.Layout.popoverMaxHeight, alignment: .top)
        .background(.background)
        .onAppear { model.reload(force: true) }
    }

    private var header: some View {
        HStack {
            Image(systemName: "command")
                .foregroundStyle(Theme.accent)
            Text(L.t("app.name")).font(.system(size: 14, weight: .semibold))
            Spacer()
            StatusPill(status: model.status)
        }
    }

    private func compactToday(_ metrics: TodayMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metrics.totalKeypresses.formatted())
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(L.t("today.heroCaption"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.Spacing.small) {
                smallStat(L.t("today.kpi.shortcutUses"), metrics.shortcutUses)
                smallStat(L.t("today.kpi.appsUsed"), metrics.appsUsed)
                smallStat(L.t("today.kpi.managed"), metrics.managedHotkeyTriggers)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func smallStat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.system(size: 16, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissionsCallout: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.lock.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(L.isChinese
                     ? "需要「输入监控」权限才能统计按键。"
                     : "Input Monitoring is required to count keystrokes.")
                    .font(Theme.Font.caption)
                Button(L.t("perm.openSettings")) {
                    Permissions.openInputMonitoringSettings()
                }
                .buttonStyle(.link)
                .font(Theme.Font.caption)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            Button {
                onOpenDashboard(.today)
            } label: {
                Label(L.isChinese ? "打开仪表盘" : "Open Dashboard", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 6) {
                Button {
                    Task { @MainActor in
                        AppController.shared.isPaused.toggle()
                        model.reload(force: true)
                    }
                } label: {
                    Label(AppController.shared.isPaused ? L.t("status.collecting") : L.t("status.paused"),
                          systemImage: AppController.shared.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onOpenDashboard(.settings)
                } label: {
                    Label(L.t("nav.settings"), systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.regular)

            Button(L.isChinese ? "退出 ShortcutSense" : "Quit ShortcutSense", action: onQuit)
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }
}
