import XCTest
import CodeIslandCore
@testable import CodeIsland

final class UsageStoreStatsProviderTests: XCTestCase {

    private let tz = TimeZone(identifier: "Asia/Shanghai")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    // 2026-07-12 10:00 local (a Sunday; ISO week runs 07-06 Mon … 07-12 Sun,
    // gregorian default week runs 07-12 Sun … 07-18 Sat — computed via the
    // same calendar either way, so the assertions below derive from it).
    private var now: Date {
        DateComponents(calendar: calendar, timeZone: tz, year: 2026, month: 7, day: 12, hour: 10).date!
    }

    private func event(
        tool: String = "claude-code", model: String = "claude-fable-5",
        daysAgo: Int = 0, hoursAgo: Int = 0,
        input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0,
        dedupKey: String
    ) -> UsageEvent {
        UsageEvent(
            tool: tool, sessionId: "s", model: model,
            timestamp: now.addingTimeInterval(TimeInterval(-daysAgo * 86_400 - hoursAgo * 3_600)),
            inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
            dedupKey: dedupKey
        )
    }

    private func makeStore() throws -> UsageStore {
        try UsageStore(path: ":memory:", timeZone: tz)
    }

    func testEmptyStoreYieldsEmptySnapshot() throws {
        let snapshot = try UsageStoreStatsProvider.snapshot(
            store: try makeStore(), now: now, activeSessions: 3, calendar: calendar, timeZone: tz
        )
        XCTAssertEqual(snapshot.summary.todayTokens, 0)
        XCTAssertNil(snapshot.summary.todayDeltaVsYesterday)
        XCTAssertNil(snapshot.summary.cacheHitRate)
        XCTAssertEqual(snapshot.summary.activeSessions, 3)
        XCTAssertEqual(snapshot.summary.activeToolCount, 0)
        XCTAssertEqual(snapshot.daily.count, 7)
        XCTAssertTrue(snapshot.daily.allSatisfy { $0.total == 0 })
        XCTAssertEqual(snapshot.weekly.count, 8)
        XCTAssertTrue(snapshot.detailRows.isEmpty)
    }

    func testSummaryAndDailyBuckets() throws {
        let store = try makeStore()
        try store.record([
            event(input: 100, output: 400, cacheRead: 9_500, cacheWrite: 50, dedupKey: "today-claude"),
            event(tool: "codex", model: "gpt-5-codex", input: 40, output: 60, dedupKey: "today-codex"),
            // Same time yesterday window (hoursAgo 26 → yesterday 08:00)
            event(daysAgo: 0, hoursAgo: 26, input: 50, output: 200, dedupKey: "yesterday"),
            // Six days ago — oldest daily bucket
            event(daysAgo: 6, input: 10, output: 20, dedupKey: "old"),
        ])

        let snapshot = try UsageStoreStatsProvider.snapshot(
            store: store, now: now, activeSessions: 5, calendar: calendar, timeZone: tz
        )

        XCTAssertEqual(snapshot.summary.todayTokens, 600)
        // (600 - 250) / 250
        XCTAssertEqual(snapshot.summary.todayDeltaVsYesterday!, 1.4, accuracy: 1e-9)
        // 9500 / (9500 + 100 + 40)
        XCTAssertEqual(snapshot.summary.cacheHitRate!, 9_500.0 / 9_640.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.summary.cacheReadTokens, 9_500)
        XCTAssertEqual(snapshot.summary.cacheWriteTokens, 50)
        XCTAssertEqual(snapshot.summary.activeSessions, 5)
        XCTAssertEqual(snapshot.summary.activeToolCount, 2)
        XCTAssertNil(snapshot.summary.equivalentCostToday)
        XCTAssertNil(snapshot.summary.costWeekToDate)

        XCTAssertEqual(snapshot.daily.count, 7)
        XCTAssertEqual(snapshot.daily[0].values[.claude], 30)
        XCTAssertEqual(snapshot.daily[5].values[.claude], 250)
        XCTAssertEqual(snapshot.daily[6].values[.claude], 500)
        XCTAssertEqual(snapshot.daily[6].values[.codex], 100)
        XCTAssertTrue(snapshot.daily[6].label.hasPrefix("07-12"))
    }

    func testWeeklyBucketsAndDetailRows() throws {
        let store = try makeStore()
        try store.record([
            event(input: 100, output: 300, cacheRead: 1_000, cacheWrite: 10, dedupKey: "w0"),
            event(tool: "codex", model: "gpt-5-codex", input: 30, output: 70, dedupKey: "w0-codex"),
            // Clearly in an earlier week regardless of week convention
            event(daysAgo: 14, input: 500, output: 1_500, dedupKey: "w2"),
        ])

        let snapshot = try UsageStoreStatsProvider.snapshot(
            store: store, now: now, activeSessions: 0, calendar: calendar, timeZone: tz
        )

        XCTAssertEqual(snapshot.weekly.count, 8)
        // All recorded tokens appear somewhere in the 8 weekly buckets
        XCTAssertEqual(snapshot.weekly.reduce(0) { $0 + $1.total }, 2_500)
        // Today's events land in the last (current) week
        XCTAssertEqual(snapshot.weekly.last?.values[.codex], 100)
        // The 14-days-ago event is not in the current week
        XCTAssertEqual(snapshot.weekly.last?.values[.claude], 400)

        // Detail table covers the current week only
        XCTAssertEqual(snapshot.detailRows.count, 2)
        let claudeRow = snapshot.detailRows.first { $0.tool == .claude }!
        XCTAssertEqual(claudeRow.toolName, "Claude")
        XCTAssertEqual(claudeRow.model, "claude-fable-5")
        XCTAssertEqual(claudeRow.input, 100)
        XCTAssertEqual(claudeRow.output, 300)
        XCTAssertEqual(claudeRow.cacheRead, 1_000)
        XCTAssertEqual(claudeRow.cacheWrite, 10)
        XCTAssertNil(claudeRow.cost)
        XCTAssertEqual(claudeRow.share, 400.0 / 500.0, accuracy: 1e-9)
        // Largest volume first
        XCTAssertEqual(snapshot.detailRows.first?.tool, .claude)
    }

    func testDetailRowsMergeToolIdsSharingASeries() throws {
        let store = try makeStore()
        try store.record([
            event(tool: "claude-code", input: 10, output: 40, dedupKey: "a"),
            event(tool: "claude-desktop", input: 5, output: 15, dedupKey: "b"),
        ])
        let snapshot = try UsageStoreStatsProvider.snapshot(
            store: store, now: now, activeSessions: 0, calendar: calendar, timeZone: tz
        )
        XCTAssertEqual(snapshot.detailRows.count, 1)
        XCTAssertEqual(snapshot.detailRows[0].input, 15)
        XCTAssertEqual(snapshot.detailRows[0].output, 55)
        XCTAssertEqual(snapshot.detailRows[0].share, 1.0, accuracy: 1e-9)
    }
}
