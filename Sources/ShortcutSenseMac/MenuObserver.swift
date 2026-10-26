import AppKit
import ApplicationServices
import Foundation
import ShortcutSenseCore

/// Reads menu structure through the Accessibility API, and (experimentally)
/// hit-tests the element under the mouse when a menu closes.
///
/// Hard limits, by design:
/// - Only applications in `MenuAllowlist` are inspected.
/// - Only `AXRole`, `AXTitle`, `AXMenuItemCmdChar` / `AXMenuItemCmdModifiers` are read.
///   `AXValue`, window titles, document content and any user-generated menu titles
///   (e.g. "Open Recent → thesis-final-v3.docx") are never read.
/// - A menu item is only recorded when the hit test returns a real `AXMenuItem` for
///   an allow-listed app; otherwise nothing is recorded and the UI says so.
enum MenuObserver {
    struct MenuCommand: Equatable {
        let commandID: String
        let title: String
        let shortcut: String?
    }

    /// Reads the menu bar of `pid` and returns static, safe commands.
    static func readMenuCommands(pid: pid_t, maxDepth: Int = 2) -> [MenuCommand] {
        let app = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else { return [] }
        // swiftlint:disable:next force_cast
        let menuBarElement = menuBar as! AXUIElement
        return walk(menuBarElement, depth: 0, maxDepth: maxDepth, path: [])
    }

    private static func walk(_ element: AXUIElement, depth: Int, maxDepth: Int,
                             path: [String]) -> [MenuCommand] {
        guard depth <= maxDepth else { return [] }
        guard let children = children(of: element) else { return [] }
        var commands: [MenuCommand] = []
        for child in children {
            guard let role = stringAttribute(child, kAXRoleAttribute) else { continue }
            let title = stringAttribute(child, kAXTitleAttribute) ?? ""
            guard isSafeStaticTitle(title) else { continue }

            if role == kAXMenuItemRole as String {
                let char = stringAttribute(child, kAXMenuItemCmdCharAttribute)
                let modifiers = intAttribute(child, kAXMenuItemCmdModifiersAttribute)
                commands.append(MenuCommand(
                    commandID: commandID(path: path, title: title),
                    title: title,
                    shortcut: char.flatMap { shortcutString(char: $0, carbonModifiers: modifiers ?? 0) }))
            } else if role == kAXMenuBarItemRole as String || role == kAXMenuRole as String {
                commands.append(contentsOf: walk(child, depth: depth + 1, maxDepth: maxDepth,
                                                 path: path + [title]))
            }
        }
        return commands
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return nil }
        return array
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func intAttribute(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Int
    }

    /// Stable identifier for a menu command (see `AXMenuCodec`).
    static func commandID(path: [String], title: String) -> String {
        AXMenuCodec.commandID(path: path, title: title)
    }

    /// Rejects titles that look like user data (see `AXMenuCodec`).
    static func isSafeStaticTitle(_ title: String) -> Bool {
        AXMenuCodec.isSafeStaticTitle(title)
    }

    /// Converts AX command char + AX modifier mask into a combo id string.
    static func shortcutString(char: String, carbonModifiers axModifiers: Int) -> String? {
        AXMenuCodec.comboID(char: char, axModifiers: axModifiers)
    }

    /// Hit-tests the element under `point` and returns it only when it is a menu item.
    /// Returns nil for everything else, including windows, buttons and text.
    static func menuItemAt(point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        guard let role = stringAttribute(element, kAXRoleAttribute),
              role == kAXMenuItemRole as String else { return nil }
        return element
    }

    static func describe(_ element: AXUIElement) -> (title: String?, shortcut: String?)? {
        guard let title = stringAttribute(element, kAXTitleAttribute) else { return nil }
        let char = stringAttribute(element, kAXMenuItemCmdCharAttribute)
        let modifiers = intAttribute(element, kAXMenuItemCmdModifiersAttribute) ?? 0
        return (title, char.flatMap { shortcutString(char: $0, carbonModifiers: modifiers) })
    }

    /// Reads the enabled symbolic hotkeys from `com.apple.symbolichotkeys`.
    /// Returns nil when the domain cannot be read, which the conflict resolver
    /// treats as "unknown", never as "free".
    static func enabledSymbolicHotkeys() -> Set<KeyCombo>? {
        guard let domain = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let parameters = domain.dictionary(forKey: "AppleSymbolicHotKeys") as? [String: Any]
        else { return nil }

        var combos = Set<KeyCombo>()
        for (_, value) in parameters {
            guard let entry = value as? [String: Any],
                  let enabled = entry["enabled"] as? Bool, enabled,
                  let valueDict = entry["value"] as? [String: Any],
                  let parametersArray = valueDict["parameters"] as? [Int],
                  parametersArray.count >= 2 else { continue }
            let keyCode = parametersArray[1]
            // The third parameter is an NSEvent modifier mask (e.g. 0x100000 for
            // Command), not Carbon bits. Interpreting it as Carbon would match
            // nothing and report every system hotkey as free.
            let appleModifiers = parametersArray.count > 2 ? parametersArray[2] : 0
            guard let code = UInt16(exactly: keyCode), appleModifiers >= 0 else { continue }
            combos.insert(KeyCombo(
                keyCode: code,
                modifiers: ComboModifiers(appleEventFlagsRawValue: UInt(appleModifiers))))
        }
        return combos
    }
}
