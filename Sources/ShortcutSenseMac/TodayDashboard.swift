import SwiftUI
import ShortcutSenseCore

/// The Today screen described in `09_UI_UX_PRODUCT_REQUIREMENTS.md` §2.2:
/// hero, KPI cards, shortcut heatmap, Top 5, timeline, Top Apps, opportunity callout.
///
/// Every value is read from `DashboardService` on a coalesced timer. There is no
/// sample data path: when the database is empty the view renders its empty states.
@MainActor
final class TodayModel: ObservableObject {
    @Published private(set) var metrics: TodayMetrics?
    @Published private(set) var reloadError: String?
    @Published private(set) var pendingRecommendation: RecommendationCardModel?
    @Published private(set) var status: CollectionStatus = .blocked
    @Published var selectedDate = Date()

    /// Minimum gap between automatic reloads. The capture pipeline writes on the main
    /// thread, so this is about not re-querying SQLite on every keystroke.
    private let minimumReloadInterval: TimeInterval = 2
    private var lastReload = Date.distantPast
    private var timer: Timer?

    func start() {
        reload(force: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reload(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReload) >= minimumReloadInterval else { return }
        lastReload = now

        let controller = AppController.shared
        status = Self.status(for: controller)
        do {
            metrics = try DashboardService.today(
                for: selectedDate, store: controller.store,
                timeZone: controller.store.collectionTimeZone,
                includeHourly: controller.store.hourlyCollectionEnabled)
            reloadError = nil
        } catch {
            reloadError = "\(error)"
        }
        pendingRecommendation = RecommendationCardModel.topPending()
    }

    /// Derived only from observable state, so the label can never claim "Collecting"
    /// while the tap is not running.
    static func status(for controller: AppController) -> CollectionStatus {
        if controller.isPaused { return .paused }
        let snapshot = controller.permissionSnapshot
        if snapshot.inputMonitoring != .granted { return .permissionsRequired }
        if controller.lastTapStatus != .running { return .blocked }
        return .collecting
    }
}

struct TodayDashboard: View {
    @ObservedObject var model: TodayModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                header
                if let error = model.reloadError {
                    errorCard(error)
                }
                if let metrics = model.metrics {
                    hero(metrics)
                    kpis(metrics)
                    heatmapSection(metrics)
                    timelineSection(metrics)
                    topAppsSection(metrics)
                    opportunitySection
                } else {
                    EmptyStateView(symbol: "hourglass", title: L.t("common.empty"))
                }
            }
            .padding(Theme.Spacing.large)
        }
        .background(.background)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L.t("today.title"))
                    .font(.system(size: 24, weight: .bold))
                Text(displayDate)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { @MainActor in
                    AppController.shared.isPaused.toggle()
                    model.reload(force: true)
                }
            } label: {
                Label(AppController.shared.isPaused ? L.t("status.collecting") : L.t("status.paused"),
                      systemImage: AppController.shared.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .help(AppController.shared.isPaused
                  ? "Resume anonymous counting"
                  : "Stop counting; history stays readable")
        }
    }

    private var displayDate: String {
        model.metrics?.date ?? ""
    }

    private func errorCard(_ message: String) -> some View {
        Card {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(Theme.Font.caption)
        }
    }

    private func hero(_ metrics: TodayMetrics) -> some View {
        HeroSummary(value: metrics.totalKeypresses,
                    caption: L.t("today.heroCaption"),
                    status: model.status,
                    date: metrics.date)
    }

    private func kpis(_ metrics: TodayMetrics) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            MetricCard(title: L.t("today.kpi.shortcutUses"),
                       value: metrics.shortcutUses,
                       definition: MetricDefinition.shortcutUses)
            MetricCard(title: L.t("today.kpi.appsUsed"),
                       value: metrics.appsUsed,
                       definition: MetricDefinition.appsUsed)
            MetricCard(title: L.t("today.kpi.managed"),
                       value: metrics.managedHotkeyTriggers,
                       definition: MetricDefinition.managedTriggers)
        }
    }

    private func heatmapSection(_ metrics: TodayMetrics) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                SectionHeader(title: L.t("today.heatmap"),
                              subtitle: L.t("today.heatmapCaption"))
                ShortcutHeatmap(combos: Dictionary(
                    uniqueKeysWithValues: metrics.topCombos.map { ($0.comboID, $0.count) }))
                if !metrics.topCombos.isEmpty {
                    Divider()
                    Text(L.t("today.top5")).font(Theme.Font.sectionTitle)
                    let peak = metrics.topCombos.map(\.count).max() ?? 1
                    ForEach(Array(metrics.topCombos.prefix(5).enumerated()), id: \.element.comboID) { index, combo in
                        ComboRankRow(rank: index + 1, combo: combo, peak: peak)
                    }
                }
            }
        }
    }

    private func timelineSection(_ metrics: TodayMetrics) -> some View {
        Card {
            ActivityTimeline(series: metrics.sevenDaySeries, hourly: metrics.hourly)
        }
    }

    private func topAppsSection(_ metrics: TodayMetrics) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(title: L.t("today.topApps"),
                              subtitle: MetricDefinition.topAppsMetric)
                if metrics.topApps.isEmpty {
                    EmptyStateView(symbol: "app.dashed", title: L.t("common.empty"))
                } else {
                    ForEach(metrics.topApps.prefix(6), id: \.bundleID) { app in
                        AppRankRow(app: app, name: DisplayName.app(app.bundleID))
                    }
                }
            }
        }
    }

    private var opportunitySection: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text(L.t("today.opportunity")).font(Theme.Font.sectionTitle)
                if let card = model.pendingRecommendation {
                    RecommendationSummaryInline(card: card)
                } else {
                    Text("No recommendation yet. ShortcutSense needs at least 7 activations on 2 different days before suggesting a shortcut.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Friendly application names. Falls back to the bundle id so an unknown app is
/// never hidden — the user should see what was actually counted.
enum DisplayName {
    private static let known: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.apple.finder": "Finder",
        "com.apple.Terminal": "Terminal",
        "com.google.Chrome": "Google Chrome",
        "org.mozilla.firefox": "Firefox",
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.apple.mail": "Mail",
        "com.apple.Notes": "Notes",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.dt.Xcode": "Xcode",
    ]

    static func app(_ bundleID: String) -> String {
        if let name = known[bundleID] { return name }
        // Last path component, e.g. "com.vendor.Thing" → "Thing".
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
