import AppKit
import Foundation
import ShortcutSenseCore

/// Wires the platform sources to the platform-independent core.
///
/// All mutable state is touched on the main thread; SQLite access is serialized
/// inside `Store`, so a slow write never blocks the event tap callback.
@MainActor
final class AppController {
    static let shared = AppController()

    let store: Store
    let pipeline: CapturePipeline
    let actionManager: ShortcutActionManager
    let weeklyService: WeeklyReviewService

    private let eventTap = EventTapSource()
    private let backend = CarbonHotkeyBackend()
    private let launcher = AppLauncherMac()
    private var activationObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var attributionTimer: Timer?
    private lazy var aiService = OptionalAI(transport: OllamaTransport())

    private(set) var lastRestore: ShortcutActionManager.RestoreOutcome?
    private(set) var lastTapStatus: EventTapSource.TapStatus = .stopped
    private(set) var menuObservationEnabled = false
    private var hasRequestedPermissions = false

    /// Menu observation is only switched on when the spike proved it works.
    /// Defaults to false so a build without spike evidence never claims to Learn.
    var menuObservationSupported = false

    var onStateChange: (() -> Void)?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShortcutSense", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let databaseURL = support.appendingPathComponent("ShortcutSense.sqlite")

        do {
            store = try Store(path: databaseURL.path)
        } catch {
            // A broken database must not silently start a fresh one and lose the
            // user's data; surface it and exit rather than guessing.
            fatalError("ShortcutSense could not open its database: \(error)")
        }

        try? store.seedDefaultExclusions(SensitiveApps.defaults)

