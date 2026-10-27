import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ShortcutSenseCore

/// `ShortcutSense --menu-spike [seconds]` measures whether a real mouse click on a
/// macOS menu item can be identified reliably enough to power automatic Learn.
///
/// It answers exactly the questions the G-B gate asks, by counting what actually
/// happens while a human clicks:
///
/// - a *static hit*: mouse-up lands on an AXMenuItem whose title passes the safety
///   filter and which carries its own shortcut — this is what Learn would use;
/// - a *rejected dynamic*: an AXMenuItem whose title looks like user data (a recent
///   file, a window name) — counted so we can prove it is refused, never stored;
/// - a *non-menu click*: page content, buttons, the desktop — must never be counted
///   as a menu hit.
///
/// Nothing but counts, bundle identifiers and the already-filtered static labels is
/// written. No window titles, no file names, no coordinates, no click stream.
enum MenuSpike {
    struct BundleCounters: Codable {
        var staticHits = 0
        var rejectedDynamic = 0
        var nonMenuClicks = 0
        var hitLabels: [String] = []
    }

    struct Report: Codable {
        var startedAt: String
        var durationSeconds: Int
        var accessibilityGranted: Bool
        var inputMonitoringGranted: Bool
        var perBundle: [String: BundleCounters]
        var totalClicks: Int

        var staticHits: Int { perBundle.values.reduce(0) { $0 + $1.staticHits } }
        var rejectedDynamic: Int { perBundle.values.reduce(0) { $0 + $1.rejectedDynamic } }
        var nonMenuClicks: Int { perBundle.values.reduce(0) { $0 + $1.nonMenuClicks } }
    }

    final class Collector {
        var perBundle: [String: BundleCounters] = [:]
        var totalClicks = 0
        private let lock = NSLock()

        func record(bundleID: String, outcome: Outcome, label: String?) {
            lock.lock(); defer { lock.unlock() }
            totalClicks += 1
            var counters = perBundle[bundleID] ?? BundleCounters()
            switch outcome {
            case .staticHit:
                counters.staticHits += 1
                if let label, counters.hitLabels.count < 20, !counters.hitLabels.contains(label) {
                    counters.hitLabels.append(label)
                }
            case .rejectedDynamic: counters.rejectedDynamic += 1
            case .nonMenu: counters.nonMenuClicks += 1
            }
            perBundle[bundleID] = counters
        }
    }

    enum Outcome { case staticHit, rejectedDynamic, nonMenu }

    static func run(seconds: Int) -> Int32 {
        let snapshot = Permissions.snapshot()
        guard snapshot.accessibility == .granted else {
            print("accessibility=denied")
            print("Run this from the app bundle in the GUI session and grant Accessibility first.")
            return 2
        }
        guard snapshot.inputMonitoring == .granted else {
            print("input_monitoring=denied")
            print("Grant Input Monitoring before running the spike.")
            return 2
        }

        let collector = Collector()
        let source = EventTapSource()
        source.onLeftMouseUp = { point in
            let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            let (outcome, label) = classify(point: point, bundleID: bundleID)
            collector.record(bundleID: bundleID, outcome: outcome, label: label)
        }
        source.start()
        guard source.status == .running else {
            print("tap_status=\(source.status)")
            return 3
        }

        print("menu_spike_started seconds=\(seconds)")
        print("Follow the G-B protocol; the report is written when the timer ends.")
        let deadline = Date().addingTimeInterval(Double(seconds))
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        source.stop()

        let report = Report(
            startedAt: DateBuckets.iso8601(deadline.addingTimeInterval(-Double(seconds))),
            durationSeconds: seconds,
            accessibilityGranted: snapshot.accessibility == .granted,
            inputMonitoringGranted: snapshot.inputMonitoring == .granted,
            perBundle: collector.perBundle,
            totalClicks: collector.totalClicks)

        let url = reportURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(report).write(to: url)
            print("report=\(url.path)")
            print("total_clicks=\(report.totalClicks)")
            print("static_hits=\(report.staticHits)")
            print("rejected_dynamic=\(report.rejectedDynamic)")
            print("non_menu_clicks=\(report.nonMenuClicks)")
            for (bundle, counters) in report.perBundle.sorted(by: { $0.key < $1.key }) {
                print("bundle.\(bundle).static_hits=\(counters.staticHits)")
                print("bundle.\(bundle).non_menu=\(counters.nonMenuClicks)")
                print("bundle.\(bundle).rejected_dynamic=\(counters.rejectedDynamic)")
            }
            return 0
        } catch {
            print("report_write_failed=\(error)")
            return 4
        }
    }

    private static func classify(point: CGPoint, bundleID: String) -> (Outcome, String?) {
        // Only allow-listed applications are inspected at all.
        guard MenuAllowlist.isAllowed(bundleID) else { return (.nonMenu, nil) }
        guard let element = MenuObserver.menuItemAt(point: point) else { return (.nonMenu, nil) }
        guard let described = MenuObserver.describe(element), let title = described.title else {
            return (.nonMenu, nil)
        }
        // A menu item whose title looks like user data is refused and counted, never
        // stored — this is the negative case the gate asks about.
        guard AXMenuCodec.isSafeStaticTitle(title) else { return (.rejectedDynamic, nil) }
        guard described.shortcut != nil else { return (.nonMenu, nil) }
        return (.staticHit, title)
    }

    static func reportURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("ShortcutSense", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("menu-spike-report.json")
    }
}
