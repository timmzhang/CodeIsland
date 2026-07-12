import XCTest
import CodeIslandCore
@testable import CodeIsland

final class UsageManagerTests: XCTestCase {

    private func totals(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0) -> UsageTotals {
        UsageTotals(inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite)
    }

    // MARK: - trailingDayKeys

    func testTrailingDayKeysOldestFirstEndingToday() {
        var calendar = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = tz
        // 2026-07-12 10:00 local
        let date = DateComponents(calendar: calendar, timeZone: tz, year: 2026, month: 7, day: 12, hour: 10).date!
        let keys = UsageManager.trailingDayKeys(days: 7, endingAt: date, calendar: calendar, timeZone: tz)
        XCTAssertEqual(keys.count, 7)
        XCTAssertEqual(keys.first, "2026-07-06")
        XCTAssertEqual(keys.last, "2026-07-12")
    }

    func testTrailingDayKeysCrossMonthBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = tz
        let date = DateComponents(calendar: calendar, timeZone: tz, year: 2026, month: 7, day: 2, hour: 1).date!
        let keys = UsageManager.trailingDayKeys(days: 7, endingAt: date, calendar: calendar, timeZone: tz)
        XCTAssertEqual(keys, ["2026-06-26", "2026-06-27", "2026-06-28", "2026-06-29",
                              "2026-06-30", "2026-07-01", "2026-07-02"])
    }

    // MARK: - todaySnapshot

    private let week = ["2026-07-06", "2026-07-07", "2026-07-08", "2026-07-09",
                        "2026-07-10", "2026-07-11", "2026-07-12"]

    func testTodaySnapshotEmptyRows() {
        let snapshot = UsageManager.todaySnapshot(from: [], dayKeys: week)
        XCTAssertFalse(snapshot.hasData)
        XCTAssertEqual(snapshot.totalTokens, 0)
        XCTAssertEqual(snapshot.last7DayTokens, Array(repeating: 0, count: 7))
        XCTAssertNil(snapshot.cacheHitRate)
        XCTAssertTrue(snapshot.perTool.isEmpty)
    }

    func testTodaySnapshotAggregatesTodayAcrossTools() {
        let rows = [
            DailyToolUsage(day: "2026-07-12", tool: "claude-code",
                           totals: totals(input: 1_000, output: 4_000, cacheRead: 90_000, cacheWrite: 500)),
            DailyToolUsage(day: "2026-07-12", tool: "codex",
                           totals: totals(input: 500, output: 1_500, cacheRead: 10_000)),
            DailyToolUsage(day: "2026-07-10", tool: "claude-code",
                           totals: totals(input: 2_000, output: 6_000)),
        ]
        let snapshot = UsageManager.todaySnapshot(from: rows, dayKeys: week)

        XCTAssertEqual(snapshot.totalTokens, 7_000)  // input+output today, cache excluded
        XCTAssertEqual(snapshot.last7DayTokens, [0, 0, 0, 0, 8_000, 0, 7_000])
        // reads / (reads + input) = 100_000 / 101_500
        XCTAssertEqual(snapshot.cacheHitRate!, 100_000.0 / 101_500.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.perTool.map(\.tool), ["claude-code", "codex"])
        XCTAssertEqual(snapshot.perTool.map(\.tokens), [5_000, 2_000])
        // Cost needs model-level rows; pushSnapshot attaches it separately
        // from the tool × model query (see UsageManager.pushSnapshot).
        XCTAssertNil(snapshot.equivalentCostUSD)
        XCTAssertTrue(snapshot.hasData)
    }

    func testTodaySnapshotHistoricalOnlyStillHasData() {
        let rows = [
            DailyToolUsage(day: "2026-07-08", tool: "claude-code",
                           totals: totals(input: 100, output: 300)),
        ]
        let snapshot = UsageManager.todaySnapshot(from: rows, dayKeys: week)
        XCTAssertEqual(snapshot.totalTokens, 0)
        XCTAssertNil(snapshot.cacheHitRate)
        XCTAssertTrue(snapshot.perTool.isEmpty)
        XCTAssertEqual(snapshot.last7DayTokens[2], 400)
        XCTAssertTrue(snapshot.hasData)  // mini bar chart still renders
    }

    func testTodaySnapshotIgnoresRowsOutsideWindowAndZeroTools() {
        let rows = [
            DailyToolUsage(day: "2026-07-01", tool: "claude-code",
                           totals: totals(input: 999, output: 999)),
            DailyToolUsage(day: "2026-07-12", tool: "gemini",
                           totals: totals(cacheRead: 5_000)),  // cache-only: excluded from perTool
        ]
        let snapshot = UsageManager.todaySnapshot(from: rows, dayKeys: week)
        XCTAssertEqual(snapshot.totalTokens, 0)
        XCTAssertEqual(snapshot.last7DayTokens, Array(repeating: 0, count: 7))
        XCTAssertTrue(snapshot.perTool.isEmpty)
        XCTAssertEqual(snapshot.cacheHitRate, 1.0)  // 5000 reads, 0 input
    }

    // MARK: - Store round-trip (the exact query pushSnapshot runs)

    func testStoreRoundTripFeedsSnapshot() throws {
        let store = try UsageStore(path: ":memory:")
        let now = Date()
        try store.record([
            UsageEvent(tool: "claude-code", sessionId: "s1", model: "claude-fable-5",
                       timestamp: now, inputTokens: 10, outputTokens: 40,
                       cacheReadTokens: 200, cacheWriteTokens: 5, dedupKey: "a"),
            UsageEvent(tool: "codex", sessionId: "s2", model: "gpt-5-codex",
                       timestamp: now.addingTimeInterval(-3 * 86_400), inputTokens: 7, outputTokens: 13,
                       cacheReadTokens: 0, cacheWriteTokens: 0, dedupKey: "b"),
        ])

        let rows = try store.totalsByDayAndTool(in: UsageStore.trailingDaysInterval(days: 7, endingAt: now))
        let snapshot = UsageManager.todaySnapshot(
            from: rows,
            dayKeys: UsageManager.trailingDayKeys(days: 7, endingAt: now)
        )
        XCTAssertEqual(snapshot.totalTokens, 50)
        XCTAssertEqual(snapshot.last7DayTokens[3], 20)
        XCTAssertEqual(snapshot.last7DayTokens[6], 50)
        XCTAssertEqual(snapshot.perTool.map(\.tool), ["claude-code"])
    }
}
