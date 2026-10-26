import SwiftUI
import ShortcutSenseCore

/// Conflict Check: inspect any combination, not just the ones the app proposes.
///
/// The four states are shown with their evidence, and the copy never claims a
/// combination is globally free — `no_known_conflict` means "nothing found in the
/// sources that can be read".
@MainActor
final class ConflictModel: ObservableObject {
    @Published var keyCode: UInt16 = KeyCodeNames.keyCode(forLetter: "k") ?? 40
    @Published var modifiers: ComboModifiers = [.control, .option, .shift]
    @Published private(set) var result: ConflictResult?
    @Published private(set) var proposedResults: [(KeyCombo, ConflictResult)] = []
    @Published private(set) var readableSources: [String: Bool] = [:]

    private static let keyChoices: [(String, UInt16)] = {
        var list: [(String, UInt16)] = KeyCodeNames.letterKeyCodes
            .sorted { $0.key < $1.key }
            .map { (String($0.key).uppercased(), $0.value) }
        list += KeyCodeNames.digitKeyCodes.sorted { $0.key < $1.key }
            .map { (String($0.key), $0.value) }
        return list
    }()

    var keyChoicesForPicker: [(String, UInt16)] { Self.keyChoices }

    func evaluate() {
        let controller = AppController.shared
        let inputs = controller.conflictInputs(targetBundleID: nil)
        readableSources = [
            "symbolic hotkeys": inputs.symbolichotkeys != nil,
            "frontmost app menu": inputs.foregroundMenuCombos != nil,
        ]
        let resolver = ConflictResolver()
        let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
        result = resolver.evaluate(combo, inputs: inputs)
        proposedResults = SystemShortcuts.candidateCombos().prefix(8).map { candidate in
            (candidate, resolver.evaluate(candidate, inputs: inputs))
        }
    }
}

struct ConflictDashboard: View {
    @ObservedObject var model: ConflictModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                Text(L.t("nav.conflicts")).font(.system(size: 24, weight: .bold))
                Text(L.isChinese
                     ? "四种状态：已占用、潜在冲突、未发现已知冲突、未知。“未发现已知冲突”只表示 ShortcutSense 能读取的来源没有发现占用，不代表该组合一定空闲。"
                     : "Four states: occupied, potential conflict, no known conflict, unknown. \"No known conflict\" means the sources ShortcutSense can read showed nothing — it does not mean the combination is free.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Card {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        SectionHeader(title: L.isChinese ? "检查一个组合键" : "Check a combination")
                        HStack {
                            Picker(L.isChinese ? "修饰键" : "Modifiers",
                                   selection: Binding(
                                    get: { model.modifiers.rawValue },
                                    set: {
                                        model.modifiers = ComboModifiers(rawValue: $0)
                                        model.evaluate()
                                    })) {
                                Text("⌃⌥⇧").tag(ComboModifiers(
                                    [.control, .option, .shift]).rawValue)
                                Text("⌘⇧").tag(ComboModifiers([.command, .shift]).rawValue)
                                Text("⌘").tag(ComboModifiers.command.rawValue)
                                Text("⌃⌘").tag(ComboModifiers([.control, .command]).rawValue)
                                Text(L.isChinese ? "无" : "None").tag(ComboModifiers([]).rawValue)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 130)

                            Picker(L.isChinese ? "按键" : "Key",
                                   selection: Binding(
                                    get: { model.keyCode },
                                    set: { model.keyCode = $0; model.evaluate() })) {
                                ForEach(model.keyChoicesForPicker, id: \.1) { choice in
                                    Text(choice.0).tag(choice.1)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 100)

                            Spacer()
                            Button(L.isChinese ? "检查" : "Check") { model.evaluate() }
                                .buttonStyle(.bordered)
                        }

                        if let result = model.result {
                            ConflictResultView(combo: KeyCombo(keyCode: model.keyCode,
                                                               modifiers: model.modifiers),
                                               result: result)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        SectionHeader(
                            title: L.isChinese ? "ShortcutSense 会提议的组合" : "Combinations ShortcutSense would propose",
                            subtitle: L.isChinese
                                ? "只在这些低风险组合中挑选，且必须处于“未发现已知冲突”。"
                                : "Only chosen from these low-risk combinations, and only when no known conflict is found.")
                        ForEach(model.proposedResults, id: \.0.comboID) { pair in
                            HStack {
                                Text(pair.0.displayString).font(Theme.Font.mono)
                                    .frame(width: 210, alignment: .leading)
                                ConflictBadge(conflict: pair.1)
                                Spacer()
                                Text(evidenceSummary(pair.1))
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L.isChinese ? "来源可读性" : "Source readability")
                            .font(Theme.Font.sectionTitle)
                        ForEach(Array(model.readableSources.keys.sorted()), id: \.self) { source in
                            HStack(spacing: 6) {
                                Image(systemName: model.readableSources[source] == true
                                      ? "checkmark.circle.fill" : "questionmark.circle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(model.readableSources[source] == true
                                                     ? .green : .secondary)
                                Text(source).font(Theme.Font.caption)
                                Spacer()
                                Text(model.readableSources[source] == true
                                     ? (L.isChinese ? "可读" : "readable")
                                     : (L.isChinese ? "不可读 → 判定为未知" : "unreadable → resolves to unknown"))
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text(L.isChinese
                             ? "第三方工具的动态热键无法枚举，这类占用一律显示为未知。"
                             : "Dynamic hotkeys of third-party tools cannot be enumerated; those are always reported as unknown.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(Theme.Spacing.large)
        }
        .background(.background)
        .onAppear { model.evaluate() }
    }

    private func evidenceSummary(_ result: ConflictResult) -> String {
        if result.evidence.isEmpty {
            return L.isChinese ? "可读来源中无证据" : "no evidence in readable sources"
        }
        return result.evidence.map(\.source).joined(separator: ", ")
    }
}

struct ConflictResultView: View {
    let combo: KeyCombo
    let result: ConflictResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(combo.displayString).font(Theme.Font.mono)
                ConflictBadge(conflict: result)
                Spacer()
                Text(result.isEligibleForAutomaticApply
                     ? (L.isChinese ? "可自动应用" : "Eligible for Apply")
                     : (L.isChinese ? "不可自动应用" : "Not eligible for Apply"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(result.isEligibleForAutomaticApply ? .green : .secondary)
            }
            ForEach(result.evidence, id: \.detail) { evidence in
                Text("• \(evidence.source) — \(evidence.detail)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if result.evidence.isEmpty {
                Text(L.isChinese
                     ? "• 可读取的来源中未发现占用。"
                     : "• Nothing found in the readable sources.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }
}
