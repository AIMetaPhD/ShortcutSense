import Foundation

/// Everything the capture pipeline needs to know about the current system state.
/// Kept as a value type so gate decisions are pure and testable.
public struct CaptureContext: Equatable, Sendable {
    public var hasInputMonitoringPermission: Bool
    public var isPaused: Bool
    public var isScreenLocked: Bool
    public var isSecureInputEnabled: Bool
    public var foregroundBundleID: String?
    public var excludedBundleIDs: Set<String>

    public init(hasInputMonitoringPermission: Bool = false,
                isPaused: Bool = false,
                isScreenLocked: Bool = false,
                isSecureInputEnabled: Bool = false,
                foregroundBundleID: String? = nil,
                excludedBundleIDs: Set<String> = []) {
        self.hasInputMonitoringPermission = hasInputMonitoringPermission
        self.isPaused = isPaused
        self.isScreenLocked = isScreenLocked
        self.isSecureInputEnabled = isSecureInputEnabled
        self.foregroundBundleID = foregroundBundleID
        self.excludedBundleIDs = excludedBundleIDs
    }
}

public enum GateDecision: Equatable, Sendable {
    /// Safe to aggregate this keystroke for `bundleID`.
    case allow(bundleID: String)
    /// Do not record anything.
    case drop(reason: DropReason)
}

public enum DropReason: String, Equatable, Sendable {
    case noInputMonitoringPermission
    case paused
    case screenLocked
    case secureInput
    case unknownForegroundApp
    case excludedApp
    case ownApplication
}

/// The single entry point for "may we record this?".
///
/// Invariants (verified by `PrivacyGateTests`):
/// - Fails closed: any unknown or negative state means *drop*.
/// - Evaluated before anything is written, logged, or sent to a model.
public struct PrivacyGate: Sendable {
    /// Bundle identifier of ShortcutSense itself; never captured.
    public static let ownBundleID = "com.aimetaphd.shortcutsense"

    public init() {}

    public func decide(_ context: CaptureContext) -> GateDecision {
        guard context.hasInputMonitoringPermission else { return .drop(reason: .noInputMonitoringPermission) }
        guard !context.isPaused else { return .drop(reason: .paused) }
        guard !context.isScreenLocked else { return .drop(reason: .screenLocked) }
        guard !context.isSecureInputEnabled else { return .drop(reason: .secureInput) }
        guard let bundleID = context.foregroundBundleID, !bundleID.isEmpty else {
            return .drop(reason: .unknownForegroundApp)
        }
        guard bundleID != Self.ownBundleID else { return .drop(reason: .ownApplication) }
        guard !context.excludedBundleIDs.contains(bundleID) else { return .drop(reason: .excludedApp) }
        return .allow(bundleID: bundleID)
    }

    /// Menu-click observation is only permitted for allow-listed applications and
    /// only when the gate would allow keystroke capture at all.
    public func decideMenuObservation(_ context: CaptureContext, bundleID: String) -> GateDecision {
        switch decide(context) {
        case .drop(let reason): return .drop(reason: reason)
        case .allow:
            guard MenuAllowlist.isAllowed(bundleID) else { return .drop(reason: .excludedApp) }
            return .allow(bundleID: bundleID)
        }
    }
}

/// Applications whose menus may be inspected by the experimental AX menu observer.
/// Only apps with stable, static, system-provided menu titles belong here.
public enum MenuAllowlist {
    public static let bundleIDs: Set<String> = [
        "com.apple.finder",
        "com.google.Chrome",
        "com.apple.Safari",
    ]

    public static func isAllowed(_ bundleID: String) -> Bool { bundleIDs.contains(bundleID) }
}