        pipeline = CapturePipeline(store: store)
        actionManager = ShortcutActionManager(store: store, backend: backend, launcher: launcher)
        weeklyService = WeeklyReviewService(store: store)
    }

    // MARK: - Lifecycle

    func start() {
        // Secure input, lock state and the frontmost app must be current at the
        // instant of each event, not up to two seconds stale from the UI poll.
        pipeline.refreshVolatileState = { [weak self] context in
            context.isSecureInputEnabled = Permissions.isSecureInputEnabled()
            context.isScreenLocked = Permissions.isScreenLocked()
            context.foregroundBundleID = AppLauncherMac.frontmostBundleID()
            if let self { context.excludedBundleIDs = Set(self.store.excludedBundleIDs()) }
        }
        refreshContext()
        pipeline.updateContext { context in
            context.excludedBundleIDs = Set(store.excludedBundleIDs())
        }

        eventTap.onKeyDown = { [weak self] event in self?.pipeline.handle(event) }
        eventTap.onStatusChange = { [weak self] status in
            self?.lastTapStatus = status
            self?.onStateChange?()
        }
        eventTap.onLeftMouseUp = { [weak self] point in self?.handleMouseUp(at: point) }
        eventTap.start()
        requestMissingPermissionsIfNeeded()

        actionManager.onTrigger = { [weak self] shortcutID, target in
            self?.pipeline.noteManagedHotkey(shortcutID: shortcutID, targetBundleID: target)
        }

        observeActivations()
        startTimers()
        lastRestore = actionManager.restoreOnLaunch()
        recordFirstCollectionIfNeeded()
        onStateChange?()
    }

    func stop() {
        eventTap.stop()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        permissionTimer?.invalidate()
        attributionTimer?.invalidate()
        store.close()
    }

    /// Registers the app in the Input Monitoring / Accessibility panes.
    ///
    /// `CGPreflightListenEventAccess()` only *reads* state and never adds the app to
    /// TCC, so a user who follows "open System Settings → Input Monitoring" can find
    /// the list empty and have nothing to switch on. `CGRequestListenEventAccess()`
    /// and `AXIsProcessTrustedWithOptions(prompt)` are the calls that register it.
    ///
    /// Only the missing grants are requested, and only once per launch: macOS shows
    /// its own consent UI and repeating the call does not help.
    private func requestMissingPermissionsIfNeeded() {
        guard !hasRequestedPermissions else { return }
        hasRequestedPermissions = true
        if Permissions.inputMonitoringStatus() != .granted {
            _ = Permissions.requestInputMonitoring()
        }
        if Permissions.accessibilityStatus() != .granted {
            _ = Permissions.requestAccessibility()
        }
    }

    private func recordFirstCollectionIfNeeded() {
        guard store.firstCollectionStartedAt() == nil,
              Permissions.inputMonitoringStatus() == .granted else { return }
        try? store.markFirstCollectionStarted(at: Date(), timeZone: .current)
    }

    private func startTimers() {
        // Permission and session state change without notification; poll cheaply.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refreshContext() }
        }
        // Expire stale attribution tokens so they cannot leak across activations.
        attributionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.pipeline.expireAttribution() }
        }
    }

    private func refreshContext() {
        let snapshot = Permissions.snapshot()
        pipeline.updateContext { context in
            context.hasInputMonitoringPermission = snapshot.inputMonitoring == .granted
            context.isScreenLocked = snapshot.screenLocked
            context.isSecureInputEnabled = snapshot.secureInputEnabled
            context.foregroundBundleID = AppLauncherMac.frontmostBundleID()
            context.excludedBundleIDs = Set(self.store.excludedBundleIDs())
            context.isPaused = self.isPaused
        }
        if snapshot.inputMonitoring == .granted {
            recordFirstCollectionIfNeeded()
            // The user may have granted permission in System Settings after launch.
            // Nothing else starts the tap, so without this the UI would say
            // "Collecting" while no tap exists and nothing is recorded.
            if eventTap.status != .running {
                eventTap.start()
            }
        }
    }

    private func observeActivations() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { notification in
            guard let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                                    as? NSRunningApplication)?.bundleIdentifier else { return }
            Task { @MainActor [weak self] in
                self?.refreshContext()
                self?.pipeline.handleAppActivation(bundleID: bundleID)
            }
        }
    }

    private func handleMouseUp(at point: CGPoint) {
        guard menuObservationEnabled, menuObservationSupported else { return }
        guard let bundleID = AppLauncherMac.frontmostBundleID(),
              MenuAllowlist.isAllowed(bundleID) else { return }
        guard let element = MenuObserver.menuItemAt(point: point),
              let described = MenuObserver.describe(element),
              let title = described.title,
              MenuObserver.isSafeStaticTitle(title) else { return }
        pipeline.handleVerifiedMenuClick(
            bundleID: bundleID,
            commandID: MenuObserver.commandID(path: [], title: title),
            safeLabel: title, knownShortcut: described.shortcut)
    }

    // MARK: - Settings surface

    var isPaused: Bool {
        get { store.metadata(MetadataKey.isPaused) == "1" }
        set {
            try? store.setMetadata(MetadataKey.isPaused, newValue ? "1" : "0")
            refreshContext()
            onStateChange?()
        }
    }

    var isAIEnabled: Bool {
        get { store.metadata(MetadataKey.aiEnabled) == "1" }
        set {
            try? store.setMetadata(MetadataKey.aiEnabled, newValue ? "1" : "0")
            onStateChange?()
        }
    }

    var aiEndpoint: URL? {
        get { store.metadata(MetadataKey.aiEndpoint).flatMap(URL.init(string:)) }
        set { try? store.setMetadata(MetadataKey.aiEndpoint, newValue?.absoluteString ?? "") }
    }

    /// Requests an explanation for a candidate. Returns the deterministic template
    /// whenever AI is off, unreachable, slow, or returns anything unexpected.
    func explain(_ request: AIExplanationRequest) -> AIExplanation {
        let template = OptionalAI.template(for: request)
        guard isAIEnabled, let endpoint = aiEndpoint else { return template }
        let target = OllamaTransport.generateEndpoint(from: endpoint)
        return (try? aiService.explain(request, enabled: true, endpoint: target)) ?? template
    }

    func setExcluded(bundleID: String, excluded: Bool) {
        if excluded {
            try? store.addExcludedApp(bundleID: bundleID, displayName: nil, source: .user)
        } else {
            try? store.removeExcludedApp(bundleID: bundleID, source: .user)
        }
        refreshContext()
        onStateChange?()
    }

    func deleteAllData() {
        // Release OS hotkeys first: their handlers stay alive independently of the
        // database and would otherwise keep launching apps and writing new rows for
        // an id that no longer exists.
        actionManager.releaseAllRegistrations()
        pipeline.attributionBuffer.reset()
        pipeline.clearNavigationState()
        try? store.deleteAllData()
        try? store.seedDefaultExclusions(SensitiveApps.defaults)
        refreshContext()
        onStateChange?()
    }

    func undo(shortcutID: String) throws {
        try actionManager.undo(shortcutID: shortcutID)
    }

    func apply(recommendation: Recommendation, combo: KeyCombo,
               conflict: ConflictResult) throws -> RegisteredShortcut {
        try actionManager.apply(recommendation: recommendation, combo: combo, conflict: conflict)
    }

    var permissionSnapshot: PermissionSnapshot { Permissions.snapshot() }

    // MARK: - Conflict inputs

    /// Builds conflict inputs from what can actually be read right now. Unreadable
    /// sources stay `nil`, which makes the resolver answer `unknown`.
    func conflictInputs(targetBundleID: String?) -> ConflictInputs {
        let registered = Set((try? store.registeredShortcuts(activeOnly: true))?.map(\.combo) ?? [])

        var targetMenu: Set<KeyCombo>?
        if let targetBundleID,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == targetBundleID }) {
            let commands = MenuObserver.readMenuCommands(pid: app.processIdentifier)
            if !commands.isEmpty {
                targetMenu = Set(commands.compactMap { $0.shortcut.flatMap(KeyComboCodec.decode) })
            }
        }

        var foregroundMenu: Set<KeyCombo>?
        if let foreground = NSWorkspace.shared.frontmostApplication {
            let commands = MenuObserver.readMenuCommands(pid: foreground.processIdentifier)
            if !commands.isEmpty {
                foregroundMenu = Set(commands.compactMap { $0.shortcut.flatMap(KeyComboCodec.decode) })
            }
        }

        return ConflictInputs(
            registeredCombos: registered,
            targetMenuCombos: targetMenu,
            foregroundMenuCombos: foregroundMenu,
            symbolichotkeys: MenuObserver.enabledSymbolicHotkeys(),
            userReportedTaken: [])
    }
}
