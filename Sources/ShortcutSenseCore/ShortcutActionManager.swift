import Foundation

public enum HotkeyRegistrationError: Error, Equatable, CustomStringConvertible {
    /// Carbon returned a non-zero `OSStatus`. -9878 is `eventHotKeyExistsErr`.
    case carbonError(Int32)
    case alreadyRegistered(KeyCombo)
    case conflictNotClear(ConflictStatus)
    case persistenceFailed(String)
    case unknownShortcut(String)

    public var description: String {
        switch self {
        case .carbonError(let status):
            let detail = status == -9878 ? " (eventHotKeyExistsErr)" : ""
            return "Carbon RegisterEventHotKey failed with OSStatus \(status)\(detail)"
        case .alreadyRegistered(let combo): return "\(combo.displayString) is already registered"
        case .conflictNotClear(let status): return "conflict status \(status.rawValue) does not allow automatic apply"
        case .persistenceFailed(let message): return "could not persist registration: \(message)"
        case .unknownShortcut(let id): return "unknown shortcut \(id)"
        }
    }
}

public enum HotkeyUnregistrationError: Error, Equatable, CustomStringConvertible {
    case carbonError(Int32)
    case notRegistered(String)
    public var description: String {
        switch self {
        case .carbonError(let status): return "Carbon UnregisterEventHotKey failed with OSStatus \(status)"
        case .notRegistered(let id): return "shortcut \(id) was not registered"
        }
    }
}

/// Abstracts the Carbon layer. The macOS implementation lives in `ShortcutSenseMac`;
/// tests use `FakeHotkeyBackend` to exercise failure and rollback paths.
public protocol HotkeyBackend: AnyObject {
    func register(_ combo: KeyCombo, shortcutID: String, handler: @escaping () -> Void)
        -> Result<Void, HotkeyRegistrationError>
    func unregister(shortcutID: String) -> Result<Void, HotkeyUnregistrationError>
    func isRegistered(shortcutID: String) -> Bool
}

/// Abstraction over launching/focusing an application.
public protocol AppLauncher: AnyObject {
    /// Returns true when the target is running and was activated, false when it had
    /// to be launched (activation not yet confirmed), or throws when unavailable.
    func activateOrLaunch(bundleID: String) throws -> Bool
    func isInstalled(bundleID: String) -> Bool
}

public enum AppLaunchError: Error, Equatable {
    case notInstalled(String)
    case activationFailed(String)
}

/// Applies, restores and undoes managed global hotkeys.
///
/// Contract:
/// - A shortcut is only persisted as active after the backend reports success.
/// - If persistence fails after registration, the registration is rolled back.
/// - Trigger counts are incremented exactly once per handler invocation, inside the
///   handler. Successful target activation is counted separately from activation
///   notifications, never in the handler.
public final class ShortcutActionManager {
    /// Synthetic status stored in `last_error_code` when the target app is missing.
    /// Negative values cannot collide with real Carbon `OSStatus` codes.
    public static let targetUnavailableCode: Int32 = -1001

    private let store: Store
    private let backend: HotkeyBackend
    private let launcher: AppLauncher
    private let clock: MonotonicClock
    private let timeZone: () -> TimeZone
    private let now: () -> Date
    private let onStateChange: () -> Void

    /// Called synchronously on every physical key press, before activation is
    /// attempted. The app layer wires this to the capture pipeline so the following
    /// activation can be attributed to this shortcut.
    public var onTrigger: ((_ shortcutID: String, _ targetBundleID: String) -> Void)?

    public init(store: Store, backend: HotkeyBackend, launcher: AppLauncher,
                clock: MonotonicClock = SystemMonotonicClock(),
                timeZone: @escaping () -> TimeZone = { .current },
                now: @escaping () -> Date = Date.init,
                onStateChange: @escaping () -> Void = {}) {
        self.store = store
        self.backend = backend
        self.launcher = launcher
        self.clock = clock
        self.timeZone = timeZone
        self.now = now
        self.onStateChange = onStateChange
    }

    // MARK: - Apply

    @discardableResult
    public func apply(recommendation: Recommendation, combo: KeyCombo,
                      conflict: ConflictResult) throws -> RegisteredShortcut {
        guard conflict.isEligibleForAutomaticApply else {
            throw HotkeyRegistrationError.conflictNotClear(conflict.status)
        }
        if let existing = try store.registeredShortcuts(activeOnly: true).first(where: { $0.combo == combo }) {
            throw HotkeyRegistrationError.alreadyRegistered(existing.combo)
        }

        let shortcutID = UUID().uuidString
        let target = recommendation.bundleID

        switch backend.register(combo, shortcutID: shortcutID, handler: { [weak self] in
            self?.handleTrigger(shortcutID: shortcutID, targetBundleID: target)
        }) {
        case .failure(let error):
            throw error
        case .success:
            break
        }

        let record = RegisteredShortcut(
            id: shortcutID, recommendationID: recommendation.id,
            targetBundleID: target, keyCode: combo.keyCode,
            carbonModifiers: combo.modifiers.rawValue,
            displayCombo: combo.displayString, isActive: true,
            createdAt: DateBuckets.iso8601(now()), lastErrorCode: nil)

        do {
            // One transaction: a partially saved apply must not leave an active row.
            try store.applyRegistration(record, recommendationID: recommendation.id, now: now())
        } catch {
            // Rollback: the OS registration must not outlive a failed persistence step.
            _ = backend.unregister(shortcutID: shortcutID)
            throw HotkeyRegistrationError.persistenceFailed(String(describing: error))
        }
        onStateChange()
        return record
    }

