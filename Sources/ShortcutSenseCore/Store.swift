import CSQLite
import Foundation

public enum SchemaVersion {
    public static let current = 1
}

/// All persisted state lives here. The schema follows `07_DATA_CONTRACT.md` §B.
///
/// Privacy invariants enforced by this type (and covered by tests):
/// - No raw key sequences, timestamps, text, URLs, window titles, clipboard, or AX values.
/// - Only day-bucket aggregates keyed by bundle identifier.
/// - Text-producing keys never reach `daily_combo_stats`.
public final class Store {
    private let db: Database
    private let queue = DispatchQueue(label: "com.aimetaphd.shortcutsense.store")
    public let path: String

    public init(path: String) throws {
        self.path = path
        self.db = try Database(path: path)
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("PRAGMA synchronous=NORMAL")
        try db.execute("PRAGMA foreign_keys=ON")
        // Measured on the real Mac: with the default 1000-page autocheckpoint the WAL
        // grew to 1.2 MB against a 108 KB database, because this process holds a
        // long-lived connection and the write rate is a handful of rows per minute.
        // A smaller threshold keeps the WAL bounded without adding noticeable work.
        try db.execute("PRAGMA wal_autocheckpoint=256")
        try migrate()
    }

    public func close() { db.close() }

    // MARK: - Schema

    private func migrate() throws {
        let version = try db.scalarInt("PRAGMA user_version")
        if version >= Int64(SchemaVersion.current) { return }
        try db.transaction {
            if version < 1 { try createV1() }
            try db.execute("PRAGMA user_version=\(SchemaVersion.current)")
        }
    }

