import Foundation
import XCTest
@testable import ShortcutSenseCore

/// AC-05 / AC-10: AX menu decoding and the title safety filter.
final class AXMenuCodecTests: XCTestCase {
    // MARK: - Modifier decoding

    func testCommandIsImpliedWhenNoCommandBitIsAbsent() {
        // AX reports only the non-Command modifiers; Command is the default.
        let plain = AXMenuCodec.comboID(char: "n", axModifiers: 0)!
        XCTAssertEqual(KeyComboCodec.decode(plain)?.modifiers, .command)

        // ⌘⇧N: AX value 1 (shift only, Command still implied).
        let shifted = AXMenuCodec.comboID(char: "n", axModifiers: AXMenuCodec.axShift)!
        XCTAssertEqual(KeyComboCodec.decode(shifted)?.modifiers, [.command, .shift],
                       "⌘⇧N must not decode as ⌘N")
    }

    func testAllAXModifierBitsMapCorrectly() {
        let all = AXMenuCodec.comboID(
            char: "n", axModifiers: AXMenuCodec.axShift | AXMenuCodec.axOption | AXMenuCodec.axControl)!
        XCTAssertEqual(KeyComboCodec.decode(all)?.modifiers, [.command, .shift, .option, .control])

        let controlOnly = AXMenuCodec.comboID(char: "c", axModifiers: AXMenuCodec.axControl)!
        XCTAssertEqual(KeyComboCodec.decode(controlOnly)?.modifiers, [.command, .control])
    }

    func testNoCommandBitRemovesCommand() {
        let plainControl = AXMenuCodec.comboID(
            char: "f", axModifiers: AXMenuCodec.axControl | AXMenuCodec.axNoCommand)!
        XCTAssertEqual(KeyComboCodec.decode(plainControl)?.modifiers, [.control],
                       "NoCommand means the combination has no Command at all")
    }

    func testZeroAXModifiersMeansCommandAlone() {
        // AX omits Command, so an empty mask is ⌘F, not a bare F.
        let combo = AXMenuCodec.comboID(char: "f", axModifiers: 0)!
        XCTAssertEqual(KeyComboCodec.decode(combo)?.modifiers, .command)
    }

    func testUppercaseAndDigitCharsDecode() {
        XCTAssertNotNil(AXMenuCodec.comboID(char: "N", axModifiers: 1))
        XCTAssertNotNil(AXMenuCodec.comboID(char: "1", axModifiers: 1))
    }

    func testNonAlphanumericCharsAreNotLearned() {
        for char in ["\u{F700}", "→", "é", "", "ab"] {
            XCTAssertNil(AXMenuCodec.comboID(char: char, axModifiers: 1),
                         "\(char) must not be decoded into a shortcut")
        }
    }

    // MARK: - Title safety

    func testStaticMenuTitlesAreSafe() {
        for title in ["New Window", "Show All", "新建窗口", "Close Tab", "Move to Trash"] {
            XCTAssertTrue(AXMenuCodec.isSafeStaticTitle(title), "\(title) should be safe")
        }
    }

    func testFileNamesAreRejected() {
        for title in ["report.pdf", "thesis-final-v3.docx", "data.csv", "notes.md"] {
            XCTAssertFalse(AXMenuCodec.isSafeStaticTitle(title), "\(title) looks like user data")
        }
    }

    func testPathsAreRejected() {
        for title in ["/Users/the-owner/Documents", "~/Desktop", "C:\\Users\\the-owner", "Open: secret"] {
            XCTAssertFalse(AXMenuCodec.isSafeStaticTitle(title), "\(title) contains a path")
        }
    }

    func testRecentItemsAreRejected() {
        // "Open Recent" is a container whose children are user files; it is refused
        // as a command and its children are refused by the allowlist.
        for title in ["Open Recent", "Recent Files", "Reopen", "打开最近的项目", "最近使用",
                      "thesis-final-v3.docx", "Untitled"] {
            XCTAssertFalse(AXMenuCodec.isSafeStaticTitle(title), "\(title) is a dynamic menu")
        }
    }

    func testEmptyAndOverlongTitlesAreRejected() {
        XCTAssertFalse(AXMenuCodec.isSafeStaticTitle(""))
        XCTAssertFalse(AXMenuCodec.isSafeStaticTitle("   "))
        XCTAssertFalse(AXMenuCodec.isSafeStaticTitle(String(repeating: "a", count: 61)))
    }

    func testCommandIDIsStableAndCaseInsensitive() {
        let a = AXMenuCodec.commandID(path: ["File"], title: "New Window")
        let b = AXMenuCodec.commandID(path: ["file"], title: "new window")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, AXMenuCodec.commandID(path: ["Edit"], title: "New Window"))
    }
}

/// The CG/NSEvent and Carbon modifier bit layouts share no bits. Reinterpreting one
/// as the other makes every shortcut look like plain text, which fails silently:
/// keystroke totals keep rising while no combo is ever recorded.
final class AppleModifierConversionTests: XCTestCase {
    private func combo(fromApple raw: UInt) -> ComboModifiers {
        ComboModifiers(appleEventFlagsRawValue: raw)
    }

    func testAppleCommandBecomesCarbonCommand() {
        // NSEvent.ModifierFlags.command == 1 << 20
        let converted = combo(fromApple: 0x0010_0000)
        XCTAssertEqual(converted, .command)
        XCTAssertEqual(converted.rawValue, ComboModifiers.command.rawValue)
    }

    func testEveryAppleModifierMaps() {
        XCTAssertEqual(combo(fromApple: 0x0002_0000), .shift)
        XCTAssertEqual(combo(fromApple: 0x0004_0000), .control)
        XCTAssertEqual(combo(fromApple: 0x0008_0000), .option)
        XCTAssertEqual(combo(fromApple: 0x0080_0000), .function)
    }

    func testCombinedAppleFlagsMap() {
        let converted = combo(fromApple: 0x0010_0000 | 0x0002_0000 | 0x0008_0000)
        XCTAssertEqual(converted, [.command, .shift, .option])
    }

    func testNaiveReinterpretationWouldHaveFailed() {
        // Guarding the regression: passing the raw CG value straight into
        // ComboModifiers(rawValue:) yields something that matches no Carbon bit.
        let naive = ComboModifiers(rawValue: UInt32(0x0010_0000))
        XCTAssertTrue(naive.intersection(.commandClass).isEmpty,
                      "this is why the conversion step exists")
    }

    func testConvertedCommandCopyClassifiesAsAShortcut() {
        let modifiers = combo(fromApple: 0x0010_0000)
        guard case .commandShortcut(let c) = KeyCombo.classify(keyCode: 8, modifiers: modifiers) else {
            return XCTFail("Cmd+C must classify as a command shortcut after conversion")
        }
        XCTAssertEqual(c.comboID, KeyCombo(keyCode: 8, modifiers: .command).comboID)
    }

    func testConvertedCmdShiftIsNavigation() {
        let modifiers = combo(fromApple: 0x0010_0000 | 0x0002_0000)
        let tab = KeyCombo(keyCode: 48, modifiers: modifiers)
        XCTAssertTrue(NavigationShortcuts.isNavigation(tab))
    }
}
