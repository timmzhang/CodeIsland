import Foundation
import SQLite3

/// SQLite-backed store for token-usage statistics.
///
/// Events are aggregated into hourly rows keyed by
/// `(date_hour, tool, model, project, subagent)` — a few hundred rows per day
/// at most — so the store stays cheap to query forever and survives transcript
/// cleanup or compaction on the tool side (the local DB is the source of truth).
///
/// Idempotency: events carrying a `dedupKey` are counted at most once, ever.
/// Keys are remembered in a `usage_seen` table, so re-running a full backfill
/// after restart never double-counts. Events without a key are always added.
///
/// Hour bucketing uses the *local* timezone ("today"/"this week" are user-local
/// concepts). All calls are serialized on an internal queue; the type is safe
/// to use from any thread.
public final class UsageStore: @unchecked Sendable {
    public enum StoreError: Error, Equatable {
        case cannotOpen(String)
        case sqlite(String)
    }

    private let queue = DispatchQueue(label: "com.codeisland.usage-store")
    private var db: OpaquePointer?
    private let hourFormatter: DateFormatter

    /// Default on-disk location, alongside the app's other persisted state.
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.codeisland/usage.sqlite"
    }

    /// Opens (creating if needed) the database at `path`. Pass `":memory:"`
    /// for an ephemeral store in tests. `timeZone` overrides the hour-bucket
    /// timezone, also for tests.
    public init(path: String = UsageStore.defaultPath, timeZone: TimeZone = .current) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH"
        hourFormatter = formatter

        if path != ":memory:" {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw StoreError.cannotOpen(message)
        }
        db = handle

        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS usage_hourly (
                date_hour   TEXT    NOT NULL,
                tool        TEXT    NOT NULL,
                model       TEXT    NOT NULL,
                project     TEXT    NOT NULL DEFAULT '',
                subagent    INTEGER NOT NULL DEFAULT 0,
                input       INTEGER NOT NULL DEFAULT 0,
                output      INTEGER NOT NULL DEFAULT 0,
                cache_write INTEGER NOT NULL DEFAULT 0,
                cache_read  INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (date_hour, tool, model, project, subagent)
            )
            """)
        try migrateHourlyTableAddingProjectIfNeeded()
        try exec("""
            CREATE TABLE IF NOT EXISTS usage_seen (
                key TEXT PRIMARY KEY
            ) WITHOUT ROWID
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS usage_meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) WITHOUT ROWID
            """)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Writing

    /// Accumulates a batch of events into the hourly aggregate rows inside a
    /// single transaction. Events whose `dedupKey` was seen before (in this
    /// call or any earlier one) are skipped. Returns how many events were
    /// actually counted.
    @discardableResult
    public func record(_ events: [UsageEvent]) throws -> Int {
        guard !events.isEmpty else { return 0 }
        return try queue.sync {
            try exec("BEGIN IMMEDIATE")
            do {
                var counted = 0
                for event in events {
                    guard try claimDedupKey(event.dedupKey) else { continue }
                    try upsert(event)
                    counted += 1
                }
                try exec("COMMIT")
                return counted
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Marks `key` as seen; returns false when it was already present.
    /// A nil key never blocks counting.
    private func claimDedupKey(_ key: String?) throws -> Bool {
        guard let key else { return true }
        let stmt = try prepare("INSERT OR IGNORE INTO usage_seen(key) VALUES(?)")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        try stepDone(stmt)
        return sqlite3_changes(db) > 0
    }

    private func upsert(_ event: UsageEvent) throws {
        let stmt = try prepare("""
            INSERT INTO usage_hourly (date_hour, tool, model, subagent, input, output, cache_write, cache_read)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(date_hour, tool, model, subagent) DO UPDATE SET
                input       = input       + excluded.input,
                output      = output      + excluded.output,
                cache_write = cache_write + excluded.cache_write,
                cache_read  = cache_read  + excluded.cache_read
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hourKey(for: event.timestamp))
        bindText(stmt, 2, event.tool)
        bindText(stmt, 3, event.model)
        sqlite3_bind_int(stmt, 4, event.isSubagent ? 1 : 0)
        sqlite3_bind_int64(stmt, 5, event.inputTokens)
        sqlite3_bind_int64(stmt, 6, event.outputTokens)
        sqlite3_bind_int64(stmt, 7, event.cacheWriteTokens)
        sqlite3_bind_int64(stmt, 8, event.cacheReadTokens)
        try stepDone(stmt)
    }

    // MARK: - Queries

    /// Grand totals over `range`. The interval is start-inclusive and
    /// end-exclusive at hour-bucket granularity, matching `DateInterval`
    /// semantics — `dayInterval(containing:)` (whose end is next midnight)
    /// covers exactly that day's 24 hour buckets.
    public func totals(in range: DateInterval) throws -> UsageTotals {
        try queue.sync {
            let stmt = try prepare("""
                SELECT COALESCE(SUM(input),0), COALESCE(SUM(output),0),
                       COALESCE(SUM(cache_read),0), COALESCE(SUM(cache_write),0)
                FROM usage_hourly WHERE date_hour >= ? AND date_hour <= ?
                """)
            defer { sqlite3_finalize(stmt) }
            bindHourRange(stmt, range)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return .zero }
            return totalsColumns(stmt, startingAt: 0)
        }
    }

    /// Day × tool cells for the stacked daily chart, ordered by day then tool.
    public func totalsByDayAndTool(in range: DateInterval) throws -> [DailyToolUsage] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT substr(date_hour, 1, 10) AS day, tool,
                       SUM(input), SUM(output), SUM(cache_read), SUM(cache_write)
                FROM usage_hourly WHERE date_hour >= ? AND date_hour <= ?
                GROUP BY day, tool ORDER BY day, tool
                """)
            defer { sqlite3_finalize(stmt) }
            bindHourRange(stmt, range)
            var rows: [DailyToolUsage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(DailyToolUsage(
                    day: columnText(stmt, 0),
                    tool: columnText(stmt, 1),
                    totals: totalsColumns(stmt, startingAt: 2)
                ))
            }
            return rows
        }
    }

    /// Tool × model rows for the detail table, largest chart volume first.
    public func totalsByToolAndModel(in range: DateInterval) throws -> [ToolModelUsage] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT tool, model,
                       SUM(input), SUM(output), SUM(cache_read), SUM(cache_write)
                FROM usage_hourly WHERE date_hour >= ? AND date_hour <= ?
                GROUP BY tool, model ORDER BY SUM(input) + SUM(output) DESC
                """)
            defer { sqlite3_finalize(stmt) }
            bindHourRange(stmt, range)
            var rows: [ToolModelUsage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(ToolModelUsage(
                    tool: columnText(stmt, 0),
                    model: columnText(stmt, 1),
                    totals: totalsColumns(stmt, startingAt: 2)
                ))
            }
            return rows
        }
    }

    /// Hour × tool cells (models merged), for the weekly activity heatmap.
    public func totalsByHourAndTool(in range: DateInterval) throws -> [HourlyToolUsage] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT date_hour, tool,
                       SUM(input), SUM(output), SUM(cache_read), SUM(cache_write)
                FROM usage_hourly WHERE date_hour >= ? AND date_hour <= ?
                GROUP BY date_hour, tool ORDER BY date_hour, tool
                """)
            defer { sqlite3_finalize(stmt) }
            bindHourRange(stmt, range)
            var rows: [HourlyToolUsage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(HourlyToolUsage(
                    dateHour: columnText(stmt, 0),
                    tool: columnText(stmt, 1),
                    totals: totalsColumns(stmt, startingAt: 2)
                ))
            }
            return rows
        }
    }

    // MARK: - Provider bookkeeping

    /// Generic key/value slot for providers to persist scan watermarks
    /// (e.g. per-file byte offsets for incremental backfill).
    public func metaValue(forKey key: String) throws -> String? {
        try queue.sync {
            let stmt = try prepare("SELECT value FROM usage_meta WHERE key = ?")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return columnText(stmt, 0)
        }
    }

    public func setMetaValue(_ value: String, forKey key: String) throws {
        try queue.sync {
            let stmt = try prepare("INSERT INTO usage_meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            bindText(stmt, 2, value)
            try stepDone(stmt)
        }
    }

    // MARK: - Hour bucketing

    /// Local-timezone hour bucket, e.g. "2026-07-11 09".
    public func hourKey(for date: Date) -> String {
        hourFormatter.string(from: date)
    }

    /// DateInterval spanning the local calendar day containing `date` —
    /// convenience for "today" queries.
    public static func dayInterval(containing date: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 0)
    }

    /// DateInterval spanning the last `days` local calendar days ending with
    /// (and including) the day containing `date` — convenience for the
    /// 7-day chart and weekly report.
    public static func trailingDaysInterval(days: Int, endingAt date: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let today = dayInterval(containing: date, calendar: calendar)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today.start) ?? today.start
        return DateInterval(start: start, end: today.end)
    }

    // MARK: - SQLite plumbing

    private func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw StoreError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transientDestructor)
    }

    /// Binds `range` as hour-key bounds at parameter slots 1 and 2. The SQL
    /// uses `<=` on the upper bound, so end-exclusivity is achieved by
    /// bucketing the instant just before `range.end`: an end of next-midnight
    /// resolves to hour "23" of the previous day, while an end partway into
    /// an hour still includes that (whole) hour bucket.
    private func bindHourRange(_ stmt: OpaquePointer, _ range: DateInterval) {
        bindText(stmt, 1, hourKey(for: range.start))
        bindText(stmt, 2, hourKey(for: range.end.addingTimeInterval(-0.001)))
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
    }

    /// Reads four consecutive SUM columns in (input, output, cache_read,
    /// cache_write) order.
    private func totalsColumns(_ stmt: OpaquePointer, startingAt index: Int32) -> UsageTotals {
        UsageTotals(
            inputTokens: sqlite3_column_int64(stmt, index),
            outputTokens: sqlite3_column_int64(stmt, index + 1),
            cacheReadTokens: sqlite3_column_int64(stmt, index + 2),
            cacheWriteTokens: sqlite3_column_int64(stmt, index + 3)
        )
    }
}