    private func createV1() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS app_metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS excluded_apps (
          bundle_id TEXT PRIMARY KEY,
          display_name TEXT,
          exclusion_source TEXT NOT NULL CHECK (exclusion_source IN ('system_default','user'))
        );
        CREATE TABLE IF NOT EXISTS daily_combo_stats (
          date_bucket TEXT NOT NULL,
          bundle_id TEXT NOT NULL,
          combo_id TEXT NOT NULL,
          count INTEGER NOT NULL CHECK (count >= 0),
          PRIMARY KEY (date_bucket, bundle_id, combo_id)
        );
        CREATE TABLE IF NOT EXISTS daily_app_activity (
          date_bucket TEXT NOT NULL,
          bundle_id TEXT NOT NULL,
          total_anonymous_keystrokes INTEGER NOT NULL DEFAULT 0,
          observed_keyboard_navigation INTEGER NOT NULL DEFAULT 0,
          unknown_origin_activations INTEGER NOT NULL DEFAULT 0,
          managed_hotkey_activations INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (date_bucket, bundle_id)
        );
        CREATE TABLE IF NOT EXISTS menu_action_stats (
          date_bucket TEXT NOT NULL,
          bundle_id TEXT NOT NULL,
          command_id TEXT NOT NULL,
          safe_static_label TEXT,
          known_shortcut TEXT,
          provenance TEXT NOT NULL CHECK (provenance IN ('verified_ax_click','explicit_manual_mark')),
          count INTEGER NOT NULL CHECK (count >= 0),
          PRIMARY KEY (date_bucket,bundle_id,command_id,provenance)
        );
        CREATE TABLE IF NOT EXISTS recommendations (
          id TEXT PRIMARY KEY,
          bundle_id TEXT NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN ('learn','launch_focus','configure')),
          target_id TEXT NOT NULL,
          proposed_combo TEXT,
          confidence TEXT NOT NULL CHECK (confidence IN ('verified','heuristic','unknown')),
          status TEXT NOT NULL CHECK (status IN ('pending','applied','dismissed','undone')),
          created_at TEXT NOT NULL,
          cooldown_until TEXT,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS registered_shortcuts (
          id TEXT PRIMARY KEY,
          recommendation_id TEXT,
          target_bundle_id TEXT NOT NULL,
          key_code INTEGER NOT NULL,
          carbon_modifiers INTEGER NOT NULL,
          display_combo TEXT NOT NULL,
          is_active INTEGER NOT NULL CHECK(is_active IN (0,1)),
          created_at TEXT NOT NULL,
          last_error_code INTEGER
        );
        CREATE TABLE IF NOT EXISTS applied_shortcut_usage_daily (
          shortcut_id TEXT NOT NULL,
          date_bucket TEXT NOT NULL,
          trigger_count INTEGER NOT NULL DEFAULT 0,
          successful_target_activation_count INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (shortcut_id,date_bucket)
        );
        CREATE TABLE IF NOT EXISTS weekly_reviews (
          review_id TEXT PRIMARY KEY,
          period_start TEXT NOT NULL,
          period_end TEXT NOT NULL,
          generated_at TEXT NOT NULL,
          is_preview INTEGER NOT NULL CHECK(is_preview IN(0,1)),
          UNIQUE (period_start,period_end,is_preview)
        );
        CREATE INDEX IF NOT EXISTS idx_combo_date ON daily_combo_stats(date_bucket);
        CREATE INDEX IF NOT EXISTS idx_activity_date ON daily_app_activity(date_bucket);
        CREATE INDEX IF NOT EXISTS idx_menu_date ON menu_action_stats(date_bucket);
        CREATE INDEX IF NOT EXISTS idx_usage_date ON applied_shortcut_usage_daily(date_bucket);
        CREATE INDEX IF NOT EXISTS idx_rec_status ON recommendations(status);
        """)
    }

    // MARK: - Diagnostics

    /// Test-only readers for connection pragmas, so a setting that silently failed
    /// to apply is caught by a test rather than by a user noticing.
    func debugPragmaInt(_ name: String) throws -> Int64 {
        try queue.sync { try db.scalarInt("PRAGMA \(name)") }
    }

    func debugPragmaString(_ name: String) throws -> String {
        try queue.sync {
            let statement = try db.prepare("PRAGMA \(name)")
            guard try statement.step() else { return "" }
            return statement.string(at: 0) ?? ""
        }
    }

    // MARK: - Metadata

    public func metadata(_ key: String) -> String? {
        queue.sync {
            guard let stmt = try? db.prepare("SELECT value FROM app_metadata WHERE key=?") else { return nil }
            try? stmt.bind([.text(key)])
            guard (try? stmt.step()) == true else { return nil }
            return stmt.string(at: 0)
        }
    }

    public func setMetadata(_ key: String, _ value: String) throws {
        try queue.sync {
            let stmt = try db.prepare("INSERT INTO app_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            try stmt.bind([.text(key), .text(value)])
            _ = try stmt.step()
        }
    }

    /// Records the first time collection actually started. Written once.
    public func markFirstCollectionStarted(at date: Date, timeZone: TimeZone) throws {
        if metadata(MetadataKey.firstCollectionStartedAt) != nil { return }
        try setMetadata(MetadataKey.firstCollectionStartedAt, DateBuckets.iso8601(date))
        try setMetadata(MetadataKey.collectionTimeZone, timeZone.identifier)
    }

    public func firstCollectionStartedAt() -> Date? {
        guard let raw = metadata(MetadataKey.firstCollectionStartedAt) else { return nil }
        return DateBuckets.parseISO8601(raw)
    }

    public var collectionTimeZone: TimeZone {
        guard let id = metadata(MetadataKey.collectionTimeZone) else { return .current }
        return TimeZone(identifier: id) ?? .current
    }

    // MARK: - Exclusions

    public func addExcludedApp(bundleID: String, displayName: String?, source: ExclusionSource) throws {
        try queue.sync {
            // A user exclusion must never downgrade a built-in `system_default` row:
            // otherwise removing the user exclusion would silently un-exclude a
            // sensitive app. Only user-sourced rows are refreshed here.
            let stmt = try db.prepare("""
            INSERT INTO excluded_apps(bundle_id,display_name,exclusion_source) VALUES(?,?,?)
            ON CONFLICT(bundle_id) DO UPDATE SET display_name=excluded.display_name,
              exclusion_source=excluded.exclusion_source
            WHERE excluded_apps.exclusion_source = 'user'
            """)
            try stmt.bind([.text(bundleID), displayName.map(SQLiteValue.text) ?? .null, .text(source.rawValue)])
            _ = try stmt.step()
        }
    }

    public func removeExcludedApp(bundleID: String, source: ExclusionSource) throws {
        try queue.sync {
            let stmt = try db.prepare("DELETE FROM excluded_apps WHERE bundle_id=? AND exclusion_source=?")
            try stmt.bind([.text(bundleID), .text(source.rawValue)])
            _ = try stmt.step()
        }
    }

    public func isExcluded(bundleID: String) -> Bool {
        queue.sync { (try? excludedSet())?.contains(bundleID) ?? false }
    }

    public func excludedBundleIDs() -> [String] {
        queue.sync { ((try? excludedSet()) ?? []).sorted() }
    }

    private func excludedSet() throws -> Set<String> {
        let stmt = try db.prepare("SELECT bundle_id FROM excluded_apps")
        var result = Set<String>()
        while try stmt.step() {
            if let id = stmt.string(at: 0) { result.insert(id) }
        }
        return result
    }

    /// Seeds the built-in sensitive list. Idempotent; user exclusions are untouched.
    public func seedDefaultExclusions(_ entries: [DefaultExclusion]) throws {
        try queue.sync {
            let stmt = try db.prepare("""
            INSERT INTO excluded_apps(bundle_id,display_name,exclusion_source) VALUES(?,?,'system_default')
            ON CONFLICT(bundle_id) DO NOTHING
            """)
            for entry in entries {
                try stmt.bind([.text(entry.bundleID), .text(entry.displayName)])
                _ = try stmt.step()
                stmt.reset()
            }
        }
    }

    // MARK: - Aggregate writes

    /// Increments the anonymous keystroke counter for a text-producing key.
    /// The key identity is discarded by the caller before this call.
    public func incrementAnonymousKeystrokes(date: String, bundleID: String, by amount: Int = 1) throws {
        try queue.sync {
            let stmt = try db.prepare("""
            INSERT INTO daily_app_activity(date_bucket,bundle_id,total_anonymous_keystrokes)
            VALUES(?,?,?)
            ON CONFLICT(date_bucket,bundle_id) DO UPDATE SET
              total_anonymous_keystrokes=total_anonymous_keystrokes+excluded.total_anonymous_keystrokes
            """)
            try stmt.bind([.text(date), .text(bundleID), .int(amount)])
            _ = try stmt.step()
        }
    }

    /// Increments the aggregate count for a verified non-text shortcut.
    public func incrementCombo(date: String, bundleID: String, comboID: String, by amount: Int = 1) throws {
        try queue.sync {
            let stmt = try db.prepare("""
            INSERT INTO daily_combo_stats(date_bucket,bundle_id,combo_id,count) VALUES(?,?,?,?)
            ON CONFLICT(date_bucket,bundle_id,combo_id) DO UPDATE SET count=count+excluded.count
            """)
            try stmt.bind([.text(date), .text(bundleID), .text(comboID), .int(amount)])
            _ = try stmt.step()
        }
    }

    public func incrementActivity(date: String, bundleID: String, field: ActivityField, by amount: Int = 1) throws {
        try queue.sync {
            let stmt = try db.prepare("""
            INSERT INTO daily_app_activity(date_bucket,bundle_id,\(field.column)) VALUES(?,?,?)
            ON CONFLICT(date_bucket,bundle_id) DO UPDATE SET \(field.column)=\(field.column)+excluded.\(field.column)
            """)
            try stmt.bind([.text(date), .text(bundleID), .int(amount)])
            _ = try stmt.step()
        }
    }

    public func incrementMenuAction(
        date: String,
        bundleID: String,
        commandID: String,
        safeLabel: String?,
        knownShortcut: String?,
        provenance: MenuProvenance,
        by amount: Int = 1
    ) throws {
        try queue.sync {
            let stmt = try db.prepare("""
            INSERT INTO menu_action_stats(date_bucket,bundle_id,command_id,safe_static_label,known_shortcut,provenance,count)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(date_bucket,bundle_id,command_id,provenance) DO UPDATE SET count=count+excluded.count
            """)
            try stmt.bind([
                .text(date), .text(bundleID), .text(commandID),
                safeLabel.map(SQLiteValue.text) ?? .null,
                knownShortcut.map(SQLiteValue.text) ?? .null,
                .text(provenance.rawValue), .int(amount),
            ])
            _ = try stmt.step()
        }
    }

    // MARK: - Reads

    public func dailyActivity(from start: String, to end: String) throws -> [DailyAppActivity] {
        try queue.sync {
            let stmt = try db.prepare("""
            SELECT date_bucket,bundle_id,total_anonymous_keystrokes,observed_keyboard_navigation,
                   unknown_origin_activations,managed_hotkey_activations
            FROM daily_app_activity WHERE date_bucket>=? AND date_bucket<=? ORDER BY date_bucket
            """)
            try stmt.bind([.text(start), .text(end)])
            var rows: [DailyAppActivity] = []
            while try stmt.step() {
                rows.append(DailyAppActivity(
                    date: stmt.string(at: 0) ?? "",
                    bundleID: stmt.string(at: 1) ?? "",
                    totalAnonymousKeystrokes: Int(stmt.int(at: 2)),
                    observedKeyboardNavigation: Int(stmt.int(at: 3)),
                    unknownOriginActivations: Int(stmt.int(at: 4)),
                    managedHotkeyActivations: Int(stmt.int(at: 5))
                ))
            }
            return rows
        }
    }

    public func comboStats(from start: String, to end: String) throws -> [DailyComboStat] {
        try queue.sync {
            let stmt = try db.prepare("""
            SELECT date_bucket,bundle_id,combo_id,count FROM daily_combo_stats
            WHERE date_bucket>=? AND date_bucket<=? ORDER BY date_bucket
            """)
            try stmt.bind([.text(start), .text(end)])
            var rows: [DailyComboStat] = []
            while try stmt.step() {
                rows.append(DailyComboStat(
                    date: stmt.string(at: 0) ?? "",
                    bundleID: stmt.string(at: 1) ?? "",
                    comboID: stmt.string(at: 2) ?? "",
                    count: Int(stmt.int(at: 3))
                ))
            }
            return rows
        }
    }

    public func menuActionStats(from start: String, to end: String) throws -> [MenuActionStat] {
        try queue.sync {
            let stmt = try db.prepare("""
            SELECT date_bucket,bundle_id,command_id,safe_static_label,known_shortcut,provenance,count
            FROM menu_action_stats WHERE date_bucket>=? AND date_bucket<=? ORDER BY date_bucket
            """)
            try stmt.bind([.text(start), .text(end)])
            var rows: [MenuActionStat] = []
            while try stmt.step() {
                rows.append(MenuActionStat(
                    date: stmt.string(at: 0) ?? "",
                    bundleID: stmt.string(at: 1) ?? "",
                    commandID: stmt.string(at: 2) ?? "",
                    safeLabel: stmt.string(at: 3),
                    knownShortcut: stmt.string(at: 4),
                    provenance: MenuProvenance(rawValue: stmt.string(at: 5) ?? "") ?? .explicitManualMark,
                    count: Int(stmt.int(at: 6))
                ))
            }
            return rows
        }
    }

    // MARK: - Recommendations

    public func upsertRecommendation(_ rec: Recommendation) throws {
        try queue.sync {
            let stmt = try db.prepare("""
            INSERT INTO recommendations(id,bundle_id,kind,target_id,proposed_combo,confidence,status,created_at,cooldown_until,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              proposed_combo=excluded.proposed_combo, confidence=excluded.confidence,
              status=excluded.status, cooldown_until=excluded.cooldown_until, updated_at=excluded.updated_at
            """)
            try stmt.bind([
                .text(rec.id), .text(rec.bundleID), .text(rec.kind.rawValue), .text(rec.targetID),
                rec.proposedCombo.map(SQLiteValue.text) ?? .null,
                .text(rec.confidence.rawValue), .text(rec.status.rawValue),
                .text(rec.createdAt), rec.cooldownUntil.map(SQLiteValue.text) ?? .null,
                .text(rec.updatedAt),
            ])
            _ = try stmt.step()
        }
    }

    public func recommendations(status: RecommendationStatus? = nil) throws -> [Recommendation] {
        try queue.sync {
            let sql = status == nil
                ? "SELECT id,bundle_id,kind,target_id,proposed_combo,confidence,status,created_at,cooldown_until,updated_at FROM recommendations ORDER BY created_at DESC"
                : "SELECT id,bundle_id,kind,target_id,proposed_combo,confidence,status,created_at,cooldown_until,updated_at FROM recommendations WHERE status=? ORDER BY created_at DESC"
            let stmt = try db.prepare(sql)
            if let status { try stmt.bind([.text(status.rawValue)]) }
            var rows: [Recommendation] = []
            while try stmt.step() {
                rows.append(Recommendation(
                    id: stmt.string(at: 0) ?? "",
                    bundleID: stmt.string(at: 1) ?? "",
                    kind: RecommendationKind(rawValue: stmt.string(at: 2) ?? "") ?? .launchFocus,
                    targetID: stmt.string(at: 3) ?? "",
                    proposedCombo: stmt.string(at: 4),
                    confidence: Confidence(rawValue: stmt.string(at: 5) ?? "") ?? .unknown,
                    status: RecommendationStatus(rawValue: stmt.string(at: 6) ?? "") ?? .pending,
                    createdAt: stmt.string(at: 7) ?? "",
                    cooldownUntil: stmt.string(at: 8),
                    updatedAt: stmt.string(at: 9) ?? ""
                ))
            }
            return rows
        }
    }

    public func recommendation(id: String) throws -> Recommendation? {
        try recommendations().first { $0.id == id }
    }

    public func setRecommendationStatus(id: String, status: RecommendationStatus, cooldownUntil: String?, now: Date) throws {
        try queue.sync {
            let stmt = try db.prepare("UPDATE recommendations SET status=?, cooldown_until=?, updated_at=? WHERE id=?")
            try stmt.bind([
                .text(status.rawValue), cooldownUntil.map(SQLiteValue.text) ?? .null,
                .text(DateBuckets.iso8601(now)), .text(id),
            ])
            _ = try stmt.step()
        }
    }

    // MARK: - Registered shortcuts

    /// Test-only fault injection for the rollback path. Never set in product code.
    internal var failNextRegisteredShortcutInsert = false

    public func insertRegisteredShortcut(_ shortcut: RegisteredShortcut) throws {
        try queue.sync {
            if failNextRegisteredShortcutInsert {
                failNextRegisteredShortcutInsert = false
                throw SQLiteError.execFailed("injected persistence failure")
            }
            let stmt = try db.prepare("""
            INSERT INTO registered_shortcuts(id,recommendation_id,target_bundle_id,key_code,carbon_modifiers,display_combo,is_active,created_at,last_error_code)
            VALUES(?,?,?,?,?,?,?,?,?)
            """)
            try stmt.bind([
                .text(shortcut.id), shortcut.recommendationID.map(SQLiteValue.text) ?? .null,
                .text(shortcut.targetBundleID), .int(Int(shortcut.keyCode)),
                .int(Int(shortcut.carbonModifiers)), .text(shortcut.displayCombo),
                .bool(shortcut.isActive), .text(shortcut.createdAt),
                shortcut.lastErrorCode.map { SQLiteValue.int(Int($0)) } ?? .null,
            ])
            _ = try stmt.step()
        }
    }

    /// Inserts the registration row and flips the recommendation to `applied` in a
    /// single transaction. Doing these separately left a window where a failure on
    /// the second statement kept an `is_active=1` row for a hotkey the user was told
    /// had failed — which `restoreOnLaunch` would then bring to life.
    public func applyRegistration(_ shortcut: RegisteredShortcut,
                                 recommendationID: String?, now: Date) throws {
        try queue.sync {
            try db.transaction {
                let insert = try db.prepare("""
                INSERT INTO registered_shortcuts(id,recommendation_id,target_bundle_id,key_code,carbon_modifiers,display_combo,is_active,created_at,last_error_code)
                VALUES(?,?,?,?,?,?,?,?,?)
                """)
                try insert.bind([
                    .text(shortcut.id), shortcut.recommendationID.map(SQLiteValue.text) ?? .null,
                    .text(shortcut.targetBundleID), .int(Int(shortcut.keyCode)),
                    .int(Int(shortcut.carbonModifiers)), .text(shortcut.displayCombo),
                    .bool(shortcut.isActive), .text(shortcut.createdAt),
                    shortcut.lastErrorCode.map { SQLiteValue.int(Int($0)) } ?? .null,
                ])
                _ = try insert.step()

                if let recommendationID {
                    let update = try db.prepare(
                        "UPDATE recommendations SET status=?, cooldown_until=NULL, updated_at=? WHERE id=?")
                    try update.bind([.text(RecommendationStatus.applied.rawValue),
                                     .text(DateBuckets.iso8601(now)), .text(recommendationID)])
                    _ = try update.step()
                }
                if failNextRegisteredShortcutInsert {
                    failNextRegisteredShortcutInsert = false
                    throw SQLiteError.execFailed("injected persistence failure")
                }
            }
        }
    }

    public func updateRegisteredShortcutActive(id: String, isActive: Bool, errorCode: Int32?) throws {
        try queue.sync {
            let stmt = try db.prepare("UPDATE registered_shortcuts SET is_active=?, last_error_code=? WHERE id=?")
            try stmt.bind([.bool(isActive), errorCode.map { SQLiteValue.int(Int($0)) } ?? .null, .text(id)])
            _ = try stmt.step()
        }
    }

    public func registeredShortcuts(activeOnly: Bool = false) throws -> [RegisteredShortcut] {
        try queue.sync {
            let stmt = try db.prepare("""
            SELECT id,recommendation_id,target_bundle_id,key_code,carbon_modifiers,display_combo,is_active,created_at,last_error_code
            FROM registered_shortcuts \(activeOnly ? "WHERE is_active=1" : "") ORDER BY created_at
            """)
            var rows: [RegisteredShortcut] = []
            while try stmt.step() {
                rows.append(RegisteredShortcut(
                    id: stmt.string(at: 0) ?? "",
                    recommendationID: stmt.string(at: 1),
                    targetBundleID: stmt.string(at: 2) ?? "",
                    keyCode: UInt16(truncatingIfNeeded: stmt.int(at: 3)),
                    carbonModifiers: UInt32(truncatingIfNeeded: stmt.int(at: 4)),
                    displayCombo: stmt.string(at: 5) ?? "",
                    isActive: stmt.int(at: 6) == 1,
                    createdAt: stmt.string(at: 7) ?? "",
                    lastErrorCode: stmt.optionalInt(at: 8).map { Int32(truncatingIfNeeded: $0) }
                ))
            }
            return rows
        }
    }

    public func deleteRegisteredShortcut(id: String) throws {
        try queue.sync {
            let stmt = try db.prepare("DELETE FROM registered_shortcuts WHERE id=?")
            try stmt.bind([.text(id)])
            _ = try stmt.step()
        }
    }

    // MARK: - Applied shortcut usage

    public func recordShortcutTrigger(shortcutID: String, date: String) throws {
        try queue.sync {
            let stmt = try db.prepare("""
            INSERT INTO applied_shortcut_usage_daily(shortcut_id,date_bucket,trigger_count)
            VALUES(?,?,1)
            ON CONFLICT(shortcut_id,date_bucket) DO UPDATE SET trigger_count=trigger_count+1
            """)
            try stmt.bind([.text(shortcutID), .text(date)])
            _ = try stmt.step()
        }
    }

    public func recordShortcutSuccessfulActivation(shortcutID: String, date: String) throws {
        try queue.sync {
            let stmt = try db.prepare("""
            INSERT INTO applied_shortcut_usage_daily(shortcut_id,date_bucket,successful_target_activation_count)
            VALUES(?,?,1)
            ON CONFLICT(shortcut_id,date_bucket) DO UPDATE SET successful_target_activation_count=successful_target_activation_count+1
            """)
            try stmt.bind([.text(shortcutID), .text(date)])
            _ = try stmt.step()
        }
    }

    public func shortcutUsage(from start: String, to end: String) throws -> [ShortcutUsage] {
        try queue.sync {
            let stmt = try db.prepare("""
            SELECT shortcut_id,date_bucket,trigger_count,successful_target_activation_count
            FROM applied_shortcut_usage_daily WHERE date_bucket>=? AND date_bucket<=? ORDER BY date_bucket
            """)
            try stmt.bind([.text(start), .text(end)])
            var rows: [ShortcutUsage] = []
            while try stmt.step() {
                rows.append(ShortcutUsage(
                    shortcutID: stmt.string(at: 0) ?? "",
                    date: stmt.string(at: 1) ?? "",
                    triggerCount: Int(stmt.int(at: 2)),
                    successfulTargetActivations: Int(stmt.int(at: 3))
                ))
            }
            return rows
        }
    }

    // MARK: - Weekly reviews

    public func insertWeeklyReview(_ review: WeeklyReviewRecord) throws -> Bool {
        try queue.sync {
            let stmt = try db.prepare("""
            INSERT INTO weekly_reviews(review_id,period_start,period_end,generated_at,is_preview)
            VALUES(?,?,?,?,?)
            ON CONFLICT(period_start,period_end,is_preview) DO NOTHING
            """)
            try stmt.bind([
                .text(review.reviewID), .text(review.periodStart), .text(review.periodEnd),
                .text(review.generatedAt), .bool(review.isPreview),
            ])
            _ = try stmt.step()
            // ON CONFLICT DO NOTHING leaves changes == 0 when the period already exists,
            // which is what makes weekly generation idempotent.
            return db.changes > 0
        }
    }

    public func weeklyReviews() throws -> [WeeklyReviewRecord] {
        try queue.sync {
            let stmt = try db.prepare("SELECT review_id,period_start,period_end,generated_at,is_preview FROM weekly_reviews ORDER BY period_start DESC")
            var rows: [WeeklyReviewRecord] = []
            while try stmt.step() {
                rows.append(WeeklyReviewRecord(
                    reviewID: stmt.string(at: 0) ?? "",
                    periodStart: stmt.string(at: 1) ?? "",
                    periodEnd: stmt.string(at: 2) ?? "",
                    generatedAt: stmt.string(at: 3) ?? "",
                    isPreview: stmt.int(at: 4) == 1
                ))
            }
            return rows
        }
    }

    public func lastWeeklyReviewPeriod() -> (start: String, end: String, preview: Bool)? {
        guard let first = (try? weeklyReviews())?.first else { return nil }
        return (first.periodStart, first.periodEnd, first.isPreview)
    }

    // MARK: - Deletion

    /// Deletes every aggregate and configuration row, checkpoints and truncates WAL,
    /// then vacuums. The database file itself stays (schema is recreated by migration).
    public func deleteAllData() throws {
        try queue.sync {
            try db.transaction {
                try db.execute("""
                DELETE FROM applied_shortcut_usage_daily;
                DELETE FROM registered_shortcuts;
                DELETE FROM recommendations;
                DELETE FROM menu_action_stats;
                DELETE FROM daily_combo_stats;
                DELETE FROM daily_app_activity;
                DELETE FROM weekly_reviews;
                DELETE FROM excluded_apps;
                DELETE FROM app_metadata;
                """)
            }
            // VACUUM rebuilds the database through the WAL, so the checkpoint must
            // run again afterwards or the function returns with a populated WAL.
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute("PRAGMA secure_delete=ON")
            try db.execute("VACUUM")
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    public func rowCounts() throws -> [String: Int] {
        try queue.sync {
            var counts: [String: Int] = [:]
            for table in ["app_metadata", "excluded_apps", "daily_combo_stats", "daily_app_activity",
                          "menu_action_stats", "recommendations", "registered_shortcuts",
                          "applied_shortcut_usage_daily", "weekly_reviews"] {
                counts[table] = Int(try db.scalarInt("SELECT COUNT(*) FROM \(table)"))
            }
            return counts
        }
    }

    // MARK: - Export

    /// Aggregate-only export. Field list is a fixed whitelist; there is no code path
    /// that can add raw keys, text or titles.
    public func exportAggregates(from start: String, to end: String) throws -> ExportPayload {
        ExportPayload(
            schemaVersion: SchemaVersion.current,
            exportedAt: DateBuckets.iso8601(Date()),
            periodStart: start,
            periodEnd: end,
            activity: try dailyActivity(from: start, to: end),
            combos: try comboStats(from: start, to: end),
            menuActions: try menuActionStats(from: start, to: end),
            shortcutUsage: try shortcutUsage(from: start, to: end),
            recommendations: try recommendations()
        )
    }
}

// MARK: - Supporting types

public enum MetadataKey {
    public static let firstCollectionStartedAt = "first_collection_started_at"
    public static let collectionTimeZone = "collection_timezone"
    public static let lastWeeklyReviewPeriod = "last_weekly_review_period"
    public static let isPaused = "is_paused"
    public static let aiEnabled = "ai_enabled"
    public static let aiEndpoint = "ai_endpoint"
    public static let notificationsEnabled = "notifications_enabled"
    public static let weeklySchedule = "weekly_schedule"
}

public enum ExclusionSource: String, Sendable {
    case systemDefault = "system_default"
    case user
}

public struct DefaultExclusion: Sendable {
    public let bundleID: String
    public let displayName: String
    public init(bundleID: String, displayName: String) {
        self.bundleID = bundleID
        self.displayName = displayName
    }
}

public enum ActivityField: String, Sendable {
    case observedKeyboardNavigation = "observed_keyboard_navigation"
    case unknownOriginActivations = "unknown_origin_activations"
    case managedHotkeyActivations = "managed_hotkey_activations"
    case totalAnonymousKeystrokes = "total_anonymous_keystrokes"

    var column: String { rawValue }
}

public enum MenuProvenance: String, Codable, Sendable {
    case verifiedAXClick = "verified_ax_click"
    case explicitManualMark = "explicit_manual_mark"
}

public struct DailyAppActivity: Codable, Equatable, Sendable {
    public let date: String
    public let bundleID: String
    public let totalAnonymousKeystrokes: Int
    public let observedKeyboardNavigation: Int
    public let unknownOriginActivations: Int
    public let managedHotkeyActivations: Int

    public init(date: String, bundleID: String, totalAnonymousKeystrokes: Int,
                observedKeyboardNavigation: Int, unknownOriginActivations: Int,
                managedHotkeyActivations: Int) {
        self.date = date
        self.bundleID = bundleID
        self.totalAnonymousKeystrokes = totalAnonymousKeystrokes
        self.observedKeyboardNavigation = observedKeyboardNavigation
        self.unknownOriginActivations = unknownOriginActivations
        self.managedHotkeyActivations = managedHotkeyActivations
    }
}

public struct DailyComboStat: Codable, Equatable, Sendable {
    public let date: String
    public let bundleID: String
    public let comboID: String
    public let count: Int
    public init(date: String, bundleID: String, comboID: String, count: Int) {
        self.date = date; self.bundleID = bundleID; self.comboID = comboID; self.count = count
    }
}

public struct MenuActionStat: Codable, Equatable, Sendable {
    public let date: String
    public let bundleID: String
    public let commandID: String
    public let safeLabel: String?
    public let knownShortcut: String?
    public let provenance: MenuProvenance
    public let count: Int

    public init(date: String, bundleID: String, commandID: String, safeLabel: String?,
                knownShortcut: String?, provenance: MenuProvenance, count: Int) {
        self.date = date; self.bundleID = bundleID; self.commandID = commandID
        self.safeLabel = safeLabel; self.knownShortcut = knownShortcut
        self.provenance = provenance; self.count = count
    }
}

public enum RecommendationKind: String, Codable, Sendable {
    case learn
    case launchFocus = "launch_focus"
    case configure
}

public enum Confidence: String, Codable, Sendable {
    case verified
    case heuristic
    case unknown
}

public enum RecommendationStatus: String, Codable, Sendable {
    case pending
    case applied
    case dismissed
    case undone
}

public struct Recommendation: Codable, Equatable, Sendable {
    public let id: String
    public let bundleID: String
    public let kind: RecommendationKind
    public let targetID: String
    public var proposedCombo: String?
    public let confidence: Confidence
    public var status: RecommendationStatus
    public let createdAt: String
    public var cooldownUntil: String?
    public var updatedAt: String

    public init(id: String, bundleID: String, kind: RecommendationKind, targetID: String,
                proposedCombo: String?, confidence: Confidence, status: RecommendationStatus,
                createdAt: String, cooldownUntil: String?, updatedAt: String) {
        self.id = id; self.bundleID = bundleID; self.kind = kind; self.targetID = targetID
        self.proposedCombo = proposedCombo; self.confidence = confidence; self.status = status
        self.createdAt = createdAt; self.cooldownUntil = cooldownUntil; self.updatedAt = updatedAt
    }
}

public struct RegisteredShortcut: Codable, Equatable, Sendable {
    public let id: String
    public let recommendationID: String?
    public let targetBundleID: String
    public let keyCode: UInt16
    public let carbonModifiers: UInt32
    public let displayCombo: String
    public var isActive: Bool
    public let createdAt: String
    public var lastErrorCode: Int32?

    public var combo: KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: ComboModifiers(rawValue: carbonModifiers))
    }

    public init(id: String, recommendationID: String?, targetBundleID: String, keyCode: UInt16,
                carbonModifiers: UInt32, displayCombo: String, isActive: Bool, createdAt: String,
                lastErrorCode: Int32?) {
        self.id = id; self.recommendationID = recommendationID; self.targetBundleID = targetBundleID
        self.keyCode = keyCode; self.carbonModifiers = carbonModifiers
        self.displayCombo = displayCombo; self.isActive = isActive
        self.createdAt = createdAt; self.lastErrorCode = lastErrorCode
    }
}

public struct ShortcutUsage: Codable, Equatable, Sendable {
    public let shortcutID: String
    public let date: String
    public let triggerCount: Int
    public let successfulTargetActivations: Int
    public init(shortcutID: String, date: String, triggerCount: Int, successfulTargetActivations: Int) {
        self.shortcutID = shortcutID; self.date = date
        self.triggerCount = triggerCount
        self.successfulTargetActivations = successfulTargetActivations
    }
}

public struct WeeklyReviewRecord: Codable, Equatable, Sendable {
    public let reviewID: String
    public let periodStart: String
    public let periodEnd: String
    public let generatedAt: String
    public let isPreview: Bool
    public init(reviewID: String, periodStart: String, periodEnd: String, generatedAt: String, isPreview: Bool) {
        self.reviewID = reviewID; self.periodStart = periodStart
        self.periodEnd = periodEnd; self.generatedAt = generatedAt; self.isPreview = isPreview
    }
}

public struct ExportPayload: Codable, Sendable {
    public let schemaVersion: Int
    public let exportedAt: String
    public let periodStart: String
    public let periodEnd: String
    public let activity: [DailyAppActivity]
    public let combos: [DailyComboStat]
    public let menuActions: [MenuActionStat]
    public let shortcutUsage: [ShortcutUsage]
    public let recommendations: [Recommendation]
}
