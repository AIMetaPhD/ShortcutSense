import Carbon.HIToolbox
import Foundation
import ShortcutSenseCore

/// Thin, explicit wrapper over Carbon `RegisterEventHotKey`.
///
/// Deliberately written from scratch rather than adopting `soffes/HotKey` as a
/// black box: that library does inspect `OSStatus` internally but does not return
/// the failure to its caller, so `HotKey(keyCombo:)` succeeds even when the system
/// refused the registration. Here every failure is a `Result.failure` carrying the
/// exact `OSStatus`, and `noErr` is documented as *acceptance only* — it does not
/// prove the hotkey will fire, which only a physical key press can show.
final class CarbonHotkeyBackend: HotkeyBackend {
    private struct Registration {
        let ref: EventHotKeyRef
        let handler: () -> Void
        let combo: KeyCombo
    }

    private var registrations: [String: Registration] = [:]
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x5348_5453 // 'SHTS'
    private var nextID: UInt32 = 1
    private var idToShortcut: [UInt32: String] = [:]

    init() {
        installEventHandler()
    }

    deinit {
        for (_, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let backend = Unmanaged<CarbonHotkeyBackend>.fromOpaque(userData).takeUnretainedValue()
                return backend.handle(event)
            },
            1, &eventType, userData, &handlerRef)
        if status != noErr {
            NSLog("ShortcutSense: InstallEventHandler failed with OSStatus \(status)")
            handlerRef = nil
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard status == noErr else { return OSStatus(eventNotHandledErr) }
        guard hotKeyID.signature == signature,
              let shortcutID = idToShortcut[hotKeyID.id],
              let registration = registrations[shortcutID] else {
            return OSStatus(eventNotHandledErr)
        }
        registration.handler()
        return noErr
    }

    func register(_ combo: KeyCombo, shortcutID: String, handler: @escaping () -> Void)
        -> Result<Void, HotkeyRegistrationError> {
        if registrations[shortcutID] != nil {
            return .failure(.alreadyRegistered(combo))
        }
        if registrations.values.contains(where: { $0.combo == combo }) {
            return .failure(.alreadyRegistered(combo))
        }
        // Without a working Carbon event handler the system will accept the
        // registration and swallow the key, while no handler ever runs. That is
        // exactly the "noErr is not success" case, so refuse it explicitly.
        guard handlerRef != nil else {
            return .failure(.carbonError(OSStatus(eventNotHandledErr)))
        }

        let id = nextID
        nextID += 1
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            combo.modifiers.rawValue,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef)

        guard status == noErr, let hotKeyRef else {
            // -9878 == eventHotKeyExistsErr
            return .failure(.carbonError(status))
        }

        registrations[shortcutID] = Registration(ref: hotKeyRef, handler: handler, combo: combo)
        idToShortcut[id] = shortcutID
        return .success(())
    }

    func unregister(shortcutID: String) -> Result<Void, HotkeyUnregistrationError> {
        guard let registration = registrations[shortcutID] else {
            return .failure(.notRegistered(shortcutID))
        }
        let status = UnregisterEventHotKey(registration.ref)
        guard status == noErr else {
            // Keep the record: the OS may still hold the grab, so `isRegistered`
            // must stay true and a later retry (or exit cleanup) must still have
            // the reference. Dropping it here would make the hotkey unrecoverable.
            return .failure(.carbonError(status))
        }
        registrations.removeValue(forKey: shortcutID)
        idToShortcut = idToShortcut.filter { $0.value != shortcutID }
        return .success(())
    }

    /// Releases every live registration. Used before deleting all user data.
    func unregisterAll() {
        for id in registrations.keys {
            _ = unregister(shortcutID: id)
        }
    }

    func isRegistered(shortcutID: String) -> Bool {
        registrations[shortcutID] != nil
    }

    /// Diagnostic snapshot for the spike report: how many hotkeys are live and
    /// whether the Carbon event handler installed successfully.
    var diagnostics: [String: Any] {
        [
            "registered_count": registrations.count,
            "event_handler_installed": handlerRef != nil,
        ]
    }
}
