import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ShortcutSenseCore

/// `ShortcutSense --diagnose` prints the real permission and capability state and
/// exits. It exists so that a field report, a QA run, or an SSH session can capture
/// what the app actually sees, instead of guessing from System Settings.
///
/// It prints no user data: no bundle IDs of installed apps, no keystrokes, no
/// paths beyond the app's own database directory, no key material.
enum Diagnose {
    static func run() -> Int32 {
        var report: [String: Any] = [:]
        let snapshot = Permissions.snapshot()

        report["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        report["architecture"] = architecture()
        report["bundle_id"] = Bundle.main.bundleIdentifier ?? "unknown"
        report["input_monitoring"] = snapshot.inputMonitoring.rawValue
        report["accessibility"] = snapshot.accessibility.rawValue
        report["secure_input_enabled"] = snapshot.secureInputEnabled
        report["screen_locked"] = snapshot.screenLocked

        // Whether a listen-only tap can actually be created right now. This is the
        // only true test of the Input Monitoring grant: the preflight flag can say
        // "granted" while tap creation still fails after a permission change.
        report["tap_creation"] = tapCreationResult()

        // Carbon: can the process install its event handler and register a key?
        // Registered on the Ctrl+Opt+Shift+F19 space so nothing real is taken.
        report["carbon"] = carbonProbe()

        // Symbolic hotkeys readable? Drives whether conflicts can be `no_known_conflict`.
        report["symbolic_hotkeys_readable"] = MenuObserver.enabledSymbolicHotkeys() != nil

        // AX: can this process read any menu at all?
        report["menu_readable"] = menuProbe()

        // TCC attributes a process to its *responsible* process. Launched from an SSH
        // session that is `sshd-keygen-wrapper`, so these same probes report the SSH
        // session's grants rather than the app's. Saying so here prevents a BLOCKED
        // diagnosis from being read as "the app was denied".
        report["launched_from_ssh_session"] = processIsResponsibleForItself() ? "no" : "likely"
        report["permission_attribution_note"] =
            "input_monitoring/accessibility/tap_creation/menu_readable describe the calling "
            + "process's TCC identity. Run from Terminal in the GUI session (or from the app "
            + "bundle) for the app's own values."

        report["database_path"] = databasePath()
        report["database_tables"] = databaseTableCount()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report.mapValues { AnyEncodable($0) }),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            print("{\"error\":\"could not encode report\"}")
            return 1
        }

        let critical = (report["input_monitoring"] as? String) == "granted"
        return critical ? 0 : 2
    }

    /// True when this executable is its own TCC responsible process. Under `ssh`
    /// the responsible process is `sshd-keygen-wrapper`, so this returns false.
    private static func processIsResponsibleForItself() -> Bool {
        let parent = ProcessInfo.processInfo.environment["SSH_CONNECTION"] != nil
        return !parent
    }

    private static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func tapCreationResult() -> String {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil)
        else { return "failed" }
        CFMachPortInvalidate(tap)
        return "created"
    }

    private static func carbonProbe() -> [String: Any] {
        var handlerRef: EventHandlerRef?
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in OSStatus(eventNotHandledErr) },
            1, &eventType, nil, &handlerRef)
        defer { if let handlerRef { RemoveEventHandler(handlerRef) } }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x4449_4147 /* 'DIAG' */, id: 1)
        // F19 (80) with Ctrl+Opt+Shift: never proposed by the product, never a
        // system default, so the probe cannot steal a real user shortcut.
        let registerStatus = RegisterEventHotKey(
            80, UInt32(controlKey | optionKey | shiftKey),
            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        var unregisterStatus: Int32 = -1
        if let hotKeyRef {
            unregisterStatus = UnregisterEventHotKey(hotKeyRef)
        }
        return [
            "install_handler_status": Int(installStatus),
            "register_status": Int(registerStatus),
            "register_no_err": registerStatus == noErr,
            "unregister_status": Int(unregisterStatus),
        ]
    }

    private static func menuProbe() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return !MenuObserver.readMenuCommands(pid: front.processIdentifier, maxDepth: 1).isEmpty
    }

    private static func databasePath() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShortcutSense/ShortcutSense.sqlite").path
    }

    private static func databaseTableCount() -> Int {
        guard let store = try? Store(path: databasePath()) else { return -1 }
        defer { store.close() }
        return (try? store.rowCounts().count) ?? -1
    }
}

/// Type-erased encoder so the report can mix strings, ints and bools.
private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void
    init(_ value: Any) {
        encodeClosure = { encoder in
            var container = encoder.singleValueContainer()
            switch value {
            case let string as String: try container.encode(string)
            case let bool as Bool: try container.encode(bool)
            case let int as Int: try container.encode(int)
            case let dict as [String: Any]:
                try container.encode(dict.mapValues { AnyEncodable($0) })
            default: try container.encode(String(describing: value))
            }
        }
    }
    func encode(to encoder: Encoder) throws { try encodeClosure(encoder) }
}
