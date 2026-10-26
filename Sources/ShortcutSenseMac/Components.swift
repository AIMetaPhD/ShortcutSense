import SwiftUI
import ShortcutSenseCore

// MARK: - Card

/// The one card surface used everywhere: grouped material, consistent radius,
/// no shadow stacking.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.medium
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
            )
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.Font.sectionTitle)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Hero

/// The blue summary block. Shows one real, checked number and states what it counts.
struct HeroSummary: View {
    let value: Int
    let caption: String
    let status: CollectionStatus
    let date: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Text(date)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                StatusPill(status: status, onDark: true)
            }
            Text(value.formatted())
                .font(Theme.Font.hero)
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .accessibilityLabel("\(value) \(caption)")
            Text(caption)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Theme.accent, Theme.accent.opacity(0.78)],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Theme.Radius.card)
        )
    }
}

// MARK: - Status

enum CollectionStatus: Equatable {
    case collecting
    case paused
    case permissionsRequired
    case blocked

    var label: String {
        switch self {
        case .collecting: return L.t("status.collecting")
        case .paused: return L.t("status.paused")
        case .permissionsRequired: return L.t("status.permissions")
        case .blocked: return L.t("status.blocked")
        }
    }

    var symbol: String {
        switch self {
        case .collecting: return "record.circle"
        case .paused: return "pause.circle.fill"
        case .permissionsRequired: return "exclamationmark.lock.fill"
        case .blocked: return "slash.circle"
        }
    }

    var tint: Color {
        switch self {
        case .collecting: return .green
        case .paused: return .orange
        case .permissionsRequired: return .orange
        case .blocked: return .secondary
        }
    }
}

struct StatusPill: View {
    let status: CollectionStatus
    var onDark: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol)
                .font(.system(size: 9, weight: .bold))
            Text(status.label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(onDark ? AnyShapeStyle(.white) : AnyShapeStyle(status.tint))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            (onDark ? Color.white.opacity(0.18) : status.tint.opacity(0.12)),
            in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.label)
    }
}

// MARK: - KPI card

/// One metric with its definition always visible, so a number can never be read out
/// of context.
struct MetricCard: View {
    let title: String
    let value: Int?
    let definition: String
    var fallback: String = "—"

    var body: some View {
        Card(padding: Theme.Spacing.small + 2) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value.map { $0.formatted() } ?? fallback)
                    .font(Theme.Font.kpi)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(definition)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value.map(String.init) ?? fallback). \(definition)")
    }
}

// MARK: - Keyboard heatmap

/// A keyboard drawn from SwiftUI shapes, coloured **only** by shortcut combinations.
///
/// Privacy rule it encodes (see `09_UI_UX_PRODUCT_REQUIREMENTS.md` §3): ordinary
/// character keys are never counted per key, so this figure has no way to represent
/// them. A key is highlighted only when the user pressed it as part of a recorded
/// Command/Control combination, and only through the combo's count.
struct ShortcutHeatmap: View {
    /// Normalized combo id → count, already filtered to the visible window.
    let combos: [String: Int]
    @State private var hovered: String?

