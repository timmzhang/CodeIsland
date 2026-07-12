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
        project: String = "",
        daysAgo: Int = 0, hoursAgo: Int = 0,
        input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0,
        dedupKey: String
    ) -> UsageEvent {
        UsageEvent(
            tool: tool, sessionId: "s", model: model, project: project,
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
        // fable-5 today: (100×10 + 400×50 + 50×12.5 + 9500×1.0) / 1e6 = 0.031125
        // gpt-5-codex today: (40×1.25 + 60×10) / 1e6 = 0.00065
        XCTAssertEqual(snapshot.summary.equivalentCostToday!, 0.031775, accuracy: 1e-9)
        // The gregorian current week (07-12 Sun onward) holds only today's events.
        XCTAssertEqual(snapshot.summary.costWeekToDate!, 0.031775, accuracy: 1e-9)

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
        // (100×10 + 300×50 + 10×12.5 + 1000×1.0) / 1e6
        XCTAssertEqual(claudeRow.cost!, 0.017125, accuracy: 1e-9)
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

    // MARK: Pricing edge cases & rankings

    func testUnpricedOnlyUsageShowsNoCostInsteadOfZero() throws {
        let store = try makeStore()
        try store.record([event(model: "mystery-model", input: 100, output: 100, dedupKey: "u")])
        let snapshot = try UsageStoreStatsProvider.snapshot(
            store: store, now: now, activeSessions: 0, calendar: calendar, timeZone: tz
        )
        XCTAssertNil(snapshot.summary.equivalentCostToday, "all-unpriced usage renders — not $0.00")
        XCTAssertNil(snapshot.summary.costWeekToDate)
        XCTAssertNil(snapshot.detailRows[0].cost)
    }

    func testEmptyStoreCostIsZeroNotNil() throws {
        let snapshot = try UsageStoreStatsProvider.snapshot(
            store: try makeStore(), now: now, activeSessions: 0, calendar: calendar, timeZone: tz
        )
        XCTAssertEqual(snapshot.summary.equivalentCostToday, 0, "no usage genuinely costs $0")
    }

    func testSettingsOverrideChangesCost() throws {
        let store = try makeStore()
        try store.record([event(input: 1_000_000, output: 0, dedupKey: "o")])
        let overridden = try UsageStoreStatsProvider.snapshot(
            store: store, now: now, activeSessions: 0, calendar: calendar, timeZone: tz,
            priceTable: UsagePriceTable(overrides: UsagePriceTable.parseOverrides(
                json: #"{"fable": {"input": 100, "output": 1}}"#
            )!)
        )
        XCTAssertEqual(overridden.summary.equivalentCostToday!, 100, accuracy: 1e-9)
    }

    func testTopRankingsComeFromCurrentWeek() throws {
        let store = try makeStore()
        try store.record([
            event(project: "/w/CodeIsland", input: 100, output: 200, dedupKey: "p1"),
            event(project: "/w/CodeIsland_p-kstm", input: 50, output: 50, dedupKey: "p1w"),
            event(tool: "codex", model: "gpt-5-codex", project: "", input: 10, output: 30, dedupKey: "p2"),
            // Previous weeks stay out of the ranking window
            event(project: "/w/old-project", daysAgo: 14, input: 9_999, output: 0, dedupKey: "p3"),
        ])
        let snapshot = try UsageStoreStatsProvider.snapshot(
            store: store, now: now, activeSessions: 0, calendar: calendar, timeZone: tz
        )
        XCTAssertEqual(snapshot.topProjects.first?.name, "CodeIsland")
        XCTAssertEqual(snapshot.topProjects.first?.tokens, 400, "worktree tokens fold into the main project")
        XCTAssertFalse(snapshot.topProjects.contains { $0.name == "old-project" })
        XCTAssertEqual(snapshot.topTools.first?.name, "Claude")
        XCTAssertEqual(snapshot.topTools.map(\.name).count, 2)
    }

    // MARK: Weekly insight (L3)

    private func rawEvent(_ date: Date, input: Int64, output: Int64 = 0, key: String) -> UsageEvent {
        UsageEvent(
            tool: "claude-code", sessionId: "s", model: "claude-fable-5", project: "",
            timestamp: date, inputTokens: input, outputTokens: output,
            cacheReadTokens: 0, cacheWriteTokens: 0, dedupKey: key
        )
    }

    private func at(_ day: Int, hour: Int) -> Date {
        DateComponents(calendar: calendar, timeZone: tz, year: 2026, month: 7, day: day, hour: hour).date!
    }

    func testWeeklyInsightDailyAveragePeakAndHeatmap() throws {
        // The gregorian default week for `now` runs Sun 07-12 … Sat 07-18.
        // `now` here is Wed 07-15 18:00, so the week-to-date spans 4 days.
        let wed = at(15, hour: 18)
        let store = try makeStore()
        try store.record([
            rawEvent(at(12, hour: 9), input: 100, output: 100, key: "sun"),   // 200, Sunday
            rawEvent(at(13, hour: 9), input: 100, output: 100, key: "mon"),   // 200, Monday
            rawEvent(at(14, hour: 15), input: 300, output: 300, key: "tue"),  // 600, Tuesday 15:00 -> bucket 7
        ])

        let snapshot = try UsageStoreStatsProvider.snapshot(
            store: store, now: wed, activeSessions: 0, calendar: calendar, timeZone: tz
        )
        let insight = snapshot.weeklyInsight

        XCTAssertEqual(insight.weekTokens, 1000)
        XCTAssertEqual(insight.dailyAverageTokens, 250, "1000 tokens / 4 elapsed days (Sun…Wed)")
        XCTAssertEqual(insight.peakDayTokens, 600, "Tuesday is the busiest day so far")
        XCTAssertFalse(insight.peakDayLabel.isEmpty)
        XCTAssertNil(insight.deltaVsLastWeek, "no prior-week data recorded")

        XCTAssertEqual(insight.heatmap.count, 84, "7 weekdays × 12 two-hour buckets")
        // Monday-first row index: Sunday -> 6, Monday -> 0, Tuesday -> 1.
        XCTAssertEqual(insight.heatmap.first { $0.weekday == 6 && $0.hourBucket == 4 }?.tokens, 200)
        XCTAssertEqual(insight.heatmap.first { $0.weekday == 0 && $0.hourBucket == 4 }?.tokens, 200)
        let tuesdayCell = insight.heatmap.first { $0.weekday == 1 && $0.hourBucket == 7 }
        XCTAssertEqual(tuesdayCell?.tokens, 600)
        XCTAssertEqual(tuesdayCell?.intensity, 1.0, "the busiest cell always has full intensity")
        XCTAssertEqual(insight.heatmap.filter { $0.tokens == 0 }.count, 81, "84 cells - 3 populated")
    }

    func testWeeklyInsightDeltaVsSameElapsedPortionOfLastWeek() throws {
        // `now` is Tue 07-14 12:00 — this week (Sun…Tue-noon) vs the same
        // Sun…Tue-noon window last week, not last week's whole Tuesday.
        let tue = at(14, hour: 12)
        let store = try makeStore()
        try store.record([
            rawEvent(at(12, hour: 9), input: 100, key: "w-sun"),
            rawEvent(at(13, hour: 9), input: 100, key: "w-mon"),
            rawEvent(at(14, hour: 9), input: 100, key: "w-tue"),
            rawEvent(at(5, hour: 9), input: 50, key: "lw-sun"),
            rawEvent(at(6, hour: 9), input: 50, key: "lw-mon"),
            // After last week's comparable cutoff (Tue 12:00) — must not count.
            rawEvent(at(7, hour: 18), input: 999, key: "lw-late-tue"),
        ])

        let snapshot = try UsageStoreStatsProvider.snapshot(
            store: store, now: tue, activeSessions: 0, calendar: calendar, timeZone: tz
        )
        // (300 - 100) / 100
        XCTAssertEqual(snapshot.weeklyInsight.deltaVsLastWeek!, 2.0, accuracy: 1e-9)
    }
}
