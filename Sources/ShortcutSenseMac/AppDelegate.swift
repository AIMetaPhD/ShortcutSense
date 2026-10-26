import AppKit
import ShortcutSenseCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        Task { @MainActor in
            AppController.shared.onStateChange = { [weak self] in self?.refreshMenu() }
            AppController.shared.start()
            self.refreshMenu()
            self.showFirstRunIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in AppController.shared.stop() }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "command",
                                     accessibilityDescription: "ShortcutSense")
        item.button?.image?.isTemplate = true
        statusItem = item
        refreshMenu()
    }

    private func refreshMenu() {
        Task { @MainActor in
            let controller = AppController.shared
            let menu = NSMenu()

            let status = controller.isPaused ? "Paused" : "Collecting"
            let statusRow = NSMenuItem(title: "Status: \(status)", action: nil, keyEquivalent: "")
            statusRow.isEnabled = false
            menu.addItem(statusRow)

            if controller.lastTapStatus == .permissionDenied {
                let warning = NSMenuItem(title: "Input Monitoring not granted — open Settings",
                                         action: #selector(openInputMonitoring), keyEquivalent: "")
                warning.target = self
                menu.addItem(warning)
            }
            menu.addItem(.separator())

            menu.addItem(item("Open ShortcutSense…", #selector(showWindow), "o"))
            menu.addItem(item(controller.isPaused ? "Resume Collection" : "Pause Collection",
                              #selector(togglePause), "p"))
            menu.addItem(.separator())
            menu.addItem(item("Quit ShortcutSense", #selector(quit), "q"))
            statusItem?.menu = menu
        }
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func togglePause() {
        Task { @MainActor in
            AppController.shared.isPaused.toggle()
            self.refreshMenu()
        }
    }

    @objc private func openInputMonitoring() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "ShortcutSense"
        window.contentView = NSHostingViewFactory.makeRootView()
        window.center()
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
