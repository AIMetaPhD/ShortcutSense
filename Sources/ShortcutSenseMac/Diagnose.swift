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

/// `ShortcutSense --ai-probe` performs one real discovery and one real generation
/// against the local Ollama, then prints only non-sensitive metadata.
///
/// It exists so a QA session can prove the wiring without reading the prompt or the
/// model's prose: what is printed is model names, HTTP outcomes, latency and whether
/// the deterministic template was used.
enum AIProbe {
    static func run() async -> Int32 {
        // Test-only override so failure paths (closed port, non-loopback) can be
        // exercised without disturbing the user's running Ollama. Loopback is still
        // enforced inside the service, so this cannot be used to reach another host.
        let override = ProcessInfo.processInfo.environment["SHORTCUTSENSE_OLLAMA_URL"]
            .flatMap(URL.init(string:))
        let service = OllamaService(baseURL: override ?? OllamaService.defaultBaseURL)
        let discovery = await service.discover()
        var lines: [String] = []
        lines.append("discovery_status=\(label(discovery.status))")
        lines.append("discovery_latency_ms=\(discovery.latencyMilliseconds)")
        switch discovery.status {
        case .connected(let models), .connectedCloudOnly(let models):
            lines.append("models=\(models.map(\.name).joined(separator: ","))")
            lines.append("local_models=\(models.filter(\.isLocallyExecutable).map(\.name).joined(separator: ","))")
            lines.append("cloud_models=\(models.filter { !$0.isLocallyExecutable }.map(\.name).joined(separator: ","))")
        default:
            lines.append("models=")
            lines.append("local_models=")
            lines.append("cloud_models=")
        }

        let local = discovery.status.models.filter(\.isLocallyExecutable)
        guard let selected = local.first else {
            lines.append("generation=skipped_no_local_model")
            print(lines.joined(separator: "\n"))
            return 3
        }
        let model = selected.name
        lines.append("selected_model=\(model)")

        let request = AIExplanationRequest(
            type: "launch_focus", appName: "Probe", observedActivations7d: 9,
            originLabel: "unknown_origin", activeDays: 3,
            proposedShortcut: "Control+Option+Shift+C",
            conflictStatus: "no_known_conflict", confidence: "heuristic")
        let outcome = await service.explain(request, model: model)
        lines.append("generation_latency_ms=\(outcome.latencyMilliseconds)")
        lines.append("used_fallback=\(outcome.usedFallback)")
        lines.append("fallback_reason=\(outcome.fallbackReason ?? "none")")
        lines.append("category=\(outcome.explanation.category.rawValue)")
        lines.append("explanation_characters=\(outcome.explanation.explanation.count)")
        // When the model answered but the payload failed validation, print only the
        // *shape* of the answer — key names and value types, never the prose — so a
        // schema mismatch can be diagnosed without exposing generated text.
        if outcome.usedFallback {
            lines.append(contentsOf: await rawShape(model: model))
        }
        print(lines.joined(separator: "\n"))
        return outcome.usedFallback ? 4 : 0
    }

    /// Returns the key names and value types of one raw generation. No values.
    private static func rawShape(model: String) async -> [String] {
        var lines: [String] = []
        guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else { return lines }
        // Same two guards as the production path: never contact a non-loopback host
        // and never follow a redirect, even from a diagnostic-only request.
        guard OptionalAI.isLoopback(url) else { return lines }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "prompt": "Reply with JSON only: {\"reason\": string, \"explanation\": string, \"category\": one of efficiency|consistency|ergonomics|other}",
            "stream": false, "format": "json",
            "options": ["temperature": 0.2, "num_predict": 200],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let probeSession = URLSession(configuration: .ephemeral,
                                      delegate: NoRedirectSessionDelegate(),
                                      delegateQueue: nil)
        guard let (data, response) = try? await probeSession.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            lines.append("raw_shape=request_failed")
            return lines
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lines.append("raw_shape=envelope_unparseable")
            return lines
        }
        // Counts only: how much budget went to hidden reasoning versus the answer.
        lines.append("raw_response_chars=\((envelope["response"] as? String)?.count ?? -1)")
        lines.append("raw_thinking_chars=\((envelope["thinking"] as? String)?.count ?? -1)")
        guard let inner = envelope["response"] as? String,
              let innerData = inner.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any] else {
            lines.append("raw_shape=inner_not_object")
            lines.append("raw_envelope_keys=\(((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "unparseable")")
            return lines
        }
        lines.append("raw_inner_keys=\(object.keys.sorted().joined(separator: ","))")
        for key in object.keys.sorted() {
            lines.append("raw_type[\(key)]=\(type(of: object[key]!))")
        }
        if let category = object["category"] as? String {
            lines.append("raw_category_lowercased=\(category.lowercased())")
        }
        return lines
    }

    private static func label(_ status: OllamaService.Status) -> String {
        switch status {
        case .disabled: return "disabled"
        case .connected: return "connected"
        case .connectedCloudOnly: return "connected_cloud_only"
        case .installedNotRunning: return "installed_not_running"
        case .notInstalled: return "not_installed"
        case .failed(let message): return "failed:\(message)"
        }
    }
}
