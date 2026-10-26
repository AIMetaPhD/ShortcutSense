import Foundation

/// Converts Accessibility API menu metadata into normalized shortcuts, and decides
/// which menu titles are safe to persist.
///
/// Kept in the platform-independent core so the decoding rules — which are easy to
/// get wrong and directly affect privacy — are covered by tests on any platform.
public enum AXMenuCodec {
    /// `AXMenuItemCmdModifiers` bits.
    ///
    /// Command is **implied**: it is present unless `axNoCommand` is set. The bits do
    /// not include Command at all, which is easy to get wrong — treating bit 0 as
    /// Command turns ⌘⇧N into ⌘N and makes every conflict check disagree with the
    /// real menu.
    public static let axShift = 1 << 0
    public static let axOption = 1 << 1
    public static let axControl = 1 << 2
    public static let axNoCommand = 1 << 3

    /// Converts an AX command character plus its AX modifier mask into a combo id.
    ///
    /// Returns nil for anything that is not a single ASCII letter or digit, which
    /// includes function keys, arrow keys and non-Latin layouts. Those are simply
    /// not learned rather than guessed.
    public static func comboID(char: String, axModifiers: Int) -> String? {
        guard char.count == 1, let character = char.lowercased().first else { return nil }
        guard let keyCode = KeyCodeNames.keyCode(forLetter: character)
                ?? KeyCodeNames.digitKeyCodes[character] else { return nil }
        var modifiers: ComboModifiers = []
        if axModifiers & axNoCommand == 0 { modifiers.insert(.command) }
        if axModifiers & axShift != 0 { modifiers.insert(.shift) }
        if axModifiers & axOption != 0 { modifiers.insert(.option) }
        if axModifiers & axControl != 0 { modifiers.insert(.control) }
        return KeyCombo(keyCode: keyCode, modifiers: modifiers).comboID
    }

    /// Builds a stable identifier for a menu command from its menu path and title.
    public static func commandID(path: [String], title: String) -> String {
        (path + [title]).joined(separator: "\u{1F}").lowercased()
    }

    /// Rejects menu titles that may contain user data.
    ///
    /// Menu titles are usually static system strings, but "Open Recent" entries and
    /// window lists are not. Anything resembling a file name, path, or free-form
    /// recent item is refused so it can never reach the database.
    public static func isSafeStaticTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return false }
        if trimmed.contains("/") || trimmed.contains("~") || trimmed.contains("\\") { return false }
        if trimmed.contains(":") { return false }

        // "report.pdf", "thesis-v3.docx" — an extension-like suffix after a dot.
        if let lastComponent = trimmed.split(separator: ".").last, trimmed.contains("."),
           lastComponent.count <= 5, lastComponent.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return false
        }

        let dynamicPrefixes = ["open recent", "recent", "reopen", "clear menu",
                               "打开最近", "最近使用", "最近打开"]
        let lowered = trimmed.lowercased()
        if dynamicPrefixes.contains(where: { lowered.hasPrefix($0) }) { return false }
        return true
    }
}
