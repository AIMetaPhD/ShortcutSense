import AppKit
import Foundation

// `ShortcutSense --diagnose` reports the real permission and capability state and
// exits. Nothing is collected and no window appears.
if CommandLine.arguments.contains("--diagnose") {
    exit(Diagnose.run())
}

// `--ai-probe` performs one real Ollama discovery and generation, printing only
// non-sensitive metadata. Used by QA to prove the AI wiring end to end.
if CommandLine.arguments.contains("--ai-probe") {
    let code = await AIProbe.run()
    exit(code)
}

// Menu-bar-only application: no Dock icon, no main window at launch.
// `main.swift` runs on the main thread but outside the main actor's static
// context, so the delegate is created inside `MainActor.assumeIsolated`.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    // Keep a strong reference: NSApplication.delegate is weak.
    DelegateHolder.shared = delegate
    application.run()
}

private enum DelegateHolder {
    @MainActor static var shared: AppDelegate?
}
