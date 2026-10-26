import SwiftUI
import ShortcutSenseCore

/// Settings. Permissions are shown separately and honestly, including the case where
/// a grant exists in TCC but the running process has not picked it up yet.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var snapshot: PermissionSnapshot?
    @Published private(set) var tapRunning = false
    @Published private(set) var excluded: [String] = []
    @Published private(set) var isPaused = false
    @Published private(set) var firstCollectionAt: Date?
    @Published private(set) var rowCounts: [String: Int] = [:]
    @Published var aiEnabled = false
    @Published var aiEndpoint = ""
    @Published var hourlyEnabled = false
    @Published var confirmDelete = false
    @Published var statusMessage: String?
    /// Non-nil when the row counts could not be read.
    @Published private(set) var dataError: String?

    func refresh() {
        let controller = AppController.shared
        snapshot = controller.permissionSnapshot
        tapRunning = controller.lastTapStatus == .running
        excluded = controller.store.excludedBundleIDs()
        isPaused = controller.isPaused
        firstCollectionAt = controller.store.firstCollectionStartedAt()
        // A failed count must not render as "0 rows" — that reads as "your data is
        // gone" rather than "the query failed".
        do {
            rowCounts = try controller.store.rowCounts()
            dataError = nil
        } catch {
            rowCounts = [:]
            dataError = "\(error)"
        }
        aiEnabled = controller.isAIEnabled
        aiEndpoint = controller.aiEndpoint?.absoluteString ?? "http://127.0.0.1:11434/api/generate"
        hourlyEnabled = controller.store.hourlyCollectionEnabled
    }

    func setExcluded(_ bundleID: String, excluded: Bool) {
        AppController.shared.setExcluded(bundleID: bundleID, excluded: excluded)
        refresh()
    }

    func deleteAll() {
        AppController.shared.deleteAllData()
        refresh()
        statusMessage = L.isChinese
            ? "本地数据已删除，系统热键已释放。"
            : "Local data deleted and OS hotkeys released."
    }

    func setHourly(_ enabled: Bool) {
        try? AppController.shared.store.setHourlyCollectionEnabled(enabled)
        hourlyEnabled = enabled
    }
}

