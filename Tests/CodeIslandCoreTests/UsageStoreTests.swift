import XCTest
import SQLite3
@testable import CodeIslandCore

final class UsageStoreTests: XCTestCase {
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory() + "usage-test-\(UUID().uuidString).sqlite"
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        super.tearDown()
    }

    private func makeStore() throws -> UsageStore {
        try UsageStore(path: dbPath, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func event(
        tool: String = "claude-code",
        model: String = "claude-opus-4-8",
        project: String = "",
        ts: Date,
        input: Int64 = 100,
        output: Int64 = 50,
        cacheRead: Int64 = 1000,
        cacheWrite: Int64 = 200,
        dedupKey: String? = nil,
        subagent: Bool = false
    ) -> UsageEvent {
        UsageEvent(
            tool: tool, sessionId: "s1", model: model, project: project, timestamp: ts,
            inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
            dedupKey: dedupKey, isSubagent: subagent
        )
    }

    // MARK: - Recording & totals

    func testRecordAndTotalsRoundTrip() throws {
        let store = try makeStore()
        let ts = date(2026, 7, 11, 9, 15)
        try store.record([event(ts: ts, input: 10, output: 20, cacheRead: 30, cacheWrite: 40)])

        let day = calendar.dateInterval(of: .day, for: ts)!
        let totals = try store.totals(in: day)
        XCTAssertEqual(totals, UsageTotals(inputTokens: 10, outputTokens: 20, cacheReadTokens: 30, cacheWriteTokens: 40))
        XCTAssertEqual(totals.chartTokens, 30)
    }

    func testEventsInSameHourAccumulateIntoOneRow() throws {
        let store = try makeStore()
        try store.record([
            event(ts: date(2026, 7, 11, 9, 5), input: 10, output: 1),
            event(ts: date(2026, 7, 11, 9, 55), input: 20, output: 2),
        ])
        let rows = try store.totalsByHourAndTool(in: calendar.dateInterval(of: .day, for: date(2026, 7, 11, 0))!)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].dateHour, "2026-07-11 09")
        XCTAssertEqual(rows[0].totals.inputTokens, 30)
        XCTAssertEqual(rows[0].totals.outputTokens, 3)
    }

    func testDedupKeySkipsRepeatsWithinAndAcrossBatches() throws {
        let store = try makeStore()
        let ts = date(2026, 7, 11, 9)
        let dup = event(ts: ts, input: 100, output: 0, dedupKey: "msg1:req1")

        let firstBatch = try store.record([dup, dup])
        XCTAssertEqual(firstBatch, 1)
        let secondBatch = try store.record([dup])
        XCTAssertEqual(secondBatch, 0)

        let totals = try store.totals(in: calendar.dateInterval(of: .day, for: ts)!)
        XCTAssertEqual(totals.inputTokens, 100)
    }

    func testDedupSurvivesReopen() throws {
        let ts = date(2026, 7, 11, 9)
        let dup = event(ts: ts, input: 100, output: 0, dedupKey: "msg1:req1")
        try makeStore().record([dup])

        let reopened = try makeStore()
        XCTAssertEqual(try reopened.record([dup]), 0)
        let totals = try reopened.totals(in: calendar.dateInterval(of: .day, for: ts)!)
        XCTAssertEqual(totals.inputTokens, 100)
    }

    func testNilDedupKeyAlwaysCounts() throws {
        let store = try makeStore()
        let ts = date(2026, 7, 11, 9)
        try store.record([event(ts: ts, input: 10, output: 0), event(ts: ts, input: 10, output: 0)])
        let totals = try store.totals(in: calendar.dateInterval(of: .day, for: ts)!)
        XCTAssertEqual(totals.inputTokens, 20)
    }

    // MARK: - Range semantics

    func testDayIntervalExcludesNeighborDays() throws {
        let store = try makeStore()
        try store.record([
            event(ts: date(2026, 7, 10, 23, 59), input: 1, output: 0),
            event(ts: date(2026, 7, 11, 0, 0), input: 10, output: 0),
            event(ts: date(2026, 7, 11, 23, 59), input: 20, output: 0),
            event(ts: date(2026, 7, 12, 0, 0), input: 100, output: 0),
        ])
        let day = UsageStore.dayInterval(containing: date(2026, 7, 11, 12), calendar: calendar)
        let totals = try store.totals(in: day)
        XCTAssertEqual(totals.inputTokens, 30)
    }

    func testTrailingDaysInterval() throws {
        let store = try makeStore()
        try store.record([
            event(ts: date(2026, 7, 4, 12), input: 1, output: 0),
            event(ts: date(2026, 7, 5, 12), input: 10, output: 0),
            event(ts: date(2026, 7, 11, 12), input: 20, output: 0),
        ])
        let week = UsageStore.trailingDaysInterval(days: 7, endingAt: date(2026, 7, 11, 18), calendar: calendar)
        let totals = try store.totals(in: week)
        XCTAssertEqual(totals.inputTokens, 30, "7-day window ending 07-11 spans 07-05 through 07-11")
    }

    // MARK: - Grouped queries

    func testTotalsByDayAndTool() throws {
        let store = try makeStore()
        try store.record([
            event(tool: "claude-code", ts: date(2026, 7, 10, 9), input: 10, output: 1),
            event(tool: "codex", ts: date(2026, 7, 10, 10), input: 20, output: 2),
            event(tool: "claude-code", ts: date(2026, 7, 11, 9), input: 30, output: 3),
        ])
        let rows = try store.totalsByDayAndTool(in: UsageStore.trailingDaysInterval(days: 7, endingAt: date(2026, 7, 11, 12), calendar: calendar))
        XCTAssertEqual(rows.map(\.day), ["2026-07-10", "2026-07-10", "2026-07-11"])
        XCTAssertEqual(rows.map(\.tool), ["claude-code", "codex", "claude-code"])
        XCTAssertEqual(rows[1].totals.inputTokens, 20)
    }

    func testTotalsByToolAndModelOrderedByChartVolume() throws {
        let store = try makeStore()
        let ts = date(2026, 7, 11, 9)
        try store.record([
            event(tool: "claude-code", model: "claude-opus-4-8", ts: ts, input: 10, output: 5),
            event(tool: "claude-code", model: "claude-haiku-4-5", ts: ts, input: 500, output: 100),
            event(tool: "codex", model: "gpt-5", ts: ts, input: 50, output: 20),
        ])
        let rows = try store.totalsByToolAndModel(in: calendar.dateInterval(of: .day, for: ts)!)
        XCTAssertEqual(rows.map(\.model), ["claude-haiku-4-5", "gpt-5", "claude-opus-4-8"])
        XCTAssertEqual(rows[0].tool, "claude-code")
    }

    func testSubagentUsageKeptAsSeparateDimensionButSummedInQueries() throws {
        let store = try makeStore()
        let ts = date(2026, 7, 11, 9)
        try store.record([
            event(ts: ts, input: 10, output: 0, subagent: false),
            event(ts: ts, input: 5, output: 0, subagent: true),
        ])
        let totals = try store.totals(in: calendar.dateInterval(of: .day, for: ts)!)
        XCTAssertEqual(totals.inputTokens, 15, "subagent usage counts toward the reported totals")
        let hourly = try store.totalsByHourAndTool(in: calendar.dateInterval(of: .day, for: ts)!)
        XCTAssertEqual(hourly.count, 1, "grouped queries merge the subagent dimension")
    }

    // MARK: - Project dimension

    func testTotalsByProjectOrderedByChartVolumeWithEmptyBucket() throws {
        let store = try makeStore()
        let ts = date(2026, 7, 11, 9)
        try store.record([
            event(project: "/w/CodeIsland", ts: ts, input: 10, output: 5),
            event(project: "/w/pins", ts: ts, input: 500, output: 100),
            event(project: "", ts: ts, input: 1, output: 1),
            event(project: "/w/CodeIsland", ts: ts, input: 30, output: 3),
        ])
        let rows = try store.totalsByProject(in: calendar.dateInterval(of: .day, for: ts)!)
        XCTAssertEqual(rows.map(\.project), ["/w/pins", "/w/CodeIsland", ""])
        XCTAssertEqual(rows[1].totals.inputTokens, 40)
    }

    func testProjectDimensionMergedInOtherQueries() throws {
        let store = try makeStore()
        let ts = date(2026, 7, 11, 9)
        try store.record([
            event(project: "/w/a", ts: ts, input: 10, output: 0),
            event(project: "/w/b", ts: ts, input: 5, output: 0),
        ])
        let hourly = try store.totalsByHourAndTool(in: calendar.dateInterval(of: .day, for: ts)!)
        XCTAssertEqual(hourly.count, 1, "hour × tool query merges the project dimension")
        XCTAssertEqual(hourly[0].totals.inputTokens, 15)
    }

    func testMigrationFromPreProjectSchemaKeepsRows() throws {
        // Build a v1 database (no project column) by hand, as shipped before p-kstm.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        for sql in [
            """
            CREATE TABLE usage_hourly (
                date_hour   TEXT    NOT NULL,
                tool        TEXT    NOT NULL,
                model       TEXT    NOT NULL,
                subagent    INTEGER NOT NULL DEFAULT 0,
                input       INTEGER NOT NULL DEFAULT 0,
                output      INTEGER NOT NULL DEFAULT 0,
                cache_write INTEGER NOT NULL DEFAULT 0,
                cache_read  INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (date_hour, tool, model, subagent)
            )
            """,
            "INSERT INTO usage_hourly VALUES ('2026-07-11 09', 'claude-code', 'claude-opus-4-8', 0, 10, 5, 2, 100)",
            "INSERT INTO usage_hourly VALUES ('2026-07-11 10', 'codex', 'gpt-5', 0, 20, 8, 0, 0)",
        ] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_close(db)

        let store = try makeStore()
        let day = calendar.dateInterval(of: .day, for: date(2026, 7, 11, 12))!
        let totals = try store.totals(in: day)
        XCTAssertEqual(totals.inputTokens, 30, "v1 rows survive the project migration")

        let projects = try store.totalsByProject(in: day)
        XCTAssertEqual(projects.map(\.project), [""], "migrated rows land in the unattributed bucket")

        // New writes with attribution coexist with migrated rows.
        try store.record([event(project: "/w/CodeIsland", ts: date(2026, 7, 11, 11), input: 7, output: 0)])
        XCTAssertEqual(try store.totalsByProject(in: day).count, 2)
    }

    // MARK: - Persistence & meta

    func testAggregatesSurviveReopen() throws {
        let ts = date(2026, 7, 11, 9)
        try makeStore().record([event(ts: ts, input: 42, output: 0)])
        let totals = try makeStore().totals(in: calendar.dateInterval(of: .day, for: ts)!)
        XCTAssertEqual(totals.inputTokens, 42)
    }

    func testMetaRoundTripAndOverwrite() throws {
        let store = try makeStore()
        XCTAssertNil(try store.metaValue(forKey: "claude.backfill"))
        try store.setMetaValue("2026-07-11", forKey: "claude.backfill")
        XCTAssertEqual(try store.metaValue(forKey: "claude.backfill"), "2026-07-11")
        try store.setMetaValue("2026-07-12", forKey: "claude.backfill")
        XCTAssertEqual(try store.metaValue(forKey: "claude.backfill"), "2026-07-12")
    }

    func testEmptyBatchIsNoOp() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.record([]), 0)
        XCTAssertEqual(try store.totals(in: UsageStore.dayInterval(calendar: calendar)), .zero)
    }

    func testConcurrentRecordsAreSerialized() throws {
        let store = try makeStore()
        let ts = date(2026, 7, 11, 9)
        DispatchQueue.concurrentPerform(iterations: 20) { i in
            _ = try? store.record([event(ts: ts, input: 1, output: 0, dedupKey: "k\(i)")])
        }
        let totals = try store.totals(in: calendar.dateInterval(of: .day, for: ts)!)
        XCTAssertEqual(totals.inputTokens, 20)
    }
}
