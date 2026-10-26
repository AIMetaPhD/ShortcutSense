import SwiftUI
import ShortcutSenseCore

func loc(_ english: String, _ chinese: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
}

// MARK: - Conflict check

@MainActor
struct ConflictView: View {
    @State private var rows: [Row] = []

    struct Row: Identifiable {
        let id: String
        let combo: String
        let status: ConflictStatus
        let evidence: [ConflictEvidence]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc("Conflict Check", "冲突检查")).font(.largeTitle.bold())
                Text(loc("Four states: occupied, potential conflict, no known conflict, unknown. \"No known conflict\" means the sources ShortcutSense can read showed nothing — it does not mean the combination is free.",
                         "四种状态：已占用、潜在冲突、未发现已知冲突、未知。“未发现已知冲突”只表示 ShortcutSense 能读取的来源没有发现占用，不代表该组合一定空闲。"))
                    .font(.callout).foregroundStyle(.secondary)

                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.combo).font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(row.status.rawValue)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(color(for: row.status).opacity(0.2), in: Capsule())
                        }
                        ForEach(row.evidence, id: \.detail) { evidence in
                            Text("• \(evidence.source) — \(evidence.detail)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if row.evidence.isEmpty {
                            Text(loc("• No evidence from readable sources.", "• 可读取来源中无证据。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func color(for status: ConflictStatus) -> Color {
        switch status {
        case .occupied: return .red
        case .potentialConflict: return .orange
        case .noKnownConflict: return .green
        case .unknown: return .gray
        }
    }

    private func reload() {
        let controller = AppController.shared
        let inputs = controller.conflictInputs(targetBundleID: nil)
        let resolver = ConflictResolver()
        rows = SystemShortcuts.candidateCombos().prefix(6).map { combo in
            let result = resolver.evaluate(combo, inputs: inputs)
            return Row(id: combo.comboID, combo: combo.displayString,
                       status: result.status, evidence: result.evidence)
        }
    }
}

// MARK: - Weekly

@MainActor
struct WeeklyView: View {
    @State private var report: WeeklyReport?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(loc("Weekly Review", "每周回顾")).font(.largeTitle.bold())

                if let report {
                    if report.isPreview {
                        Label(loc("Preview — fewer than 7 days of real data. Numbers below are not a weekly result.",
                                  "预览 — 真实数据不足 7 天。以下数字不代表一周的结果。"),
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Text("\(report.periodStart) → \(report.periodEnd)").font(.headline)
                    Text(loc("Generated at \(report.generatedAt.formatted()) (actual time, not a scheduled claim).",
                             "生成于 \(report.generatedAt.formatted())（实际时间，并非声称准点执行）。"))
                        .font(.caption).foregroundStyle(.secondary)

                    Text(loc("Anonymous keystrokes: \(report.totalAnonymousKeystrokes)",
                             "匿名按键总数：\(report.totalAnonymousKeystrokes)"))

                    if !report.topCombos.isEmpty {
                        Text(loc("Most used shortcuts", "最常用快捷键")).font(.headline)
                        ForEach(report.topCombos, id: \.comboID) { combo in
                            Text("• \(combo.display) — \(combo.count)").font(.callout)
                        }
                    }

                    if !report.adoptedShortcuts.isEmpty {
                        Text(loc("Adopted shortcuts (measured)", "已采纳热键（实测）")).font(.headline)
                        ForEach(report.adoptedShortcuts, id: \.shortcutID) { adopted in
                            Text(loc("• \(adopted.displayCombo) → \(adopted.targetBundleID): \(adopted.triggerCount) presses, \(adopted.successfulActivations) confirmed activations",
                                     "• \(adopted.displayCombo) → \(adopted.targetBundleID)：\(adopted.triggerCount) 次按键，\(adopted.successfulActivations) 次确认激活"))
                                .font(.callout)
                        }
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text(loc("No report yet.", "暂无报告。")).foregroundStyle(.secondary)
                }

                Button(loc("Generate now", "立即生成")) { generate() }
            }
        }
        .onAppear(perform: generate)
    }

    private func generate() {
        do {
            report = try AppController.shared.weeklyService.generateIfNeeded().report
        } catch {
            self.error = "\(error)"
        }
    }
}

// MARK: - Settings

@MainActor
struct SettingsView: View {
    @State private var snapshot: PermissionSnapshot?
    @State private var aiEnabled = false
    @State private var aiEndpoint = "http://127.0.0.1:11434/api/generate"
    @State private var excluded: [String] = []
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(loc("Settings", "设置")).font(.largeTitle.bold())

                GroupBox(loc("Permissions", "权限")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let snapshot {
                            ForEach(snapshot.diagnosis, id: \.self) { line in
                                Text(line).font(.callout)
                            }
                        }
                        HStack {
                            Button(loc("Request Input Monitoring", "申请输入监控")) {
                                Permissions.requestInputMonitoring(); refresh()
                            }
                            Button(loc("Request Accessibility", "申请辅助功能")) {
                                Permissions.requestAccessibility(); refresh()
                            }
                            Button(loc("Refresh", "刷新")) { refresh() }
                        }
                    }.padding(6)
                }

                GroupBox(loc("Excluded applications", "排除的应用")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loc("Sensitive apps are excluded by default. Terminal-class apps can be re-included knowingly.",
                                 "敏感应用默认排除。终端类应用可在知情后重新纳入。"))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(excluded, id: \.self) { bundle in
                            Text(bundle).font(.system(.caption, design: .monospaced))
                        }
                    }.padding(6)
                }

                GroupBox(loc("Optional local AI (Ollama)", "可选本地 AI（Ollama）")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(loc("Off by default. When enabled, only the fixed aggregate JSON is sent to a loopback address. The model can only return an explanation; it cannot change any setting.",
                                 "默认关闭。启用后只向环回地址发送固定的聚合 JSON。模型只能返回解释，不能修改任何设置。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle(loc("Enable local AI explanations", "启用本地 AI 解释"),
                               isOn: Binding(get: { aiEnabled },
                                             set: { aiEnabled = $0; AppController.shared.isAIEnabled = $0 }))
                        TextField("Endpoint", text: $aiEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                AppController.shared.aiEndpoint = URL(string: aiEndpoint)
                            }
                        Text(loc("Only http://127.0.0.1 or http://[::1] is accepted.", "仅接受 http://127.0.0.1 或 http://[::1]。"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(6)
                }

                GroupBox(loc("Data", "数据")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(loc("Deleting removes all ShortcutSense history, exclusions and settings, and checkpoints the SQLite WAL. Files you exported yourself are not touched.",
                                 "删除会清除全部 ShortcutSense 历史、排除项和设置，并检查点 SQLite WAL。你自己导出的文件不会被删除。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(loc("Delete all local data", "删除全部本地数据"), role: .destructive) {
                            confirmDelete = true
                        }
                        .confirmationDialog(loc("Delete all local data?", "删除全部本地数据？"),
                                            isPresented: $confirmDelete) {
                            Button(loc("Delete", "删除"), role: .destructive) {
                                AppController.shared.deleteAllData(); refresh()
                            }
                            Button(loc("Cancel", "取消"), role: .cancel) {}
                        }
                    }.padding(6)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let controller = AppController.shared
        snapshot = controller.permissionSnapshot
        aiEnabled = controller.isAIEnabled
        aiEndpoint = controller.aiEndpoint?.absoluteString ?? "http://127.0.0.1:11434/api/generate"
        excluded = controller.store.excludedBundleIDs()
    }
}
