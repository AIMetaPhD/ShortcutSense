// swift-tools-version:5.9
import PackageDescription

// ShortcutSense — path B (clean native project, no KeyStats fork).
//
// Target layout:
//   ShortcutSenseCore  — platform-independent logic (compiles + tests on Linux and macOS)
//   ShortcutSenseMac   — macOS app (AppKit/SwiftUI/Carbon/CoreGraphics); macOS only
//   CSQLite            — system SQLite module shim
//
// The macOS target is excluded on non-macOS hosts so that the core can be built and
// tested anywhere (including CI containers and this Linux toolchain).

var products: [Product] = [
    .library(name: "ShortcutSenseCore", targets: ["ShortcutSenseCore"])
]

var targets: [Target] = [
    .systemLibrary(
        name: "CSQLite",
        path: "Sources/CSQLite",
        providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]
    ),
    .target(
        name: "ShortcutSenseCore",
        dependencies: ["CSQLite"],
        path: "Sources/ShortcutSenseCore"
    ),
    .testTarget(
        name: "ShortcutSenseCoreTests",
        dependencies: ["ShortcutSenseCore"],
        path: "Tests/ShortcutSenseCoreTests",
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
products.append(.executable(name: "ShortcutSense", targets: ["ShortcutSenseMac"]))
// Runs the same test sources without XCTest, for Macs that have Command Line Tools
// but not full Xcode (XCTest ships only with Xcode). Built by Scripts/test-without-xcode.sh.
products.append(.executable(name: "ShortcutSenseTests", targets: ["ShortcutSenseTests"]))
targets.append(
    .executableTarget(
        name: "ShortcutSenseMac",
        dependencies: ["ShortcutSenseCore"],
        path: "Sources/ShortcutSenseMac",
        // Info.plist is copied into the bundle by Scripts/build-app.sh, not by SwiftPM.
        exclude: ["Resources"]
    )
)
// Test sources are compiled here too, with the shim standing in for XCTest.
targets.append(
    .executableTarget(
        name: "ShortcutSenseTests",
        dependencies: ["ShortcutSenseCore"],
        path: "Tools/TestRunner",
        // `Tests` is populated by Scripts/test-without-xcode.sh with copies of the
        // real test sources in which `import XCTest` is rewritten to the shim. SwiftPM
        // refuses to let one file belong to two targets, so a generated copy is used.
        sources: ["main.swift", "XCTestShim.swift", "Tests"]
    )
)
#endif

let package = Package(
    name: "ShortcutSense",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
