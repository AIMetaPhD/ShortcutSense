import AppKit
import CoreGraphics
import Foundation
import ShortcutSenseCore

/// Listen-only `CGEventTap`.
///
/// Safety properties:
/// - `.listenOnly`: events are never modified, suppressed, or re-injected.
/// - The callback does O(1) work and returns immediately; nothing here touches
///   SQLite or the network on the event thread.
/// - `tapDisabledByTimeout` / `tapDisabledByUserInput` re-enable the tap and, if
///   that fails, report a visible error instead of silently recording nothing.
/// - Sleep/wake and session changes re-create the tap.
final class EventTapSource {
    /// Delivered on the main queue.
    var onKeyDown: ((RawKeyEvent) -> Void)?
    var onStatusChange: ((TapStatus) -> Void)?
    var onLeftMouseUp: ((CGPoint) -> Void)?

    enum TapStatus: Equatable {
        case running
        case permissionDenied
        case creationFailed
        case disabledByTimeout
        case disabledByUserInput
        case stopped
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []
    private(set) var status: TapStatus = .stopped
    private(set) var lastMouseSample: CGPoint = .zero

    private var eventMask: CGEventMask {
        let keyDown = CGEventType.keyDown.rawValue
        let leftMouseUp = CGEventType.leftMouseUp.rawValue
        return CGEventMask((1 << keyDown) | (1 << leftMouseUp))
    }

    func start() {
        guard tap == nil else { return }
        guard Permissions.inputMonitoringStatus() == .granted else {
            update(.permissionDenied)
            return
        }
        installObservers()
        createTap()
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Without invalidating, the port and its callback (which holds an
            // unretained pointer to this object) outlive `stop()`.
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        update(.stopped)
    }

    private func createTap() {
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let source = Unmanaged<EventTapSource>.fromOpaque(userInfo).takeUnretainedValue()
            source.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: userInfo
        ) else {
            update(.creationFailed)
            return
        }

        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        update(.running)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout:
            update(.disabledByTimeout)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .tapDisabledByUserInput:
            update(.disabledByUserInput)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            // `event.flags` is CGEventFlags. It must be converted, not reinterpreted:
            // the CG and Carbon modifier bits share no bits at all.
            let modifiers = ComboModifiers(appleEventFlagsRawValue: UInt(event.flags.rawValue))
            let raw = RawKeyEvent(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                                  modifiers: modifiers, isKeyDown: true)
            DispatchQueue.main.async { [weak self] in self?.onKeyDown?(raw) }
        case .leftMouseUp:
            let point = event.location
            lastMouseSample = point
            DispatchQueue.main.async { [weak self] in self?.onLeftMouseUp?(point) }
        default:
            break
        }
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                // Taps are frequently invalidated by sleep; rebuild rather than trust it.
                self?.rebuildAfterSystemEvent()
            })
        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.rebuildAfterSystemEvent()
            })
    }

    private func rebuildAfterSystemEvent() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        if tap == nil { createTap() }
    }

    private func update(_ newStatus: TapStatus) {
        guard status != newStatus else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }
}
