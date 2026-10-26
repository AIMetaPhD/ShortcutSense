import Foundation

/// System-level shortcut knowledge used by the conflict resolver.
///
/// Two distinct kinds of risk are modelled separately, because conflating them
/// would overstate what can be known:
///
/// - `systemGlobal`: registered by the window server. These cannot be taken over by
///   an application hotkey.
/// - `appMenuHighRisk`: conventional per-application menu bindings (`⌘Q`, `⌘W`, …).
///   They are *not* global grabs; they conflict only while that app is frontmost.
public enum SystemShortcuts {
    public struct Entry: Sendable, Equatable {
        public let keyCode: UInt16
        public let modifiers: ComboModifiers
        public let label: String
        public let scope: ConflictScope
        public let source: String

        public init(keyCode: UInt16, modifiers: ComboModifiers, label: String,
                    scope: ConflictScope, source: String) {
            self.keyCode = keyCode; self.modifiers = modifiers
            self.label = label; self.scope = scope; self.source = source
        }
    }

    private static let cmd = ComboModifiers.command
    private static let ctrl = ComboModifiers.control
    private static let opt = ComboModifiers.option
    private static let shift = ComboModifiers.shift

    public static let entries: [Entry] = [
        // Window-server globals (cannot be overridden by an app hotkey).
        Entry(keyCode: 48, modifiers: cmd, label: "Command+Tab", scope: .systemGlobal, source: "window server: app switcher"),
        Entry(keyCode: 48, modifiers: [cmd, shift], label: "Command+Shift+Tab", scope: .systemGlobal, source: "window server: app switcher"),
        Entry(keyCode: 49, modifiers: cmd, label: "Command+Space", scope: .systemGlobal, source: "symbolichotkeys: Spotlight"),
        Entry(keyCode: 49, modifiers: [cmd, opt], label: "Command+Option+Space", scope: .systemGlobal, source: "symbolichotkeys: Finder search"),
        Entry(keyCode: 53, modifiers: [cmd, opt], label: "Command+Option+Escape", scope: .systemGlobal, source: "window server: force quit"),
        Entry(keyCode: 49, modifiers: [ctrl, cmd], label: "Control+Command+Space", scope: .systemGlobal, source: "system: character viewer"),
        Entry(keyCode: 4, modifiers: [ctrl, cmd], label: "Control+Command+H", scope: .systemGlobal, source: "system: show desktop / app"),
        Entry(keyCode: 123, modifiers: [ctrl, cmd], label: "Control+Command+Left", scope: .systemGlobal, source: "system: previous space"),
        Entry(keyCode: 124, modifiers: [ctrl, cmd], label: "Control+Command+Right", scope: .systemGlobal, source: "system: next space"),
        Entry(keyCode: 20, modifiers: [cmd, shift], label: "Command+Shift+3", scope: .systemGlobal, source: "system: screenshot"),
        Entry(keyCode: 21, modifiers: [cmd, shift], label: "Command+Shift+4", scope: .systemGlobal, source: "system: screenshot selection"),
        Entry(keyCode: 23, modifiers: [cmd, shift], label: "Command+Shift+5", scope: .systemGlobal, source: "system: screenshot toolbar"),

        // Conventional per-app menu bindings: high risk, but not global grabs.
        Entry(keyCode: 12, modifiers: cmd, label: "Command+Q", scope: .appMenuHighRisk, source: "app menu convention: Quit"),
        Entry(keyCode: 13, modifiers: cmd, label: "Command+W", scope: .appMenuHighRisk, source: "app menu convention: Close"),
        Entry(keyCode: 4, modifiers: cmd, label: "Command+H", scope: .appMenuHighRisk, source: "app menu convention: Hide"),
        Entry(keyCode: 46, modifiers: cmd, label: "Command+M", scope: .appMenuHighRisk, source: "app menu convention: Minimize"),
        Entry(keyCode: 46, modifiers: [cmd, opt], label: "Command+Option+M", scope: .appMenuHighRisk, source: "app menu convention: Minimize all"),
        Entry(keyCode: 15, modifiers: cmd, label: "Command+R", scope: .appMenuHighRisk, source: "app menu convention: Reload"),
        Entry(keyCode: 31, modifiers: cmd, label: "Command+O", scope: .appMenuHighRisk, source: "app menu convention: Open"),
        Entry(keyCode: 1, modifiers: cmd, label: "Command+S", scope: .appMenuHighRisk, source: "app menu convention: Save"),
        Entry(keyCode: 35, modifiers: cmd, label: "Command+P", scope: .appMenuHighRisk, source: "app menu convention: Print"),
        Entry(keyCode: 0, modifiers: cmd, label: "Command+A", scope: .appMenuHighRisk, source: "app menu convention: Select All"),
        Entry(keyCode: 8, modifiers: cmd, label: "Command+C", scope: .appMenuHighRisk, source: "app menu convention: Copy"),
        Entry(keyCode: 9, modifiers: cmd, label: "Command+V", scope: .appMenuHighRisk, source: "app menu convention: Paste"),
        Entry(keyCode: 7, modifiers: cmd, label: "Command+X", scope: .appMenuHighRisk, source: "app menu convention: Cut"),
        Entry(keyCode: 6, modifiers: cmd, label: "Command+Z", scope: .appMenuHighRisk, source: "app menu convention: Undo"),
        Entry(keyCode: 37, modifiers: cmd, label: "Command+L", scope: .appMenuHighRisk, source: "app menu convention: location"),
        Entry(keyCode: 45, modifiers: cmd, label: "Command+N", scope: .appMenuHighRisk, source: "app menu convention: New"),
        Entry(keyCode: 17, modifiers: cmd, label: "Command+T", scope: .appMenuHighRisk, source: "app menu convention: New tab"),
        Entry(keyCode: 3, modifiers: cmd, label: "Command+F", scope: .appMenuHighRisk, source: "app menu convention: Find"),
        Entry(keyCode: 5, modifiers: cmd, label: "Command+G", scope: .appMenuHighRisk, source: "app menu convention: Find next"),
        Entry(keyCode: 18, modifiers: cmd, label: "Command+1", scope: .appMenuHighRisk, source: "app menu convention: tab 1"),
        Entry(keyCode: 19, modifiers: cmd, label: "Command+2", scope: .appMenuHighRisk, source: "app menu convention: tab 2"),
        Entry(keyCode: 20, modifiers: cmd, label: "Command+3", scope: .appMenuHighRisk, source: "app menu convention: tab 3"),
        Entry(keyCode: 23, modifiers: cmd, label: "Command+5", scope: .appMenuHighRisk, source: "app menu convention: tab 5"),
        Entry(keyCode: 22, modifiers: cmd, label: "Command+6", scope: .appMenuHighRisk, source: "app menu convention: tab 6"),
        Entry(keyCode: 26, modifiers: cmd, label: "Command+7", scope: .appMenuHighRisk, source: "app menu convention: tab 7"),
        Entry(keyCode: 28, modifiers: cmd, label: "Command+8", scope: .appMenuHighRisk, source: "app menu convention: tab 8"),
        Entry(keyCode: 25, modifiers: cmd, label: "Command+9", scope: .appMenuHighRisk, source: "app menu convention: tab 9"),
        Entry(keyCode: 50, modifiers: cmd, label: "Command+`", scope: .appMenuHighRisk, source: "app menu convention: cycle windows"),
        Entry(keyCode: 123, modifiers: cmd, label: "Command+Left", scope: .appMenuHighRisk, source: "app menu convention: back"),
        Entry(keyCode: 124, modifiers: cmd, label: "Command+Right", scope: .appMenuHighRisk, source: "app menu convention: forward"),
    ]

