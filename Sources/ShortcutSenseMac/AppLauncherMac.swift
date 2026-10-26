import AppKit
import Foundation
import ShortcutSenseCore

/// Launches or focuses an installed application by bundle identifier.
///
/// Uses `NSWorkspace` only; no AppleScript, no preference files of other apps, and
/// nothing is written outside ShortcutSense's own container.
final class AppLauncherMac: AppLauncher {
    private let workspace = NSWorkspace.shared

    func isInstalled(bundleID: String) -> Bool {
        workspace.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Returns `true` when the app was already running and has been activated,
    /// `false` when it had to be launched. The caller must not treat `false` as a
    /// confirmed activation — only the activation notification proves that.
    func activateOrLaunch(bundleID: String) throws -> Bool {
        guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            throw AppLaunchError.notInstalled(bundleID)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        let running = workspace.runningApplications.first { $0.bundleIdentifier == bundleID }
        if let running, running.activationPolicy != .prohibited {
            running.activate(options: [.activateAllWindows])
            return true
        }

        var launched = false
        var launchError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        workspace.openApplication(at: url, configuration: configuration) { _, error in
            launchError = error
            launched = true
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        if let launchError { throw AppLaunchError.activationFailed(String(describing: launchError)) }
        return !launched
    }

    /// Bundle identifier of the frontmost application, or nil when unknown.
    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Running applications that have a bundle identifier and a regular UI presence.
    static func runningBundleIDs() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
    }
}
