import Foundation

/// Monotonic clock abstraction so attribution windows are testable without sleeping.
public protocol MonotonicClock: Sendable {
    var now: TimeInterval { get }
}

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Short-lived, in-memory record of the last navigation keystroke or managed-hotkey
/// activation. Nothing here is ever persisted; it only classifies the *next* app
/// activation within a bounded window.
public struct AttributionBuffer: Sendable {
    public static let defaultWindow: TimeInterval = 1.5

    public struct PendingNavigation: Sendable {
        public let timestamp: TimeInterval
        public let comboID: String
    }

    public struct PendingManagedHotkey: Sendable {
        public let timestamp: TimeInterval
        public let targetBundleID: String
        public let shortcutID: String
        public let token: UUID
    }

    public private(set) var lastNavigation: PendingNavigation?
    public private(set) var lastManaged: PendingManagedHotkey?
    public let window: TimeInterval

    public init(window: TimeInterval = AttributionBuffer.defaultWindow) {
        self.window = window
    }

    public mutating func noteNavigation(comboID: String, at time: TimeInterval) {
        lastNavigation = PendingNavigation(timestamp: time, comboID: comboID)
    }

    public mutating func noteManagedHotkey(targetBundleID: String, shortcutID: String,
                                           at time: TimeInterval, token: UUID = UUID()) -> UUID {
        lastManaged = PendingManagedHotkey(timestamp: time, targetBundleID: targetBundleID,
                                           shortcutID: shortcutID, token: token)
        return token
    }

    /// Classifies an app activation and consumes the matching token.
    ///
    /// The result is a *heuristic*: it cannot distinguish Dock clicks from Raycast,
    /// system focus changes, or other launchers. `unknownOrigin` never means
    /// "the user clicked the Dock".
    public mutating func classifyActivation(bundleID: String, at time: TimeInterval) -> ActivationOrigin {
        if let managed = lastManaged, time - managed.timestamp <= window {
            lastManaged = nil
            lastNavigation = nil
            if managed.targetBundleID == bundleID {
                return .managedHotkey(shortcutID: managed.shortcutID, token: managed.token)
            }
            // A managed hotkey fired but a different app came forward. Treat as unknown.
            return .unknownOrigin
        }
        if let navigation = lastNavigation, time - navigation.timestamp <= window {
            lastNavigation = nil
            return .observedKeyboardNavigation(comboID: navigation.comboID)
        }
        return .unknownOrigin
    }

    /// Drops expired entries. Called on a timer so stale tokens cannot leak forward.
    public mutating func expire(at time: TimeInterval) {
        if let managed = lastManaged, time - managed.timestamp > window { lastManaged = nil }
        if let navigation = lastNavigation, time - navigation.timestamp > window { lastNavigation = nil }
    }

    public mutating func reset() {
        lastNavigation = nil
        lastManaged = nil
    }
}

public enum ActivationOrigin: Equatable, Sendable {
    case managedHotkey(shortcutID: String, token: UUID)
    case observedKeyboardNavigation(comboID: String)
    case unknownOrigin
}