    // MARK: - Undo

    public func undo(shortcutID: String, cooldownDays: Int = RecommendationThresholds.dismissalCooldownDays) throws {
        guard let record = try store.registeredShortcuts().first(where: { $0.id == shortcutID }) else {
            throw HotkeyRegistrationError.unknownShortcut(shortcutID)
        }
        if backend.isRegistered(shortcutID: shortcutID) {
            if case .failure(let error) = backend.unregister(shortcutID: shortcutID) {
                // Keep the database row active: the OS still holds the hotkey.
                try store.updateRegisteredShortcutActive(id: shortcutID, isActive: true,
                                                         errorCode: errorCode(for: error))
                onStateChange()
                throw error
            }
        }
        try store.deleteRegisteredShortcut(id: shortcutID)
        if let recommendationID = record.recommendationID {
            let cooldown = Calendar(identifier: .gregorian).date(
                byAdding: .day, value: cooldownDays, to: now())
            try store.setRecommendationStatus(
                id: recommendationID, status: .undone,
                cooldownUntil: cooldown.map(DateBuckets.iso8601), now: now())
        }
        onStateChange()
    }

    /// Releases every live registration without touching the database.
    ///
    /// Used before deleting all data: leaving OS grabs alive after the user asked for
    /// deletion would keep launching apps from a shortcut that no longer exists in
    /// the UI, and would immediately write fresh usage rows for a deleted id.
    public func releaseAllRegistrations() {
        for record in (try? store.registeredShortcuts()) ?? [] {
            if backend.isRegistered(shortcutID: record.id) {
                _ = backend.unregister(shortcutID: record.id)
            }
        }
    }

    // MARK: - Restore

    public struct RestoreOutcome: Sendable {
        public let restored: [String]
        public let failed: [(id: String, error: String)]
    }

    /// Re-registers persisted shortcuts at launch. Failures stay visible in the UI
    /// and are recorded with their OSStatus; they are never silently dropped.
    @discardableResult
    public func restoreOnLaunch() -> RestoreOutcome {
        var restored: [String] = []
        var failed: [(id: String, error: String)] = []
        let stored = (try? store.registeredShortcuts(activeOnly: true)) ?? []
        for record in stored {
            // Already live in this process (e.g. restore called twice): leave it alone
            // rather than asking Carbon to register the same hotkey again.
            if backend.isRegistered(shortcutID: record.id) {
                restored.append(record.id)
                continue
            }
            guard launcher.isInstalled(bundleID: record.targetBundleID) else {
                try? store.updateRegisteredShortcutActive(id: record.id, isActive: false,
                                                          errorCode: ShortcutActionManager.targetUnavailableCode)
                failed.append((record.id, "target application not installed: \(record.targetBundleID)"))
                continue
            }
            let result = backend.register(record.combo, shortcutID: record.id, handler: { [weak self] in
                self?.handleTrigger(shortcutID: record.id, targetBundleID: record.targetBundleID)
            })
            switch result {
            case .success:
                try? store.updateRegisteredShortcutActive(id: record.id, isActive: true, errorCode: nil)
                restored.append(record.id)
            case .failure(let error):
                let code: Int32
                if case .carbonError(let status) = error { code = status } else { code = -1 }
                try? store.updateRegisteredShortcutActive(id: record.id, isActive: false, errorCode: code)
                failed.append((record.id, error.description))
            }
        }
        onStateChange()
        return RestoreOutcome(restored: restored, failed: failed)
    }

    // MARK: - Trigger handling

    /// Called from the backend on a physical key press. Exactly one call per press.
    ///
    /// Only `trigger_count` is incremented here. `successful_target_activation_count`
    /// is incremented exclusively by the app-activation observer, so a single press
    /// can never be counted twice — even when the target is already frontmost and
    /// no activation notification arrives (the counters then legitimately diverge,
    /// which the UI shows as a mismatch rather than hiding).
    public func handleTrigger(shortcutID: String, targetBundleID: String) {
        let date = DateBuckets.bucket(for: now(), timeZone: timeZone())
        try? store.recordShortcutTrigger(shortcutID: shortcutID, date: date)
        onTrigger?(shortcutID, targetBundleID)
        do {
            _ = try launcher.activateOrLaunch(bundleID: targetBundleID)
        } catch {
            // Activation failure is visible through the trigger/success mismatch.
        }
    }

    private func errorCode(for error: HotkeyUnregistrationError) -> Int32 {
        switch error {
        case .carbonError(let status): return status
        case .notRegistered: return -1
        }
    }
}
