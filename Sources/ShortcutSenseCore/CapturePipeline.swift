import Foundation

/// Source of raw input events. The macOS implementation wraps a listen-only
/// `CGEventTap`; tests drive `handle` directly with synthetic events.
public protocol RawEventSource: AnyObject {
    func start()
    func stop()
}

/// A raw keystroke as delivered by the platform. This value must not be persisted.
public struct RawKeyEvent: Equatable, Sendable {
    public let keyCode: UInt16
    public let modifiers: ComboModifiers
    public let isKeyDown: Bool

    public init(keyCode: UInt16, modifiers: ComboModifiers, isKeyDown: Bool = true) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.isKeyDown = isKeyDown
    }
}

/// Feeds platform events through the privacy gate into aggregate storage.
///
/// The pipeline never stores a raw event. Each event is either dropped, counted
/// anonymously, or aggregated as a normalized command combination.
public final class CapturePipeline {
    private let store: Store
    private let gate: PrivacyGate
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    private let onAttributionNote: (String) -> Void

    public private(set) var context: CaptureContext
    public var attributionBuffer = AttributionBuffer()

    /// Called on every key event, immediately before the gate runs, to refresh the
    /// volatile parts of the context (foreground app, secure input, lock state).
    ///
    /// The app polls these every couple of seconds for the UI, but a poll interval is
    /// not good enough for Secure Input: a password field can gain focus between two
    /// polls and keystrokes would still be counted. Checking here bounds the exposure
    /// to the single event in flight.
    public var refreshVolatileState: ((inout CaptureContext) -> Void)?

    private func liveContext() -> CaptureContext {
        guard let refreshVolatileState else { return context }
        var live = context
        refreshVolatileState(&live)
        return live
    }

    /// Most recent verified navigation combo, kept only in memory.
    public private(set) var lastNavigationComboID: String?

    /// Diagnostic counters, in memory only, reported by `--diagnose`.
    ///
    /// They record *categories*, never key codes or text, so this cannot become a
    /// keystroke log. They exist because a silent classification failure is
    /// indistinguishable from "the user typed no shortcuts" without them.
    public struct Diagnostics: Sendable {
        public var eventsSeen = 0
        public var dropped = 0
        public var modifierOnly = 0
        public var textInput = 0
        public var commandShortcut = 0
        public var lastDropReason: String?
        public var lastModifierRawValue: UInt32 = 0
        public var lastClassification = ""
    }
    public private(set) var diagnostics = Diagnostics()

    public init(store: Store, gate: PrivacyGate = PrivacyGate(),
                context: CaptureContext = CaptureContext(),
                now: @escaping () -> Date = Date.init,
                timeZone: @escaping () -> TimeZone = { .current },
                onAttributionNote: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.gate = gate
        self.context = context
        self.now = now
        self.timeZone = timeZone
        self.onAttributionNote = onAttributionNote
    }

    public func updateContext(_ mutate: (inout CaptureContext) -> Void) {
        mutate(&context)
    }

    // MARK: - Keystrokes

    /// Processes one key-down event. Returns the classification for diagnostics only
    /// (the classification never contains persisted text).
    @discardableResult
    public func handle(_ event: RawKeyEvent) -> KeyEventClassification? {
        guard event.isKeyDown else { return nil }
        diagnostics.eventsSeen += 1
        diagnostics.lastModifierRawValue = event.modifiers.rawValue
        let decision = gate.decide(liveContext())
        guard case .allow(let bundleID) = decision else {
            diagnostics.dropped += 1
            if case .drop(let reason) = decision { diagnostics.lastDropReason = reason.rawValue }
            return nil
        }

        let classification = KeyCombo.classify(keyCode: event.keyCode, modifiers: event.modifiers)
        let date = DateBuckets.bucket(for: now(), timeZone: timeZone())

        switch classification {
        case .modifierOnly:
            diagnostics.modifierOnly += 1
            diagnostics.lastClassification = "modifierOnly"
            return classification
        case .textInput:
            diagnostics.textInput += 1
            diagnostics.lastClassification = "textInput"
            try? store.incrementAnonymousKeystrokes(date: date, bundleID: bundleID)
            return classification
        case .commandShortcut(let combo):
            diagnostics.commandShortcut += 1
            diagnostics.lastClassification = "commandShortcut"
            try? store.incrementCombo(date: date, bundleID: bundleID, comboID: combo.comboID)
            if NavigationShortcuts.isNavigation(combo) {
                lastNavigationComboID = combo.comboID
                attributionBuffer.noteNavigation(comboID: combo.comboID,
                                                 at: ProcessInfo.processInfo.systemUptime)
            }
            return classification
        }
    }

