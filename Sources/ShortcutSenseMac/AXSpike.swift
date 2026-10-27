import AppKit
import ApplicationServices
import Foundation
import ShortcutSenseCore

/// `ShortcutSense --ax-spike` answers the G-B question without a human clicking.
///
/// The gate asks whether a real mouse click on a menu item can be identified as an
/// `AXMenuItem`. That decomposes into two measurable facts:
///
/// 1. **Reachability** — with a menu open, does `AXUIElementCopyElementAtPosition` at
///    a menu item's own coordinates return that item? If not, no timing trick helps.
/// 2. **Post-click timing** — after the click is delivered, is the menu still in the
///    AX tree at the same coordinates, or has it already closed?
///
/// The spike opens menus through `AXPress` and posts synthetic clicks at the measured
/// coordinates, so it exercises the same code path the product would use. It is
/// labelled synthetic: this measures the *API's* behaviour, not a human's clicking.
enum AXSpike {
    struct TargetResult: Codable {
        let app: String
        let menuTitle: String
        let itemsTested: Int
        let reachableHits: Int
        let postClickHits: Int
        let sampleLabels: [String]
    }

    struct Report: Codable {
        let startedAt: String
        let accessibilityGranted: Bool
        let targets: [TargetResult]
        let verdict: String
        let notes: [String]
    }

    /// Applications to probe. Finder and Safari ship with macOS; Chrome is probed
    /// only if it is running.
    private static var candidateBundleIDs: [String] {
        ["com.apple.finder", "com.google.Chrome", "com.apple.Safari"]
    }