    public static func matches(keyCode: UInt16, modifiers: ComboModifiers) -> [Entry] {
        let normalized = modifiers.intersection([.command, .control, .option, .shift])
        return entries.filter { entry in
            entry.keyCode == keyCode &&
            entry.modifiers.intersection([.command, .control, .option, .shift]) == normalized
        }
    }

    /// Combinations this product will never propose, regardless of conflict state.
    /// Chosen as `Control+Option+Shift+<letter>`: no system grab uses that prefix and
    /// it is unlikely to collide with an application menu binding.
    public static let candidatePrefix: ComboModifiers = [.control, .option, .shift]

    public static let candidateLetters: [Character] = [
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
        "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
    ]

    public static func candidateCombos() -> [KeyCombo] {
        candidateLetters.compactMap { letter in
            guard let code = KeyCodeNames.keyCode(forLetter: letter) else { return nil }
            return KeyCombo(keyCode: code, modifiers: candidatePrefix)
        }
    }
}

public enum ConflictScope: String, Codable, Sendable {
    case systemGlobal = "system_global"
    case appMenuHighRisk = "app_menu_high_risk"
    case userManaged = "user_managed"
    case thirdPartyUnknown = "third_party_unknown"
}

public enum ConflictStatus: String, Codable, Sendable {
    case occupied
    case potentialConflict = "potential_conflict"
    case noKnownConflict = "no_known_conflict"
    case unknown
}

public struct ConflictEvidence: Codable, Equatable, Sendable {
    public let scope: ConflictScope
    public let source: String
    public let detail: String
    public init(scope: ConflictScope, source: String, detail: String) {
        self.scope = scope; self.source = source; self.detail = detail
    }
}

