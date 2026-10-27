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
    @StateObject private var ai = AIAnalysisModel()

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
                SectionHeader(title: L.isChinese ? "本地 AI（Ollama）" : "Local AI (Ollama)",
                              subtitle: L.isChinese
                                ? "默认关闭。开启后只与 127.0.0.1:11434 通信，只使用本机已安装的模型，只发送固定的聚合字段。模型只能返回解释，不能修改任何设置。"
                                : "Off by default. When on, it only talks to 127.0.0.1:11434, only uses models installed on this Mac, and only sends fixed aggregate fields. The model can return an explanation and nothing else.")

                Toggle(L.isChinese ? "启用本地 AI 解释" : "Enable local AI explanations",
                       isOn: Binding(get: { ai.isEnabled },
                                     set: {
                                         AppController.shared.isAIEnabled = $0
                                         if $0 { ai.refreshDiscovery() } else { ai.stop() }
                                         model.refresh()
                                     }))

                if ai.isEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: ai.models.isEmpty ? "exclamationmark.circle" : "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(ai.models.isEmpty ? .orange : .green)
                        Text(ai.statusText)
                            .font(Theme.Font.caption)
                            .foregroundStyle(ai.models.isEmpty ? .orange : .secondary)
                        if ai.checking { ProgressView().controlSize(.small) }
                        Spacer()
                        Button(L.isChinese ? "重新检测" : "Check again") { ai.refreshDiscovery() }
                            .buttonStyle(.link)
                            .font(Theme.Font.caption)
                    }

                    if !ai.models.isEmpty {
                        Picker(L.isChinese ? "模型" : "Model",
                               selection: Binding(get: { ai.selectedModel },
                                                  set: {
                                                      ai.selectedModel = $0
                                                      AppController.shared.selectedModel = $0
                                                  })) {
                            ForEach(ai.models) { candidate in
                                Text("\(candidate.name)  (\(ByteCountFormatter.string(fromByteCount: candidate.sizeBytes, countStyle: .file)))")
                                    .tag(candidate.name)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 340, alignment: .leading)
                    }

                    if !ai.selectedModel.isEmpty {
                        HStack(spacing: 8) {
                            Button(L.isChinese ? "测试本地模型" : "Test local model") {
                                ai.runSelfTest()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(ai.analyzing)
                            if ai.analyzing { ProgressView().controlSize(.small) }
                            Spacer()
                        }
                        if let outcome = ai.outcome {
                            HStack(spacing: 6) {
                                Image(systemName: outcome.usedFallback
                                      ? "doc.text" : "checkmark.seal.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(outcome.usedFallback ? .orange : .green)
                                Text(outcome.usedFallback
                                     ? (L.isChinese ? "内置模板（模型未参与）" : "Built-in template (model not used)")
                                     : (L.isChinese ? "本地模型 \(outcome.model)" : "Local model \(outcome.model)"))
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(outcome.usedFallback ? .orange : .green)
                                Spacer()
                                Text("\(outcome.latencyMilliseconds) ms")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            if let reason = outcome.fallbackReason {
                                Text(reason).font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                            Text(L.isChinese
                                 ? "这是连通性测试，使用固定请求，不含你的任何数据。"
                                 : "This is a connectivity test with a fixed request; it contains none of your data.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if case .connectedCloudOnly(let rejected) = ai.status {
                        ForEach(rejected, id: \.name) { cloud in
                            Text("\(cloud.name): \(OllamaModelPolicy.rejectionReason(cloud.name) ?? "")")
                                .font(Theme.Font.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if case .installedNotRunning = ai.status {
                        Toggle(L.isChinese
                               ? "允许 ShortcutSense 启动已安装的 Ollama"
                               : "Allow ShortcutSense to start the installed Ollama",
                               isOn: Binding(
                                get: { AppController.shared.allowAutoStartOllama },
                                set: {
                                    AppController.shared.allowAutoStartOllama = $0
                                    if $0 { ai.startOllamaIfAllowed() }
                                }))
                        Text(L.isChinese
                             ? "只启动你自己安装的 Ollama，不会下载任何模型；已经在运行的实例不会被关闭。"
                             : "Only starts the Ollama you installed. It never downloads a model, and never stops an instance you started yourself.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if case .notInstalled = ai.status {
                        Text(L.isChinese
                             ? "未检测到 Ollama。可从 ollama.com 安装后重新检测；本应用不会替你安装或下载任何东西。"
                             : "Ollama was not found. Install it from ollama.com and check again; this app never installs or downloads anything for you.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(L.isChinese
                     ? "只使用名称不带云端标记的模型：Ollama 也能代理云端模型，仅检查环回地址不足以保证离线。"
                     : "Only models without a cloud marker are offered: Ollama can proxy cloud models, so a loopback check alone cannot guarantee offline execution.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { if ai.isEnabled { ai.refreshDiscovery() } }
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