    /// Prints every static menu title of the allow-listed apps and whether the
    /// allowlist would accept it. Read-only: nothing is stored, nothing is clicked.
    static func inventory() -> Int32 {
        guard Permissions.accessibilityStatus() == .granted else {
            print("accessibility=denied")
            return 2
        }
        var accepted: Set<String> = []
        var rejected: Set<String> = []
        for bundleID in candidateBundleIDs {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
                    ?? launch(bundleID: bundleID) else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            guard let menuBar = self.element(element, kAXMenuBarAttribute),
                  let topLevel = children(menuBar) else { continue }
            for barItem in topLevel {
                guard let menu = children(barItem)?.first, let items = children(menu) else { continue }
                for item in items {
                    guard let title = stringAttribute(item, kAXTitleAttribute),
                          !title.isEmpty,
                          stringAttribute(item, kAXRoleAttribute) == kAXMenuItemRole as String,
                          stringAttribute(item, kAXMenuItemCmdCharAttribute) != nil else { continue }
                    if AXMenuCodec.isSafeStaticTitle(title) { accepted.insert(title) }
                    else { rejected.insert(title) }
                }
            }
        }
        var lines: [String] = []
        lines.append("accepted=\(accepted.count) rejected=\(rejected.count)")
        lines.append("--- accepted ---")
        for title in accepted.sorted() { lines.append("  + \(title)") }
        lines.append("--- rejected ---")
        for title in rejected.sorted() { lines.append("  - \(title)") }
        let text = lines.joined(separator: "\n")
        // Launched through LaunchServices, so stdout is not attached to a terminal;
        // write the inventory next to the other reports.
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("ShortcutSense", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? text.write(to: base.appendingPathComponent("ax-inventory.txt"),
                        atomically: true, encoding: .utf8)
        print(text)
        return 0
    }

    static func run() -> Int32 {
        guard Permissions.accessibilityStatus() == .granted else {
            print("accessibility=denied")
            return 2
        }

        var results: [TargetResult] = []
        var notes: [String] = []

        for bundleID in candidateBundleIDs {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
                    ?? launch(bundleID: bundleID) else {
                notes.append("\(bundleID): not running and could not be launched")
                continue
            }
            if let result = probe(app: app, bundleID: bundleID) {
                results.append(result)
            } else {
                notes.append("\(bundleID): no readable static menu items")
            }
        }

        let totalReachable = results.reduce(0) { $0 + $1.reachableHits }
        let totalPost = results.reduce(0) { $0 + $1.postClickHits }
        let totalTested = results.reduce(0) { $0 + $1.itemsTested }

        // The gate: a menu item must be identifiable at its own coordinates, and must
        // still be identifiable immediately after a click is delivered.
        let verdict: String
        if totalTested == 0 {
            verdict = "inconclusive_no_items"
        } else if totalReachable == totalTested && totalPost == totalTested {
            verdict = "reliable"
        } else if totalPost >= (totalTested * 6 + 9) / 10 {
            verdict = "mostly_reliable"
        } else if totalPost > 0 {
            verdict = "unreliable"
        } else {
            verdict = "not_identifiable"
        }

        let report = Report(
            startedAt: DateBuckets.iso8601(Date()),
            accessibilityGranted: true,
            targets: results,
            verdict: verdict,
            notes: notes)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: reportURL())
            print(String(decoding: data, as: UTF8.self))
        }
        for note in notes { print("note: \(note)") }
        print("verdict=\(verdict)")
        print("reachable=\(totalReachable)/\(totalTested) post_click=\(totalPost)/\(totalTested)")
        return 0
    }

    private static func launch(bundleID: String) -> NSRunningApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        var launched: NSRunningApplication?
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            launched = app
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        // Give the app a moment to publish its menu bar.
        Thread.sleep(forTimeInterval: 1.2)
        return launched ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private static func probe(app: NSRunningApplication, bundleID: String) -> TargetResult? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = element(appElement, kAXMenuBarAttribute) else { return nil }
        guard let topLevel = children(menuBar) else { return nil }

        var tested = 0
        var reachable = 0
        var postClick = 0
        var labels: [String] = []
        var menuTitleUsed = ""

        for barItem in topLevel {
            guard let title = stringAttribute(barItem, kAXTitleAttribute),
                  AXMenuCodec.isSafeStaticTitle(title) else { continue }

            // Open the menu through the accessibility action, not a click.
            AXUIElementPerformAction(barItem, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.25)

            defer {
                // Dismiss whatever is open so the next iteration starts clean.
                postKey(keyCode: 53, flags: [])   // Escape
                Thread.sleep(forTimeInterval: 0.15)
            }

            guard let menu = children(barItem)?.first,
                  let items = children(menu) else { continue }

            for item in items {
                guard let itemTitle = stringAttribute(item, kAXTitleAttribute),
                      AXMenuCodec.isSafeStaticTitle(itemTitle),
                      let role = stringAttribute(item, kAXRoleAttribute),
                      role == kAXMenuItemRole as String else { continue }
                // Only items that carry their own shortcut are useful to Learn.
                guard stringAttribute(item, kAXMenuItemCmdCharAttribute) != nil else { continue }
                guard let frame = frame(of: item) else { continue }

                tested += 1
                menuTitleUsed = title
                if labels.count < 12 { labels.append(itemTitle) }

                let point = CGPoint(x: frame.midX, y: frame.midY)
                if let hit = MenuObserver.menuItemAt(point: point),
                   let hitTitle = MenuObserver.describe(hit)?.title,
                   hitTitle == itemTitle {
                    reachable += 1
                }

                // Deliver a synthetic click at the item and immediately re-test, which
                // is the moment a real mouse-up would occur.
                postMouseClick(at: point)
                Thread.sleep(forTimeInterval: 0.05)
                if let hit = MenuObserver.menuItemAt(point: point),
                   let hitTitle = MenuObserver.describe(hit)?.title,
                   hitTitle == itemTitle {
                    postClick += 1
                }
                break   // one item per menu keeps the spike short and avoids side effects
            }
            if tested >= 6 { break }
        }

        guard tested > 0 else { return nil }
        // A 0-hit result over 2–3 items is not evidence that the API is broken; it is
        // evidence that the allowlist left almost nothing to test. The sample labels
        // make that difference visible instead of inviting the wrong conclusion.
        return TargetResult(app: bundleID, menuTitle: menuTitleUsed, itemsTested: tested,
                            reachableHits: reachable, postClickHits: postClick,
                            sampleLabels: labels)
    }

    // MARK: - Synthetic input

    private static func postMouseClick(at point: CGPoint) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        up.post(tap: .cghidEventTap)
    }

    private static func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - AX helpers

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ parent: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return nil }
        return array
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func reportURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("ShortcutSense", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("ax-spike-report.json")
    }
}
