// A minimal XCTest-compatible shim for machines that have Command Line Tools but
// not full Xcode (XCTest is only shipped with Xcode).
//
// It implements exactly the subset the test suite uses, so the *same* test files run
// unchanged in both places:
//   - CI / any machine with Xcode:  swift test        (real XCTest)
//   - Command-Line-Tools-only Mac:  swift run ShortcutSenseTests  (this shim)
//
// The assertions are the same code in both cases; only the reporting differs.

import Foundation

public struct XCTSkip: Error {
    public let message: String
    public init(_ message: String = "") { self.message = message }
}

/// `NSObject` + `@objcMembers` so test methods in subclasses are exposed to the
/// Objective-C runtime and can be discovered with `class_copyMethodList`.
@objcMembers
open class XCTestCase: NSObject {
    public override init() { super.init() }
    open func setUpWithError() throws {}
    open func tearDownWithError() throws {}

    public func setUp() {}
    public func tearDown() {}
}

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    TestReporter.shared.recordFailure("XCTFail: \(message)", file: "\(file)", line: line)
}

public func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool,
                          _ message: @autoclosure () -> String = "",
                          file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !expression() {
            TestReporter.shared.recordFailure("XCTAssertTrue failed - \(message())",
                                              file: "\(file)", line: line)
        }
    } catch {
        TestReporter.shared.recordFailure("XCTAssertTrue threw \(error)", file: "\(file)", line: line)
    }
}

public func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool,
                           _ message: @autoclosure () -> String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() {
            TestReporter.shared.recordFailure("XCTAssertFalse failed - \(message())",
                                              file: "\(file)", line: line)
        }
    } catch {
        TestReporter.shared.recordFailure("XCTAssertFalse threw \(error)", file: "\(file)", line: line)
    }
}

public func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T,
                                         _ rhs: @autoclosure () throws -> T,
                                         _ message: @autoclosure () -> String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {
    do {
        let left = try lhs()
        let right = try rhs()
        if left != right {
            TestReporter.shared.recordFailure(
                "XCTAssertEqual failed: (\"\(left)\") is not equal to (\"\(right)\") - \(message())",
                file: "\(file)", line: line)
        }
    } catch {
        TestReporter.shared.recordFailure("XCTAssertEqual threw \(error)", file: "\(file)", line: line)
    }
}

/// Floating-point comparison with a tolerance, as XCTest provides.
public func XCTAssertEqual<T: FloatingPoint>(_ lhs: @autoclosure () throws -> T,
                                             _ rhs: @autoclosure () throws -> T,
                                             accuracy: T,
                                             _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
    do {
        let left = try lhs()
        let right = try rhs()
        if abs(left - right) > accuracy {
            TestReporter.shared.recordFailure(
                "XCTAssertEqual failed: \"\(left)\" is not equal to \"\(right)\" within \(accuracy) - \(message())",
                file: "\(file)", line: line)
        }
    } catch {
        TestReporter.shared.recordFailure("XCTAssertEqual threw \(error)", file: "\(file)", line: line)
    }
}

public func XCTAssertNotEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T,
                                            _ rhs: @autoclosure () throws -> T,
                                            _ message: @autoclosure () -> String = "",
                                            file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try lhs() == rhs() {
            TestReporter.shared.recordFailure("XCTAssertNotEqual failed - \(message())",
                                              file: "\(file)", line: line)
        }
    } catch {
        TestReporter.shared.recordFailure("XCTAssertNotEqual threw \(error)", file: "\(file)", line: line)
    }
}

public func XCTAssertNil(_ expression: @autoclosure () throws -> Any?,
                         _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() != nil {
            TestReporter.shared.recordFailure("XCTAssertNil failed - \(message())",
                                              file: "\(file)", line: line)
        }
    } catch {
        TestReporter.shared.recordFailure("XCTAssertNil threw \(error)", file: "\(file)", line: line)
    }
}

public func XCTAssertNotNil(_ expression: @autoclosure () throws -> Any?,
                            _ message: @autoclosure () -> String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() == nil {
            TestReporter.shared.recordFailure("XCTAssertNotNil failed - \(message())",
                                              file: "\(file)", line: line)
        }
    } catch {
        TestReporter.shared.recordFailure("XCTAssertNotNil threw \(error)", file: "\(file)", line: line)
    }
}

public func XCTAssertLessThan<T: Comparable>(_ lhs: @autoclosure () throws -> T,
                                             _ rhs: @autoclosure () throws -> T,
                                             _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !(lhs() < rhs()) {
            TestReporter.shared.recordFailure("XCTAssertLessThan failed - \(message())",
                                              file: "\(file)", line: line)
        }
    } catch {
        TestReporter.shared.recordFailure("XCTAssertLessThan threw \(error)", file: "\(file)", line: line)
    }
}

public func XCTAssertLessThanOrEqual<T: Comparable>(_ lhs: @autoclosure () throws -> T,
                                                    _ rhs: @autoclosure () throws -> T,
                                                    _ message: @autoclosure () -> String = "",
                                                    file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !(lhs() <= rhs()) {
            TestReporter.shared.recordFailure("XCTAssertLessThanOrEqual failed - \(message())",
                                              file: "\(file)", line: line)
        }
    } catch {
        TestReporter.shared.recordFailure("XCTAssertLessThanOrEqual threw \(error)",
                                          file: "\(file)", line: line)
    }
}

public func XCTAssertGreaterThan<T: Comparable>(_ lhs: @autoclosure () throws -> T,
                                                _ rhs: @autoclosure () throws -> T,
                                                _ message: @autoclosure () -> String = "",
                                                file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !(lhs() > rhs()) {
            TestReporter.shared.recordFailure("XCTAssertGreaterThan failed - \(message())",
                                              file: "\(file)", line: line)
        }
    } catch {
        TestReporter.shared.recordFailure("XCTAssertGreaterThan threw \(error)",
                                          file: "\(file)", line: line)
    }
}

public func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T,
                                    _ message: @autoclosure () -> String = "",
                                    file: StaticString = #filePath, line: UInt = #line,
                                    _ errorHandler: (Error) -> Void = { _ in }) {
    do {
        _ = try expression()
        TestReporter.shared.recordFailure(
            "XCTAssertThrowsError failed: expression did not throw - \(message())",
            file: "\(file)", line: line)
    } catch {
        errorHandler(error)
    }
}

public func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?,
                         _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try expression() else {
        TestReporter.shared.recordFailure("XCTUnwrap failed - \(message())", file: "\(file)", line: line)
        throw TestReporter.UnwrapFailure()
    }
    return value
}

public final class TestReporter {
    public static let shared = TestReporter()
    struct UnwrapFailure: Error {}

    private var failures: [String] = []
    private var currentTest: String = ""

    public private(set) var totalTests = 0
    public private(set) var failedTests = 0

    func begin(_ name: String) {
        currentTest = name
        failures.removeAll()
    }

    func recordFailure(_ message: String, file: String, line: UInt) {
        let short = file.split(separator: "/").suffix(2).joined(separator: "/")
        failures.append("  \(short):\(line): \(message)")
    }

    func end() -> Bool {
        totalTests += 1
        if failures.isEmpty {
            print("  ✓ \(currentTest)")
            return true
        }
        failedTests += 1
        print("  ✗ \(currentTest)")
        failures.forEach { print($0) }
        return false
    }
}