public struct ConflictResult: Codable, Equatable, Sendable {
    public let status: ConflictStatus
    public let evidence: [ConflictEvidence]

    public init(status: ConflictStatus, evidence: [ConflictEvidence]) {
        self.status = status; self.evidence = evidence
    }

    /// True only for `noKnownConflict`. Deliberately named to prevent the UI from
    /// ever phrasing this as "this shortcut is free".
    public var isEligibleForAutomaticApply: Bool { status == .noKnownConflict }
}

public struct ConflictInputs: Sendable {
    /// Combos already registered by ShortcutSense itself.
    public var registeredCombos: Set<KeyCombo>
    /// Combos read from the target application's menu (nil when unreadable).
    public var targetMenuCombos: Set<KeyCombo>?
    /// Combos read from the frontmost application's menu (nil when unreadable).
    public var foregroundMenuCombos: Set<KeyCombo>?
    /// Combos enabled in `com.apple.symbolichotkeys` (nil when unreadable).
    public var symbolichotkeys: Set<KeyCombo>?
    /// Combos the user has confirmed are taken by a third-party tool.
    public var userReportedTaken: Set<KeyCombo>

    public init(registeredCombos: Set<KeyCombo> = [],
                targetMenuCombos: Set<KeyCombo>? = nil,
                foregroundMenuCombos: Set<KeyCombo>? = nil,
                symbolichotkeys: Set<KeyCombo>? = nil,
                userReportedTaken: Set<KeyCombo> = []) {
        self.registeredCombos = registeredCombos
        self.targetMenuCombos = targetMenuCombos
        self.foregroundMenuCombos = foregroundMenuCombos
        self.symbolichotkeys = symbolichotkeys
        self.userReportedTaken = userReportedTaken
    }
}

/// Four-state conflict resolution with layered evidence.
public struct ConflictResolver: Sendable {
    public init() {}

    public func evaluate(_ combo: KeyCombo, inputs: ConflictInputs) -> ConflictResult {
        var evidence: [ConflictEvidence] = []

        // 1. Static system knowledge.
        for entry in SystemShortcuts.matches(keyCode: combo.keyCode, modifiers: combo.modifiers) {
            evidence.append(ConflictEvidence(scope: entry.scope, source: entry.source, detail: entry.label))
        }

        // 2. Our own registrations.
        if inputs.registeredCombos.contains(combo) {
            evidence.append(ConflictEvidence(scope: .userManaged, source: "ShortcutSense registry",
                                             detail: "already registered by ShortcutSense"))
        }

        // 3. User-confirmed third-party occupation.
        if inputs.userReportedTaken.contains(combo) {
            evidence.append(ConflictEvidence(scope: .thirdPartyUnknown, source: "user report",
                                             detail: "user confirmed another tool uses this"))
        }

        // 4. Dynamic system toggles, when readable.
        if let enabled = inputs.symbolichotkeys, enabled.contains(combo) {
            evidence.append(ConflictEvidence(scope: .systemGlobal, source: "com.apple.symbolichotkeys",
                                             detail: "enabled system symbolic hotkey"))
        }

        // 5. Application menus, when readable.
        if let target = inputs.targetMenuCombos, target.contains(combo) {
            evidence.append(ConflictEvidence(scope: .appMenuHighRisk, source: "target app menu",
                                             detail: "already bound in the target application's menu"))
        }
        if let foreground = inputs.foregroundMenuCombos, foreground.contains(combo) {
            evidence.append(ConflictEvidence(scope: .appMenuHighRisk, source: "frontmost app menu",
                                             detail: "already bound in the frontmost application's menu"))
        }

        let status = Self.status(for: evidence, inputs: inputs)
        return ConflictResult(status: status, evidence: evidence)
    }

    private static func status(for evidence: [ConflictEvidence], inputs: ConflictInputs) -> ConflictStatus {
        if evidence.contains(where: { $0.scope == .systemGlobal || $0.scope == .userManaged }) {
            return .occupied
        }
        if evidence.contains(where: { $0.scope == .thirdPartyUnknown }) {
            return .unknown
        }
        if evidence.contains(where: { $0.scope == .appMenuHighRisk }) {
            return .potentialConflict
        }
        // No negative evidence. If we could not read the sources that would tell us
        // about third-party global tools, the honest answer is `unknown`.
        let canSeeSystemState = inputs.symbolichotkeys != nil
        let canSeeMenus = inputs.targetMenuCombos != nil && inputs.foregroundMenuCombos != nil
        if canSeeSystemState && canSeeMenus { return .noKnownConflict }
        return .unknown
    }
}
