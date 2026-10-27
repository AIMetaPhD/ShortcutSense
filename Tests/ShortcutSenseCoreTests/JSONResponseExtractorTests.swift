import Foundation
import XCTest
@testable import ShortcutSenseCore

/// Local models wrap JSON in prose or fences. The extractor must find the object
/// without relaxing the schema check that follows it.
final class JSONResponseExtractorTests: XCTestCase {
    private func text(_ data: Data?) -> String? {
        data.flatMap { String(data: $0, encoding: .utf8) }
    }

    func testBareObjectIsReturnedUnchanged() {
        let raw = #"{"reason":"r","explanation":"e","category":"other"}"#
        XCTAssertEqual(text(JSONResponseExtractor.extractObject(from: raw)), raw)
    }

    func testFencedBlockIsUnwrapped() {
        let raw = """
        ```json
        {"reason":"r","explanation":"e","category":"other"}
        ```
        """
        XCTAssertEqual(text(JSONResponseExtractor.extractObject(from: raw)),
                       #"{"reason":"r","explanation":"e","category":"other"}"#)
    }

    func testProseBeforeAndAfterIsStripped() {
        let raw = #"Here is the JSON: {"reason":"r","explanation":"e","category":"other"} Hope that helps."#
        XCTAssertEqual(text(JSONResponseExtractor.extractObject(from: raw)),
                       #"{"reason":"r","explanation":"e","category":"other"}"#)
    }

    func testNestedObjectIsKeptWhole() {
        let raw = #"{"reason":"r","explanation":"e","category":"other","extra":{"a":1}}"#
        XCTAssertEqual(text(JSONResponseExtractor.extractObject(from: raw)), raw)
    }

    func testEmptyOrNonJSONReturnsNil() {
        XCTAssertNil(JSONResponseExtractor.extractObject(from: ""))
        XCTAssertNil(JSONResponseExtractor.extractObject(from: "   "))
        XCTAssertNil(JSONResponseExtractor.extractObject(from: "no braces here"))
        XCTAssertNil(JSONResponseExtractor.extractObject(from: "} backwards {"))
    }

    func testExtractedObjectStillFailsStrictSchemaWhenItHasExtraFields() {
        // The extractor only finds the object; OptionalAI.parse still rejects it.
        let raw = #"""
        ```json
        {"reason":"r","explanation":"e","category":"other","command":"rm -rf /"}
        ```
        """#
        guard let data = JSONResponseExtractor.extractObject(from: raw) else {
            return XCTFail("extractor should find the object")
        }
        XCTAssertThrowsError(try OptionalAI.parse(data)) { error in
            XCTAssertEqual(error as? AIError, .unexpectedFields)
        }
    }

    func testExtractedObjectPassesWhenSchemaIsClean() throws {
        let raw = #"""
        Certainly.
        ```json
        {"reason":"r","explanation":"e","category":"efficiency"}
        ```
        """#
        let data = try XCTUnwrap(JSONResponseExtractor.extractObject(from: raw))
        let parsed = try OptionalAI.parse(data)
        XCTAssertEqual(parsed.category, .efficiency)
    }
}
