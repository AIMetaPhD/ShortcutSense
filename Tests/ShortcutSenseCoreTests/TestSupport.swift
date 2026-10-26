import Foundation
@testable import ShortcutSenseCore

/// A temporary on-disk database. Tests always use real SQLite, never an in-memory
/// stand-in, so WAL behaviour and schema constraints are actually exercised.
final class TempStore {
    let directory: URL
    let store: Store

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shortcutsense-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try Store(path: directory.appendingPathComponent("ShortcutSense.sqlite").path)
    }

    var databasePath: String { directory.appendingPathComponent("ShortcutSense.sqlite").path }
    var walPath: String { databasePath + "-wal" }
    var shmPath: String { databasePath + "-shm" }

    func tearDown() {
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Configurable backend so registration failure paths are exercised deterministically.
final class FakeHotkeyBackend: HotkeyBackend {
    struct Registered {
        let combo: KeyCombo
        let handler: () -> Void
    }

    var registered: [String: Registered] = [:]
    /// Set to a Carbon status to make the next `register` call fail.
    var nextRegisterError: Int32?
    /// Set to a Carbon status to make the next `unregister` call fail.
    var nextUnregisterError: Int32?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    func register(_ combo: KeyCombo, shortcutID: String, handler: @escaping () -> Void)
        -> Result<Void, HotkeyRegistrationError> {
        registerCallCount += 1
        if let error = nextRegisterError {
            nextRegisterError = nil
            return .failure(.carbonError(error))
        }
        if registered.values.contains(where: { $0.combo == combo }) {
            return .failure(.carbonError(-9878)) // eventHotKeyExistsErr
        }
        registered[shortcutID] = Registered(combo: combo, handler: handler)
        return .success(())
    }

    func unregister(shortcutID: String) -> Result<Void, HotkeyUnregistrationError> {
        unregisterCallCount += 1
        if let error = nextUnregisterError {
            nextUnregisterError = nil
            return .failure(.carbonError(error))
        }
        guard registered.removeValue(forKey: shortcutID) != nil else {
            return .failure(.notRegistered(shortcutID))
        }
        return .success(())
    }

    func isRegistered(shortcutID: String) -> Bool { registered[shortcutID] != nil }

    /// Simulates a physical key press.
    func press(shortcutID: String) { registered[shortcutID]?.handler() }
}

final class FakeAppLauncher: AppLauncher {
    var installed: Set<String>
    var running: Set<String>
    private(set) var activateCalls: [String] = []

    init(installed: Set<String> = ["com.apple.finder", "com.google.Chrome"],
         running: Set<String> = []) {
        self.installed = installed
        self.running = running
    }

    func activateOrLaunch(bundleID: String) throws -> Bool {
        guard installed.contains(bundleID) else { throw AppLaunchError.notInstalled(bundleID) }
        activateCalls.append(bundleID)
        let wasRunning = running.contains(bundleID)
        running.insert(bundleID)
        return wasRunning
    }

    func isInstalled(bundleID: String) -> Bool { installed.contains(bundleID) }
}

/// Mutable clock for deterministic time travel.
final class TestClock {
    var current: Date
    init(_ current: Date) { self.current = current }
    func advance(days: Double) { current = current.addingTimeInterval(days * 86_400) }
    func advance(seconds: Double) { current = current.addingTimeInterval(seconds) }
}

enum TestDates {
    /// 2026-03-02 09:00:00 UTC — a Monday, no DST transition nearby.
    static let base: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 2
        components.hour = 9; components.minute = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    static let utc = TimeZone(identifier: "UTC")!

    static func day(_ offset: Int) -> Date { base.addingTimeInterval(Double(offset) * 86_400) }

    static func bucket(_ offset: Int, timeZone: TimeZone = utc) -> String {
        DateBuckets.bucket(for: day(offset), timeZone: timeZone)
    }
}
