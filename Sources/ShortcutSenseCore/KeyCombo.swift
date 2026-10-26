import Foundation

/// Modifier set for a shortcut, using the same bit layout as Carbon's
/// `RegisterEventHotKey` so the value can be passed through unchanged.
public struct ComboModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command   = ComboModifiers(rawValue: 0x0100) // cmdKey
    public static let shift     = ComboModifiers(rawValue: 0x0200) // shiftKey
    public static let option    = ComboModifiers(rawValue: 0x0800) // optionKey
    public static let control   = ComboModifiers(rawValue: 0x1000) // controlKey
    /// Fn. This is the **Carbon** bit (`kEventKeyModifierFnMask`), not the CG
    /// constant: CG's `maskSecondaryFn` is 0x0080_0000 and is converted by
    /// `init(appleEventFlagsRawValue:)`. Carbon does not document Fn as a
    /// `RegisterEventHotKey` modifier, so Fn combinations are recorded but never
    /// proposed as an applicable shortcut.
    public static let function  = ComboModifiers(rawValue: 0x8000)

    /// Modifiers that make a keystroke a command rather than text input.
    public static let commandClass: ComboModifiers = [.command, .control]

    /// Converts Apple's `NSEvent.ModifierFlags` / `CGEventFlags` bit layout into the
    /// Carbon layout used everywhere else in this project.
    ///
    /// The two share no bits: CG uses `0x00100000` for Command where Carbon uses
    /// `0x0100`. Passing CG bits to `ComboModifiers(rawValue:)` silently produces a
    /// value that matches nothing, which would make every shortcut look like text
    /// input — so every platform boundary must go through this initializer.
    public init(appleEventFlagsRawValue raw: UInt) {
        var value: ComboModifiers = []
        if raw & ComboModifiers.appleCommandBit != 0 { value.insert(.command) }
        if raw & ComboModifiers.appleShiftBit != 0 { value.insert(.shift) }
        if raw & ComboModifiers.appleOptionBit != 0 { value.insert(.option) }
        if raw & ComboModifiers.appleControlBit != 0 { value.insert(.control) }
        if raw & ComboModifiers.appleSecondaryFnBit != 0 { value.insert(.function) }
        self = value
    }

    /// Bit constants from `NSEvent.ModifierFlags` (identical for `CGEventFlags`).
    static let appleCommandBit: UInt = 0x0010_0000
    static let appleShiftBit: UInt = 0x0002_0000
    static let appleControlBit: UInt = 0x0004_0000
    static let appleOptionBit: UInt = 0x0008_0000
    static let appleSecondaryFnBit: UInt = 0x0080_0000

    public var displayTokens: [String] {
        var tokens: [String] = []
        if contains(.control) { tokens.append("Control") }
        if contains(.option) { tokens.append("Option") }
        if contains(.shift) { tokens.append("Shift") }
        if contains(.command) { tokens.append("Command") }
        if contains(.function) { tokens.append("Fn") }
        return tokens
    }
}

/// A normalized keyboard shortcut.
///
/// The key code is the macOS virtual key code (`kVK_*`). It is only ever persisted
/// for combinations that classify as *command* shortcuts — see `KeyCombo.classify`.
public struct KeyCombo: Hashable, Codable, Sendable, CustomStringConvertible {
    public let keyCode: UInt16
    public let modifiers: ComboModifiers

    public init(keyCode: UInt16, modifiers: ComboModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Canonical, order-independent identifier used as the database key.
    /// Never contains any information about text the user typed: only a virtual
    /// key code plus modifier bits.
    public var comboID: String {
        "kc\(keyCode)-m\(modifiers.rawValue)"
    }

    public var displayString: String {
        let key = KeyCodeNames.displayName(for: keyCode) ?? "KeyCode(\(keyCode))"
        return (modifiers.displayTokens + [key]).joined(separator: "+")
    }

    public var description: String { displayString }

    public var hasCommandClassModifier: Bool {
        !modifiers.intersection(.commandClass).isEmpty
    }
}

/// Why a key event may or may not be persisted.
public enum KeyEventClassification: Equatable, Sendable {
    /// Modifier keys pressed on their own. Never a shortcut, never counted as text.
    case modifierOnly
    /// Ordinary text entry (letters, digits, space, return, IME, Option-produced
    /// characters). Counted only in the anonymous total; the key code is discarded.
    case textInput
    /// A combination that is safe to aggregate as `(date, bundleID, combo, count)`.
    case commandShortcut(KeyCombo)
}

public extension KeyCombo {
    /// Keys that are themselves modifiers. Pressing these alone is never a shortcut.
    static let modifierKeyCodes: Set<UInt16> = [
        54, 55, // right cmd, left cmd
        56, 57, // left shift, right shift
        58, 59, // left option, right option
        60, 61, // right control, left control
        63,     // fn
    ]

    /// Virtual key codes that produce text on a standard layout. These are never
    /// persisted with their identity; they only contribute to the anonymous counter.
    static let textProducingKeyCodes: Set<UInt16> = {
        var codes: Set<UInt16> = []
        // Letters A–Z (kVK_ANSI_A = 0 … kVK_ANSI_Z = 6 are not contiguous; use the
        // documented table below).
        codes.formUnion(KeyCodeNames.letterKeyCodes.values)
        // Digits 0–9 (top row and keypad).
        codes.formUnion(KeyCodeNames.digitKeyCodes.values)
        // Punctuation and whitespace that produce characters.
        codes.formUnion([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
                         20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
                         36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50,
                         65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92])
        return codes
    }()

    /// Classifies a raw key event.
    ///
    /// Rules (deliberately conservative — see `01_PROJECT_PLAN.md` §3.1):
    /// 1. Modifier-only presses are not shortcuts.
    /// 2. A keystroke is only treated as a command shortcut when it carries
    ///    Command or Control. Option-only combinations are text input on most
    ///    layouts (e.g. Option+e is a dead key), so they are never persisted with
    ///    their identity — they fall back to the anonymous counter.
    /// 3. Function keys with Command/Control are command shortcuts.
    /// 4. Everything else is text input.
    static func classify(keyCode: UInt16, modifiers: ComboModifiers) -> KeyEventClassification {
        if modifierKeyCodes.contains(keyCode) { return .modifierOnly }
        guard !modifiers.intersection(.commandClass).isEmpty else { return .textInput }
        // Command/Control + a text-producing key is a real command (Cmd+C, Ctrl+A…).
        // Command/Control + Option + letter is still a command (the Option is not
        // producing a character because Command or Control is held).
        return .commandShortcut(KeyCombo(keyCode: keyCode, modifiers: modifiers))
    }
}

/// Display names for macOS virtual key codes. Only used for UI and for the
/// human-readable `display_combo` column; never for inference.
public enum KeyCodeNames {
    public static let letterKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    public static let digitKeyCodes: [Character: UInt16] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29,
    ]

    private static let special: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        76: "Enter", 114: "Help", 115: "Home", 116: "PageUp", 117: "ForwardDelete",
        119: "End", 121: "PageDown", 123: "Left", 124: "Right", 125: "Down", 126: "Up",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    public static func displayName(for keyCode: UInt16) -> String? {
        if let letter = letterKeyCodes.first(where: { $0.value == keyCode }) {
            return letter.key.uppercased()
        }
        if let digit = digitKeyCodes.first(where: { $0.value == keyCode }) {
            return String(digit.key)
        }
        return special[keyCode]
    }

    public static func keyCode(forLetter letter: Character) -> UInt16? {
        letterKeyCodes[Character(letter.lowercased())]
    }
}