    // MARK: - App activation

    /// Classifies an app activation and persists only the aggregate counter.
    ///
    /// The activation itself is the authoritative statement about which app is now
    /// frontmost, so the context is updated *before* gating. Everything else
    /// (pause, lock, secure input, exclusion, permissions) still fails closed.
    public func handleAppActivation(bundleID: String) {
        context.foregroundBundleID = bundleID
        guard case .allow = gate.decide(context) else { return }

        let date = DateBuckets.bucket(for: now(), timeZone: timeZone())
        let origin = attributionBuffer.classifyActivation(
            bundleID: bundleID, at: ProcessInfo.processInfo.systemUptime)

        switch origin {
        case .managedHotkey(let shortcutID, _):
            try? store.incrementActivity(date: date, bundleID: bundleID, field: .managedHotkeyActivations)
            try? store.recordShortcutSuccessfulActivation(shortcutID: shortcutID, date: date)
        case .observedKeyboardNavigation:
            try? store.incrementActivity(date: date, bundleID: bundleID, field: .observedKeyboardNavigation)
        case .unknownOrigin:
            try? store.incrementActivity(date: date, bundleID: bundleID, field: .unknownOriginActivations)
        }
    }

    /// Called by the managed-hotkey handler so the next activation can be attributed.
    public func noteManagedHotkey(shortcutID: String, targetBundleID: String) {
        _ = attributionBuffer.noteManagedHotkey(
            targetBundleID: targetBundleID, shortcutID: shortcutID,
            at: ProcessInfo.processInfo.systemUptime)
    }

    /// Clears the in-memory predecessor state. Must be called when the user deletes
    /// all data, so a stale 1.5 s token cannot attribute a fresh activation.
    public func clearNavigationState() {
        lastNavigationComboID = nil
        attributionBuffer.reset()
    }

    public func expireAttribution() {
        attributionBuffer.expire(at: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - Menu observation

    /// Records a verified menu click. Only called after the platform layer has
    /// confirmed the hit-tested element was an `AXMenuItem` in an allow-listed app.
    public func handleVerifiedMenuClick(bundleID: String, commandID: String,
                                        safeLabel: String?, knownShortcut: String?) {
        guard case .allow = gate.decideMenuObservation(liveContext(), bundleID: bundleID) else { return }
        let date = DateBuckets.bucket(for: now(), timeZone: timeZone())
        try? store.incrementMenuAction(
            date: date, bundleID: bundleID, commandID: commandID,
            safeLabel: safeLabel, knownShortcut: knownShortcut,
            provenance: .verifiedAXClick)
    }

    /// Records an explicit user mark. Never increments click counts.
    public func handleManualMark(bundleID: String, commandID: String,
                                 safeLabel: String?, knownShortcut: String?) {
        // A user marking a menu command is still a decision to record data about an
        // app; it must respect pause, lock, exclusion and permission like everything
        // else, rather than becoming a gate bypass.
        guard case .allow = gate.decideMenuObservation(liveContext(), bundleID: bundleID) else { return }
        let date = DateBuckets.bucket(for: now(), timeZone: timeZone())
        try? store.incrementMenuAction(
            date: date, bundleID: bundleID, commandID: commandID,
            safeLabel: safeLabel, knownShortcut: knownShortcut,
            provenance: .explicitManualMark)
    }
}

/// Combinations that switch applications or windows. Only these can be the
/// "predecessor" of an app activation.
public enum NavigationShortcuts {
    private static let combos: Set<KeyCombo> = [
        KeyCombo(keyCode: 48, modifiers: .command),                    // Cmd+Tab
        KeyCombo(keyCode: 48, modifiers: [.command, .shift]),          // Cmd+Shift+Tab
        KeyCombo(keyCode: 50, modifiers: .command),                    // Cmd+`
        KeyCombo(keyCode: 123, modifiers: [.control, .command]),       // Ctrl+Cmd+Left
        KeyCombo(keyCode: 124, modifiers: [.control, .command]),       // Ctrl+Cmd+Right
    ]

    public static func isNavigation(_ combo: KeyCombo) -> Bool { combos.contains(combo) }
}
