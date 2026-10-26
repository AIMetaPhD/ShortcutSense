import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Independent permission probes. Input Monitoring and Accessibility are separate
/// TCC services and must never be collapsed into one switch in the UI.
enum PermissionStatus: String {
    case granted
    case denied
    case unknown
}

struct PermissionSnapshot {
    let inputMonitoring: PermissionStatus
    let accessibility: PermissionStatus
    let secureInputEnabled: Bool
    let screenLocked: Bool
    let capturedAt: Date

    var canCaptureKeys: Bool {
        inputMonitoring == .granted && !secureInputEnabled && !screenLocked
    }

    /// Human-readable diagnosis for Settings. Deliberately avoids promising that any
    /// `tccutil` command works — the service name must be verified on the target OS.
    var diagnosis: [String] {
        var lines: [String] = []
        switch inputMonitoring {
        case .granted:
            lines.append("Input Monitoring: granted (keystroke aggregation is possible).")
        case .denied:
            lines.append("Input Monitoring: not granted. Open System Settings → Privacy & Security → Input Monitoring and enable ShortcutSense.")
        case .unknown:
            lines.append("Input Monitoring: could not be determined. Check System Settings → Privacy & Security → Input Monitoring.")
        }
        switch accessibility {
        case .granted:
            lines.append("Accessibility: granted (menu reading is possible).")
        case .denied:
            lines.append("Accessibility: not granted. Menu discovery and conflict checks are limited; shortcuts still work.")
        case .unknown:
            lines.append("Accessibility: could not be determined.")
        }
        if secureInputEnabled { lines.append("Secure Input is active: collection is paused.") }
        if screenLocked { lines.append("Screen is locked: collection is paused.") }
        return lines
    }
}

enum Permissions {
    static func inputMonitoringStatus() -> PermissionStatus {
        // Preflight does not prompt and does not add the app to the TCC list.
        if CGPreflightListenEventAccess() { return .granted }
        return .denied
    }

    /// Requests Input Monitoring. macOS shows its own prompt; the return value is
    /// the state *after* the call, which is usually still `false` until the user
    /// flips the switch and relaunches.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    static func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func isSecureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// Returns `true` when the screen is locked **or the state cannot be determined**.
    ///
    /// The gate treats `true` as "do not record", so an unreadable session must fail
    /// closed rather than optimistically reporting "unlocked".
    static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool, locked { return true }
        return false
    }

    /// Opens the Input Monitoring pane. Kept here so the same deep link is used from
    /// the menu, the panel and Settings.
    static func openInputMonitoringSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            inputMonitoring: inputMonitoringStatus(),
            accessibility: accessibilityStatus(),
            secureInputEnabled: isSecureInputEnabled(),
            screenLocked: isScreenLocked(),
            capturedAt: Date())
    }
}
