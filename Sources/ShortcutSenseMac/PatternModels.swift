import SwiftUI
import ShortcutSenseCore

/// View model for the T1-driven suggestions: Learn cards, manual marks and
/// workspace groups. All three read the same store the capture pipeline writes.
@MainActor
final class PatternModel: ObservableObject {
    struct LearnCard: Identifiable, Equatable {
        let id: String
        let bundleID: String
        let appName: String
        let commandID: String
        let label: String
        let shortcut: String?
        let shortcutDisplay: String?
        let observedCount: Int?
        let activeDays: Int
        let provenance: MenuProvenance
    }

    struct WorkspaceCard: Identifiable, Equatable {
        let id: String
        let bundleIDs: [String]
        let names: [String]
        let activeDays: Int
        let occurrences: Int
        var proposedCombo: KeyCombo?
        var conflict: ConflictResult?
    }

    @Published private(set) var learnCards: [LearnCard] = []
    @Published private(set) var workspaceCards: [WorkspaceCard] = []
    @Published private(set) var t1Enabled = false
    @Published private(set) var menuItemsInFrontmostApp: [MenuItem] = []
    @Published var actionError: String?
    @Published var readError: String?

    struct MenuItem: Identifiable, Equatable {
        let id: String
        let label: String
        let shortcut: String?
        let shortcutDisplay: String?
    }

    /// How far back the pattern scan looks.
    private let windowDays = 7

    func reload() {
        let controller = AppController.shared
        let store = controller.store
        t1Enabled = store.t1CollectionEnabled
        let window = DateBuckets.rollingWindow(endingAt: Date(), days: windowDays,
                                               timeZone: store.collectionTimeZone)
        let start = window.buckets.first ?? ""
        let end = window.buckets.last ?? ""
        do {
            let events = try store.t1Events(from: start, to: end)
            let menu = PatternDiscovery.menuCommandPatterns(events: events)
            learnCards = menu.map { pattern in
                LearnCard(
                    id: "\(pattern.bundleID)|\(pattern.commandID)|\(pattern.provenance.rawValue)",
                    bundleID: pattern.bundleID,
                    appName: DisplayName.app(pattern.bundleID),
                    commandID: pattern.commandID,
                    label: pattern.safeLabel ?? pattern.commandID,
                    shortcut: pattern.knownShortcut,
                    shortcutDisplay: pattern.knownShortcut
                        .flatMap(KeyComboCodec.decode)?.displayString,
                    observedCount: pattern.observedCount,
                    activeDays: pattern.activeDays,
                    provenance: pattern.provenance)
            }

            let registered = try store.registeredShortcuts(activeOnly: true)
            let takenCombos = Set(registered.map(\.combo))
            let alreadyManaged = Set(registered.map(\.targetBundleID))
            var allocator = ComboAllocator()
            let resolver = ConflictResolver()
            let inputs = controller.conflictInputs(targetBundleID: nil)
            workspaceCards = PatternDiscovery.workspacePatterns(events: events).compactMap { pattern in
                // A group that already has a hotkey is not suggested again.
                let key = pattern.bundleIDs.joined(separator: ",")
                if alreadyManaged.contains(key) { return nil }
                guard let combo = allocator.nextAvailable(inputs: inputs) else { return nil }
                let conflict = resolver.evaluate(combo, inputs: inputs)
                guard conflict.isEligibleForAutomaticApply else { return nil }
                allocator.claim(combo)
                return WorkspaceCard(
                    id: key, bundleIDs: pattern.bundleIDs,
                    names: pattern.bundleIDs.map(DisplayName.app),
                    activeDays: pattern.activeDays, occurrences: pattern.occurrences,
                    proposedCombo: combo, conflict: conflict)
            }
            _ = takenCombos
            readError = nil
        } catch {
            learnCards = []
            workspaceCards = []
            readError = "\(error)"
        }
        loadFrontmostMenu()
    }

    /// Reads the frontmost application's menu so the user can mark an item by name.
    /// This is a read of static titles only; nothing is recorded until a mark is made.
    func loadFrontmostMenu() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              MenuAllowlist.isAllowed(bundleID) else {
            menuItemsInFrontmostApp = []
            return
        }
        let commands = MenuObserver.readMenuCommands(pid: app.processIdentifier)
        menuItemsInFrontmostApp = commands
            .filter { AXMenuCodec.isSafeStaticTitle($0.title) }
            .map { command in
                MenuItem(id: command.commandID,
                         label: command.title,
                         shortcut: command.shortcut,
                         shortcutDisplay: command.shortcut.flatMap(KeyComboCodec.decode)?.displayString)
            }
            .sorted { $0.label < $1.label }
    }

    var frontmostAppName: String? {
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }
        return DisplayName.app(bundle)
    }

    func mark(_ item: MenuItem) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return }
        AppController.shared.recordManualMark(
            bundleID: bundleID, commandID: item.id,
            safeLabel: item.label, knownShortcut: item.shortcut)
        reload()
    }

    func applyWorkspace(_ card: WorkspaceCard) {
        actionError = nil
        guard let combo = card.proposedCombo, let conflict = card.conflict else { return }
        do {
            _ = try AppController.shared.actionManager.applyWorkspace(
                bundleIDs: card.bundleIDs,
                displayName: card.names.joined(separator: " + "),
                combo: combo, conflict: conflict, recommendation: nil)
            reload()
        } catch {
            actionError = "\(error)"
        }
    }

    func setT1Enabled(_ enabled: Bool) {
        AppController.shared.t1CollectionEnabled = enabled
        t1Enabled = enabled
        reload()
    }
}