/// Built-in sensitive applications excluded by default.
///
/// These identifiers must be confirmed on the target macOS version before release
/// (see `docs/verification/macOS-spikes.md`). Unknown identifiers are harmless: the
/// exclusion simply never matches.
public enum SensitiveApps {
    public static let defaults: [DefaultExclusion] = [
        DefaultExclusion(bundleID: "com.apple.keychainaccess", displayName: "Keychain Access"),
        DefaultExclusion(bundleID: "com.1password.1password", displayName: "1Password"),
        DefaultExclusion(bundleID: "com.1password.1password7", displayName: "1Password 7"),
        DefaultExclusion(bundleID: "com.bitwarden.desktop", displayName: "Bitwarden"),
        DefaultExclusion(bundleID: "com.lastpass.LastPass", displayName: "LastPass"),
        DefaultExclusion(bundleID: "com.apple.SecurityAgent", displayName: "Security Agent"),
        DefaultExclusion(bundleID: "com.apple.loginwindow", displayName: "Login Window"),
        DefaultExclusion(bundleID: "com.apple.ScreenSaver.Engine", displayName: "Screen Saver"),
        DefaultExclusion(bundleID: "com.apple.Terminal", displayName: "Terminal"),
        DefaultExclusion(bundleID: "com.googlecode.iterm2", displayName: "iTerm2"),
        DefaultExclusion(bundleID: "dev.warp.Warp-Stable", displayName: "Warp"),
        DefaultExclusion(bundleID: "com.microsoft.VSCode", displayName: "Visual Studio Code"),
        DefaultExclusion(bundleID: "com.apple.systempreferences", displayName: "System Settings"),

        // System consent and privilege UI. Observed on a real Mac: granting Input
        // Monitoring produced an activation row for `universalAccessAuthWarn`, i.e.
        // the permission dialog itself was being counted as app behaviour. These are
        // not applications the user chose to use, and counting them would pollute
        // recommendations with a "frequently used app" nobody ever opened.
        DefaultExclusion(bundleID: "com.apple.accessibility.universalAccessAuthWarn",
                         displayName: "Accessibility consent dialog"),
        DefaultExclusion(bundleID: "com.apple.UserNotificationCenter",
                         displayName: "User notification centre"),
        DefaultExclusion(bundleID: "com.apple.SecurityAgent", displayName: "Security agent"),
        DefaultExclusion(bundleID: "com.apple.CoreServicesUIAgent",
                         displayName: "Core services UI agent"),
        DefaultExclusion(bundleID: "com.apple.appkit.xpc.openAndSavePanelService",
                         displayName: "Open/Save panel"),
        DefaultExclusion(bundleID: "com.apple.printcenter",
                         displayName: "Print centre"),
        DefaultExclusion(bundleID: "com.apple.notificationcenterui",
                         displayName: "Notification centre"),
        DefaultExclusion(bundleID: "com.apple.controlcenter",
                         displayName: "Control Centre"),
        DefaultExclusion(bundleID: "com.apple.Spotlight",
                         displayName: "Spotlight"),
    ] + codeAndCredentialToolBundleIDs
        .sorted()
        .map { DefaultExclusion(bundleID: $0,
                                displayName: codeAndCredentialToolDisplayNames[$0] ?? $0) }

    /// Tools whose input is predominantly code, prompts or credentials.
    ///
    /// Observed on the owner's Mac: `com.openai.codex` produced keystroke and
    /// activation rows during a normal session. Anything typed into an AI assistant,
    /// editor, IDE or API client is far more likely to contain a secret than ordinary
    /// prose.
    ///
    /// Deliberately broad rather than minimal: a missing entry leaks, while an extra
    /// entry only means the user re-includes an app they care about.
    public static let codeAndCredentialToolBundleIDs: Set<String> = [
        // AI assistants and agents
        "com.openai.codex",
        "com.anthropic.claude",
        "com.openai.chat",
        // Editors and IDEs
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.goland",
        "com.jetbrains.CLion",
        "com.jetbrains.rider",
        // Terminals and shells
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        // API and credential clients
        "com.postmanlabs.postman",
        "com.github.GitHubClient",
        // Password managers beyond those listed individually above
        "com.dashlane.dashlane",
        "com.keepersecurity.passwordmanager",
        "com.enpass.Enpass",
    ]

    private static let codeAndCredentialToolDisplayNames: [String: String] = [
        "com.openai.codex": "Codex",
        "com.anthropic.claude": "Claude",
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
        "com.postmanlabs.postman": "Postman",
        "com.github.GitHubClient": "GitHub Desktop",
        "com.googlecode.iterm2": "iTerm2",
        "dev.warp.Warp-Stable": "Warp",
        "com.apple.Terminal": "Terminal",
    ]

    /// Terminal-class apps: excluded by default but re-includable by an informed user.
    ///
    /// A subset of `codeAndCredentialToolBundleIDs`, defined here so the UI can offer
    /// re-inclusion for exactly these apps. It is asserted to be a subset in tests, so
    /// the two lists cannot drift apart.
    public static let terminalClassBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
    ]
}
