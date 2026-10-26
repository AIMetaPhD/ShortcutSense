import AppKit
import SwiftUI
import ShortcutSenseCore

/// App shell: `NSStatusItem` → compact popover → standalone dashboard window.
///
/// The status item uses `NSPopover` with a SwiftUI panel so the compact surface is
/// real UI rather than a menu of commands, as the v2.1 spec requires.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var window: NSWindow?
    private let panelModel = TodayModel()
    private var pendingSection: RootView.Section = .today

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        Task { @MainActor in
            AppController.shared.onStateChange = { [weak self] in self?.refreshStatusItem() }
            AppController.shared.start()
            self.refreshStatusItem()
            self.showFirstRunIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in AppController.shared.stop() }
    }

    // MARK: - Status item and popover

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "command",
                                     accessibilityDescription: L.t("app.name"))
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.setAccessibilityLabel(L.t("app.name"))
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let panel = MenuBarPanel(
            model: panelModel,
            onOpenDashboard: { [weak self] section in
                self?.closePopover()
                self?.showWindow(section: section)
            },
            onQuit: { NSApplication.shared.terminate(nil) })
        popover.contentViewController = NSHostingController(rootView: panel)
        popover.contentSize = NSSize(width: Theme.Layout.popoverWidth, height: 420)
        self.popover = popover
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover else { return }
        if popover.isShown {
            closePopover()
        } else if let button = statusItem?.button {
            panelModel.reload(force: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    /// Reflects collection state on the icon itself so the user can tell at a glance.
    private func refreshStatusItem() {
        let status = TodayModel.status(for: AppController.shared)
        statusItem?.button?.appletTerminalIsPaused(status == .paused)
        statusItem?.button?.setAccessibilityLabel("\(L.t("app.name")) — \(status.label)")
        statusItem?.button?.toolTip = "\(L.t("app.name")) — \(status.label)"
    }

    // MARK: - Dashboard window

    func showWindow(section: RootView.Section = .today) {
        pendingSection = section
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Theme.Layout.dashboardIdeal),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = L.t("app.name")
        window.minSize = Theme.Layout.dashboardMin
        window.contentView = NSHostingView(rootView: RootView())
        window.center()
        window.setFrameAutosaveName("ShortcutSenseDashboard")
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func showFirstRunIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "hasCompletedFirstRun") == false else { return }
        UserDefaults.standard.set(true, forKey: "hasCompletedFirstRun")
        showWindow()
    }
}

private extension NSStatusBarButton {
    /// Tints the icon when collection is paused so the state is visible without
    /// opening anything.
    func appletTerminalIsPaused(_ paused: Bool) {
        contentTintColor = paused ? .systemOrange : nil
    }
}
