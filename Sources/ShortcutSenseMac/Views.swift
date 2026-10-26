import SwiftUI
import ShortcutSenseCore

func loc(_ english: String, _ chinese: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
}

// MARK: - Opportunities

@MainActor
struct OpportunitiesView: View {
    @State private var candidates: [LaunchFocusCandidate] = []
    @State private var learnCandidates: [LearnCandidate] = []
    @State private var registered: [RegisteredShortcut] = []
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(loc("Opportunities", "推荐")).font(.largeTitle.bold())

                if !registered.isEmpty {
                    sectionTitle(loc("Active shortcuts", "已启用的热键"))
                    ForEach(registered, id: \.id) { shortcut in
                        HStack {
                            Text(shortcut.displayCombo).font(.system(.body, design: .monospaced))
                            Text("→ \(shortcut.targetBundleID)").foregroundStyle(.secondary)
                            Spacer()
                            Button(loc("Undo", "撤销")) {
                                do { try AppController.shared.undo(shortcutID: shortcut.id); reload() }
                                catch { message = "\(error)" }
                            }
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Divider()
                }

                if let message {
                    Text(message).font(.callout).foregroundStyle(.red)
                }

                if candidates.isEmpty && learnCandidates.isEmpty {
                    Text(loc("No recommendations yet. ShortcutSense needs at least 7 activations on 2 different days before suggesting a shortcut.",
                             "暂无推荐。需要至少 7 次激活、分布在 2 个不同日期后才会给出建议。"))
                        .foregroundStyle(.secondary)
                }

                ForEach(candidates, id: \.bundleID) { candidate in
                    CandidateCard(candidate: candidate) { reload() }
                }

                ForEach(learnCandidates, id: \.commandID) { learn in
                    LearnCard(candidate: learn)
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
    }

    private func reload() {
        let controller = AppController.shared
        registered = (try? controller.store.registeredShortcuts(activeOnly: true)) ?? []

        let window = DateBuckets.rollingWindow(endingAt: Date(), days: 7, timeZone: .current)
        let activity = (try? controller.store.dailyActivity(
            from: window.buckets.first ?? "", to: window.buckets.last ?? "")) ?? []

        var byApp: [String: (unknown: Int, navigation: Int, managed: Int, days: Set<String>)] = [:]
        for row in activity {
            var entry = byApp[row.bundleID] ?? (0, 0, 0, [])
            entry.unknown += row.unknownOriginActivations
            entry.navigation += row.observedKeyboardNavigation
            entry.managed += row.managedHotkeyActivations
            if row.unknownOriginActivations > 0 || row.observedKeyboardNavigation > 0 {
                entry.days.insert(row.date)
            }
            byApp[row.bundleID] = entry
        }
        let evidence = byApp.map { key, value in
            AppEvidence(bundleID: key, unknownOriginActivations: value.unknown,
                        observedKeyboardNavigation: value.navigation,
                        managedHotkeyActivations: value.managed, activeDays: value.days.count)
        }

        let dismissed = Set(((try? controller.store.recommendations(status: .dismissed)) ?? [])
            .filter { rec in
                guard let until = rec.cooldownUntil, let date = DateBuckets.parseISO8601(until) else { return false }
                return date > Date()
            }
            .map(\.bundleID))

        var allocator = ComboAllocator()
        let engine = RecommendationEngine()
        candidates = engine.launchFocusCandidates(
            evidence: evidence,
            existingManagedBundleIDs: Set(registered.map(\.targetBundleID)),
            dismissedBundleIDs: dismissed,
            inferredRecommendationsEnabled: true,
            conflictInputs: controller.conflictInputs(targetBundleID: nil),
            comboAllocator: &allocator
        ).filter(\.shouldSurface)

        let menuStats = (try? controller.store.menuActionStats(
            from: window.buckets.first ?? "", to: window.buckets.last ?? "")) ?? []
        learnCandidates = engine.learnCandidates(
            menuStats: menuStats,
            existingManagedCombos: Set(registered.map(\.combo)),
            explicitMarks: [])
    }
}

@MainActor
struct CandidateCard: View {
    let candidate: LaunchFocusCandidate
    let onChanged: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(candidate.bundleID).font(.headline)
                if candidate.priority == .high {
                    Text(loc("High priority", "高优先级"))
                        .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
            }

            // Semantic honesty: origin is unknown, never described as a click.
            Text(loc("\(candidate.evidence.unknownOriginActivations) activations in 7 days on \(candidate.evidence.activeDays) days. How you got there is not known (not necessarily the Dock or the mouse).",
                     "7 天内激活 \(candidate.evidence.unknownOriginActivations) 次，分布在 \(candidate.evidence.activeDays) 天。来源未知（不一定是 Dock 或鼠标）。"))
                .font(.callout)

            HStack {
                Text(loc("Proposed", "建议")).foregroundStyle(.secondary)
                Text(candidate.proposedCombo.displayString)
                    .font(.system(.body, design: .monospaced))
            }
            Text(loc("Conflict: \(candidate.conflict.status.rawValue) — checked against system hotkeys, enabled symbolic hotkeys and readable app menus. This is not a guarantee the combination is free.",
                     "冲突：\(candidate.conflict.status.rawValue) — 已检查系统热键、已启用的符号热键和可读取的应用菜单。这不代表该组合一定空闲。"))
                .font(.caption).foregroundStyle(.secondary)

            if let error { Text(error).font(.caption).foregroundStyle(.red) }

            HStack {
                Button(loc("Apply", "应用")) { apply() }
                    .buttonStyle(.borderedProminent)
                Button(loc("Dismiss", "忽略")) { dismiss() }
                Spacer()
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func apply() {
        let controller = AppController.shared
        let recommendation = Recommendation(
            id: "launch-\(candidate.bundleID)", bundleID: candidate.bundleID,
            kind: .launchFocus, targetID: "launch",
            proposedCombo: candidate.proposedCombo.comboID, confidence: candidate.confidence,
            status: .pending, createdAt: DateBuckets.iso8601(Date()),
            cooldownUntil: nil, updatedAt: DateBuckets.iso8601(Date()))
        do {
            try controller.store.upsertRecommendation(recommendation)
            // Re-check conflicts immediately before registering: menus and other apps
            // may have changed since the card was rendered.
            let fresh = ConflictResolver().evaluate(
                candidate.proposedCombo,
                inputs: controller.conflictInputs(targetBundleID: candidate.bundleID))
            _ = try controller.apply(recommendation: recommendation,
                                     combo: candidate.proposedCombo, conflict: fresh)
            onChanged()
        } catch {
            self.error = "\(error)"
        }
    }

    private func dismiss() {
        let controller = AppController.shared
        let recommendation = Recommendation(
            id: "launch-\(candidate.bundleID)", bundleID: candidate.bundleID,
            kind: .launchFocus, targetID: "launch",
            proposedCombo: candidate.proposedCombo.comboID, confidence: candidate.confidence,
            status: .dismissed, createdAt: DateBuckets.iso8601(Date()),
            cooldownUntil: nil, updatedAt: DateBuckets.iso8601(Date()))
        let cooldown = Calendar.current.date(byAdding: .day,
                                             value: RecommendationThresholds.dismissalCooldownDays,
                                             to: Date())
        try? controller.store.upsertRecommendation(recommendation)
        try? controller.store.setRecommendationStatus(
            id: recommendation.id, status: .dismissed,
            cooldownUntil: cooldown.map(DateBuckets.iso8601), now: Date())
        onChanged()
    }
}

@MainActor
struct LearnCard: View {
    let candidate: LearnCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.safeLabel ?? candidate.commandID).font(.headline)
            if let count = candidate.observedClickCount, let days = candidate.activeDays {
                Text(loc("Observed \(count) verified menu clicks on \(days) days.",
                         "已观测到 \(count) 次经验证的菜单点击，分布在 \(days) 天。"))
                    .font(.callout)
            } else {
                // Manual marks never pretend to be observed counts.
                Text(loc("Based on your manual mark — no click count is claimed.",
                         "基于你的手动标记 — 不声称点击次数。"))
                    .font(.callout)
            }
            if let shortcut = candidate.existingShortcut,
               let combo = KeyComboCodec.decode(shortcut) {
                Text(loc("This command already has a shortcut: \(combo.displayString)",
                         "该命令已有快捷键：\(combo.displayString)"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(loc("This command has no shortcut. macOS does not allow an app to add one to another app's menu; ShortcutSense shows a manual guide instead of pretending to do it.",
                         "该命令没有快捷键。macOS 不允许应用为其他应用添加菜单快捷键；ShortcutSense 会给出人工指引，而不会假装自动完成。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }
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