    private static let rows: [[String]] = [
        ["esc", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=", "delete"],
        ["tab", "q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]", "\\"],
        ["caps", "a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'", "return"],
        ["shift", "z", "x", "c", "v", "b", "n", "m", ",", ".", "/", "shift"],
        ["fn", "control", "option", "command", "space", "command", "option", "left", "up", "down", "right"],
    ]

    /// Virtual key code for a keycap label, used to look up its count.
    private static let keyCodes: [String: UInt16] = {
        var map: [String: UInt16] = [:]
        for (letter, code) in KeyCodeNames.letterKeyCodes { map[String(letter)] = code }
        for (digit, code) in KeyCodeNames.digitKeyCodes { map[String(digit)] = code }
        map["space"] = 49; map["tab"] = 48; map["return"] = 36; map["esc"] = 53
        map["delete"] = 51; map["-"] = 27; map["="] = 24
        map["["] = 33; map["]"] = 30; map["\\"] = 42
        map[";"] = 41; map["'"] = 39; map[","] = 43; map["."] = 47; map["/"] = 44
        return map
    }()

    /// Sum of counts for every combo whose key is this keycap.
    private func intensity(for label: String) -> (count: Int, combos: [String]) {
        guard let code = Self.keyCodes[label] else { return (0, []) }
        var total = 0
        var matched: [String] = []
        for (comboID, count) in combos {
            guard let combo = KeyComboCodec.decode(comboID), combo.keyCode == code else { continue }
            total += count
            matched.append(combo.displayString)
        }
        return (total, matched.sorted())
    }

    private var peak: Int { max(1, combos.values.max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if combos.isEmpty {
                emptyState
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 4) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, label in
                                keycap(label)
                            }
                        }
                    }
                }
                legend
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(L.t("common.empty"))
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            Text(L.t("today.heatmapCaption"))
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.large)
        .accessibilityElement(children: .combine)
    }

    private func keycap(_ label: String) -> some View {
        let hit = intensity(for: label)
        let ratio = Double(hit.count) / Double(peak)
        let isWide = ["space", "shift", "command", "return", "tab", "caps", "fn",
                      "control", "option", "delete", "esc"].contains(label)
        return RoundedRectangle(cornerRadius: 5)
            .fill(Theme.heat(ratio))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
            )
            .overlay(
                Text(displayLabel(label))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(ratio > 0.55 ? .white : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            )
            .frame(width: isWide ? 46 : 26, height: 24)
            .onHover { inside in hovered = inside ? label : (hovered == label ? nil : hovered) }
            .help(hit.count > 0
                  ? "\(hit.combos.joined(separator: ", ")) — \(hit.count) uses"
                  : "")
            .accessibilityLabel(hit.count > 0
                ? "\(displayLabel(label)): \(hit.count) shortcut uses"
                : displayLabel(label))
    }

    private func displayLabel(_ label: String) -> String {
        switch label {
        case "command": return "⌘"
        case "option": return "⌥"
        case "control": return "⌃"
        case "shift": return "⇧"
        case "return": return "↩"
        case "delete": return "⌫"
        case "tab": return "⇥"
        case "esc": return "esc"
        case "space": return "space"
        case "caps": return "caps"
        case "fn": return "fn"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        default: return label.uppercased()
        }
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Text("less").font(.system(size: 9)).foregroundStyle(.tertiary)
            ForEach(0..<Theme.heatRamp.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.heatRamp[index])
                    .frame(width: 14, height: 8)
            }
            Text("more").font(.system(size: 9)).foregroundStyle(.tertiary)
            Spacer()
            Text(L.t("today.heatmapCaption"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

// MARK: - Top combos

struct ComboRankRow: View {
    let rank: Int
    let combo: ComboTotal
    let peak: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text("\(rank)")
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 14, alignment: .trailing)
            Text(combo.display)
                .font(Theme.Font.mono)
                .frame(width: 170, alignment: .leading)
                .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.accentSoft)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(4, proxy.size.width * CGFloat(combo.count) / CGFloat(max(1, peak))))
                }
            }
            .frame(height: 6)
            Text("\(combo.count)")
                .font(Theme.Font.mono)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(combo.display), \(combo.count) uses")
    }
}

// MARK: - Timeline

/// Seven-day activity chart. This is the honest fallback described in the spec:
/// when hourly history is off there is no within-day data, and the chart says so.
struct ActivityTimeline: View {
    let series: [DailyTotal]
    let hourly: [HourlyBucket]?

    private var usesHourly: Bool { !(hourly ?? []).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Text(L.t("today.timeline")).font(Theme.Font.sectionTitle)
                Spacer()
                Text(usesHourly ? "24 h" : L.t("today.timelineFallback"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            if usesHourly {
                hourlyChart
            } else {
                dailyChart
            }
        }
    }

    private var dailyChart: some View {
        let peak = max(1, series.map(\.keypresses).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(series, id: \.date) { day in
                VStack(spacing: 5) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.accent.opacity(day.keypresses > 0 ? 0.75 : 0.12))
                        .frame(height: max(3, 96 * CGFloat(day.keypresses) / CGFloat(peak)))
                    Text(shortLabel(day.date))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(day.date): \(day.keypresses) keystrokes")
            }
        }
        .frame(height: 132)
    }

    private var hourlyChart: some View {
        let byHour = Dictionary(uniqueKeysWithValues: (hourly ?? []).map { ($0.hour, $0) })
        let peak = max(1, (hourly ?? []).map(\.keypresses).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<24, id: \.self) { hour in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.accent.opacity(byHour[hour] != nil ? 0.75 : 0.08))
                    .frame(height: max(2, 96 * CGFloat(byHour[hour]?.keypresses ?? 0) / CGFloat(peak)))
                    .accessibilityLabel("\(hour):00, \(byHour[hour]?.keypresses ?? 0) keystrokes")
            }
        }
        .frame(height: 132)
    }

    private func shortLabel(_ date: String) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3 else { return date }
        return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
    }
}

// MARK: - Top apps

struct AppRankRow: View {
    let app: AppKeystrokeTotal
    let name: String

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "app.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(name).font(Theme.Font.cardTitle).lineLimit(1)
                    Spacer()
                    Text("\(app.keystrokes)")
                        .font(Theme.Font.mono)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(Theme.accent.opacity(0.8))
                            .frame(width: max(3, proxy.size.width * CGFloat(app.share)))
                    }
                }
                .frame(height: 5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(app.keystrokes) keystrokes")
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(title).font(Theme.Font.sectionTitle).foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.large)
        .accessibilityElement(children: .combine)
    }
}