struct SettingsDashboard: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                Text(L.t("nav.settings")).font(.system(size: 24, weight: .bold))
                permissions
                collection
                exclusions
                aiSection
                dataSection
            }
            .padding(Theme.Spacing.large)
        }
        .background(.background)
        .onAppear { model.refresh() }
    }

    // MARK: Permissions

    private var permissions: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(title: L.isChinese ? "权限" : "Permissions",
                              subtitle: L.isChinese
                                ? "两项权限分别申请、分别显示，可随时在系统设置中撤销。"
                                : "The two grants are requested and shown separately, and can be revoked at any time.")
                permissionRow(L.t("perm.inputMonitoring"),
                              state: model.snapshot?.inputMonitoring ?? .unknown,
                              detail: L.isChinese
                                ? "统计按键所必需。撤销后采集立即停止，历史仍可查看。"
                                : "Required to count keystrokes. Revoking stops collection immediately; history stays readable.",
                              action: { Permissions.requestInputMonitoring(); model.refresh() },
                              open: { Permissions.openInputMonitoringSettings() })
                permissionRow(L.t("perm.accessibility"),
                              state: model.snapshot?.accessibility ?? .unknown,
                              detail: L.isChinese
                                ? "仅用于读取菜单和检查冲突。不授权也能使用热键功能。"
                                : "Only used to read menus and check conflicts. Shortcuts work without it.",
                              action: { Permissions.requestAccessibility(); model.refresh() },
                              open: { Permissions.openAccessibilitySettings() })
                if (model.snapshot?.inputMonitoring ?? .denied) == .granted && !model.tapRunning {
                    Label(L.isChinese
                          ? "权限已授予，但当前进程尚未开始采集。请退出并重新打开应用。"
                          : "The grant exists but this process is not capturing yet. Quit and reopen the app.",
                          systemImage: "arrow.clockwise.circle")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func permissionRow(_ title: String, state: PermissionStatus,
                               detail: String,
                               action: @escaping () -> Void,
                               open: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: state == .granted ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(state == .granted ? .green : .orange)
                    .font(.system(size: 11))
                Text(title).font(Theme.Font.cardTitle)
                Text(state == .granted ? L.t("perm.granted") : L.t("perm.denied"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(state == .granted ? .green : .orange)
                Spacer()
                if state != .granted {
                    Button(L.t("perm.request"), action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(L.t("perm.openSettings"), action: open)
                        .buttonStyle(.link)
                        .font(Theme.Font.caption)
                }
            }
            Text(detail)
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 19)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(state == .granted ? "granted" : "not granted")")
    }

    // MARK: Collection

    private var collection: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(title: L.isChinese ? "采集" : "Collection")
                Toggle(L.isChinese ? "暂停采集" : "Pause collection",
                       isOn: Binding(get: { model.isPaused },
                                     set: { AppController.shared.isPaused = $0; model.refresh() }))
                Toggle(L.isChinese ? "记录小时级分布（默认关闭）" : "Record hourly distribution (off by default)",
                       isOn: Binding(get: { model.hourlyEnabled },
                                     set: { model.setHourly($0) }))
                Text(L.isChinese
                     ? "小时级分布可以反映日常作息，因此默认关闭。开启后，活动时间线会显示当天 24 小时；关闭时显示近 7 天总计。"
                     : "Hourly distributions can reveal daily routines, so this is off by default. When on, the timeline shows 24 hours for the day; when off, it shows 7-day totals.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let first = model.firstCollectionAt {
                    Text(L.isChinese
                         ? "首次采集时间：\(first.formatted())"
                         : "First collection: \(first.formatted())")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Exclusions

    private var exclusions: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(title: L.isChinese ? "排除的应用" : "Excluded applications",
                              subtitle: L.isChinese
                                ? "默认排除密码管理器、终端、编辑器和 AI 编程工具。终端类可在知情后重新纳入。"
                                : "Password managers, terminals, editors and AI coding tools are excluded by default. Terminal-class apps can be re-included knowingly.")
                ForEach(model.excluded, id: \.self) { bundle in
                    HStack {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(DisplayName.app(bundle)).font(Theme.Font.caption)
                        Text(bundle).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button(L.isChinese ? "纳入" : "Include") {
                            model.setExcluded(bundle, excluded: false)
                        }
                        .buttonStyle(.link)
                        .font(Theme.Font.caption)
                    }
                }
            }
        }
    }

    // MARK: AI

    private var aiSection: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(title: L.isChinese ? "可选本地 AI（Ollama）" : "Optional local AI (Ollama)",
                              subtitle: L.isChinese
                                ? "默认关闭。启用后只向环回地址发送固定的聚合 JSON。模型只能返回解释，不能修改任何设置。"
                                : "Off by default. When enabled, only a fixed aggregate JSON is sent to a loopback address. The model can only return an explanation; it cannot change any setting.")
                Toggle(L.isChinese ? "启用本地 AI 解释" : "Enable local AI explanations",
                       isOn: Binding(get: { model.aiEnabled },
                                     set: { AppController.shared.isAIEnabled = $0; model.refresh() }))
                TextField("Endpoint", text: $model.aiEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { AppController.shared.aiEndpoint = URL(string: model.aiEndpoint) }
                Text(L.isChinese
                     ? "仅接受 http://127.0.0.1 或 http://[::1]。"
                     : "Only http://127.0.0.1 or http://[::1] is accepted.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Data

    private var dataSection: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader(title: L.isChinese ? "本地数据" : "Local data",
                              subtitle: L.isChinese
                                ? "删除会清除全部历史、排除项和设置，释放系统热键，并检查点 SQLite WAL。你自己导出的文件不会被删除。"
                                : "Deleting removes all history, exclusions and settings, releases OS hotkeys and checkpoints the SQLite WAL. Files you exported yourself are not touched.")
                if let dataError = model.dataError {
                    Label(L.isChinese ? "无法读取本地数据：\(dataError)"
                                      : "Local data could not be read: \(dataError)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.red)
                }
                HStack(spacing: Theme.Spacing.medium) {
                    ForEach(["daily_combo_stats", "daily_app_activity", "registered_shortcuts",
                             "hourly_keyboard_activity"], id: \.self) { table in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.dataError == nil ? "\(model.rowCounts[table] ?? 0)" : "—")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .monospacedDigit()
                            Text(table.replacingOccurrences(of: "_", with: " "))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
                if let message = model.statusMessage {
                    Text(message).font(Theme.Font.caption).foregroundStyle(.green)
                }
                Button(L.isChinese ? "删除全部本地数据" : "Delete all local data", role: .destructive) {
                    model.confirmDelete = true
                }
                .confirmationDialog(L.isChinese ? "删除全部本地数据？" : "Delete all local data?",
                                    isPresented: $model.confirmDelete) {
                    Button(L.isChinese ? "删除" : "Delete", role: .destructive) { model.deleteAll() }
                    Button(L.t("common.cancel"), role: .cancel) {}
                }
            }
        }
    }
}
