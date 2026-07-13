import XCTest
import CodeIslandCore
@testable import CodeIsland

/// Pure assembly logic behind the in-panel usage detail page (p-cfj6):
/// N-day trend collapsing and today's per-session (worktree) ranking.
@MainActor
final class UsageDetailPageTests: XCTestCase {
    override func setUp() {
        L10n.shared.language = "en"
    }

    override func tearDown() {
        L10n.shared.language = "system"
    }

    private func totals(_ input: Int64, _ output: Int64) -> UsageTotals {
        UsageTotals(inputTokens: input, outputTokens: output, cacheReadTokens: 0, cacheWriteTokens: 0)
    }

    // MARK: - Trend

    func testTrendDaysCollapsesToolsAndZeroFillsMissingDays() {
        let keys = ["2026-07-11", "2026-07-12", "2026-07-13"]
        let rows = [
            DailyToolUsage(day: "2026-07-11", tool: "claude", totals: totals(100, 200)),
            DailyToolUsage(day: "2026-07-11", tool: "codex", totals: totals(50, 50)),
            DailyToolUsage(day: "2026-07-13", tool: "claude", totals: totals(1000, 2000)),
            // Outside the window — ignored
            DailyToolUsage(day: "2026-07-01", tool: "claude", totals: totals(9, 9)),
        ]

        let trend = UsageDetailPageModel.trendDays(from: rows, dayKeys: keys)

        XCTAssertEqual(trend.map(\.tokens), [400, 0, 3000])
        XCTAssertEqual(trend.map(\.label), ["11", "12", "13"])
        XCTAssertEqual(trend.map(\.isToday), [false, false, true])
    }

    // MARK: - Session distribution

    func testSessionRowsKeepWorktreeSuffixesDistinct() {
        let rows = UsageDetailPageModel.sessionRows(from: [
            (project: "/Users/me/ws/pins_p-pgy1", tokens: 4500),
            (project: "/Users/me/ws/pins", tokens: 2500),
        ])

        // Unlike the weekly Top-projects ranking, "pins_p-pgy1" must NOT fold into "pins".
        XCTAssertEqual(rows.map(\.name), ["pins_p-pgy1", "pins"])
        XCTAssertEqual(rows.map(\.tokens), [4500, 2500])
        XCTAssertEqual(rows[0].fraction, 1.0)
        XCTAssertEqual(rows[1].fraction, 2500.0 / 4500.0, accuracy: 0.0001)
    }

    func testSessionRowsBucketUnattributedAndDropZeroRows() {
        let rows = UsageDetailPageModel.sessionRows(from: [
            (project: "", tokens: 300),
            (project: "/Users/me/ws/idle", tokens: 0),
        ])

        XCTAssertEqual(rows.map(\.name), [L10n.shared["usage_project_unknown"]])
        XCTAssertEqual(rows.first?.tokens, 300)
    }

    func testSessionRowsFoldLongTailIntoOthers() {
        let projects = (1...11).map { (project: "/ws/proj\(String(format: "%02d", $0))", tokens: 1000 * (12 - $0)) }

        let rows = UsageDetailPageModel.sessionRows(from: projects)

        XCTAssertEqual(rows.count, UsageDetailPageModel.maxSessionRows + 1)
        let others = try! XCTUnwrap(rows.last)
        XCTAssertEqual(others.name, String(format: L10n.shared["usage_rank_others"], 3))
        // proj09 (3000) + proj10 (2000) + proj11 (1000)
        XCTAssertEqual(others.tokens, 6000)
    }

    func testSessionRowsDoNotFoldASingleTailRow() {
        // maxSessionRows + 1 entries: folding one row would just rename it.
        let projects = (1...9).map { (project: "/ws/proj\($0)", tokens: 100 * (10 - $0)) }

        let rows = UsageDetailPageModel.sessionRows(from: projects)

        XCTAssertEqual(rows.count, 9)
        XCTAssertEqual(rows.last?.name, "proj9")
    }
}
