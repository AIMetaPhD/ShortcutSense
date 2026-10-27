import Foundation
import XCTest
@testable import ShortcutSenseCore

/// Muse round 5, S1. Shape-based filtering cannot separate "New Window" from
/// "Meeting notes" — both are two ordinary words — so the rule is a closed allowlist
/// of known menu commands. An unrecognised title is refused, which is the correct
/// direction for data that gets persisted.
final class TitleSafetyTests: XCTestCase {
    // MARK: Must be refused

    func testPlausibleWindowTitlesAreRefused() {
        for title in ["Claude Code", "Untitled", "Draft", "Meeting notes",
                      "Final version", "Screenshot", "My Project", "Untitled 2"] {
            XCTAssertFalse(AXMenuCodec.isSafeStaticTitle(title),
                           "\(title) could be a window or document title")
        }
    }

    func testFileNamesAreRefused() {
        for title in ["report.pdf", "thesis.docx", "data.csv", "a.swift"] {
            XCTAssertFalse(AXMenuCodec.isSafeStaticTitle(title), title)
        }
    }

    func testPathsAndPunctuationAreRefused() {
        for title in ["/Users/someone/Documents", "~/Desktop", "a:b", "a|b", "a?b"] {
            XCTAssertFalse(AXMenuCodec.isSafeStaticTitle(title), title)
        }
    }

    func testVersionNumbersAndDatesAreRefused() {
        for title in ["v3", "Version 2", "2024 report", "Q3 summary"] {
            XCTAssertFalse(AXMenuCodec.isSafeStaticTitle(title), title)
        }
    }

    func testSentencesAreRefused() {
        XCTAssertFalse(AXMenuCodec.isSafeStaticTitle(
            "This is a fairly long sentence that is not a menu command"))
    }

    func testEmptyAndOverlongAreRefused() {
        XCTAssertFalse(AXMenuCodec.isSafeStaticTitle(""))
        XCTAssertFalse(AXMenuCodec.isSafeStaticTitle("   "))
        XCTAssertFalse(AXMenuCodec.isSafeStaticTitle(String(repeating: "a", count: 41)))
    }

    func testUnknownCommandIsRefusedEvenIfShort() {
        // The point of the allowlist: a short, harmless-looking string that is not a
        // known command is still refused.
        for title in ["Something", "Whatever", "Random label"] {
            XCTAssertFalse(AXMenuCodec.isSafeStaticTitle(title), title)
        }
    }

    // MARK: Must be kept

    func testRealEnglishMenuCommandsAreKept() {
        for title in ["New Window", "New Finder Window", "Empty Trash", "Show All",
                      "Close Tab", "Copy", "Paste", "Undo", "Select All",
                      "Move to Trash", "Go to Folder", "Show View Options",
                      "Enter Full Screen", "Show Bookmarks Bar"] {
            XCTAssertTrue(AXMenuCodec.isSafeStaticTitle(title), "\(title) is a static command")
        }
    }

    func testRealChineseMenuCommandsAreKept() {
        for title in ["新建访达窗口", "拷贝", "显示全部", "全选", "移到废纸篓", "前往文件夹"] {
            XCTAssertTrue(AXMenuCodec.isSafeStaticTitle(title), title)
        }
    }

    // MARK: Properties of the list itself

    func testAllowlistHasNoDuplicatesAndIsNonTrivial() {
        XCTAssertGreaterThan(AXMenuCodec.knownStaticTitles.count, 80)
        XCTAssertEqual(AXMenuCodec.knownStaticTitles.count,
                       Set(AXMenuCodec.knownStaticTitles.map { $0 }).count)
    }

    func testEveryEntryIsShort() {
        for title in AXMenuCodec.knownStaticTitles {
            XCTAssertLessThanOrEqual(title.count, 40, title)
            XCTAssertFalse(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
