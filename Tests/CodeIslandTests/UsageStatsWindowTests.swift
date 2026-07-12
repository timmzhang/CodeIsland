import XCTest
import SwiftUI
@testable import CodeIsland

final class UsageStatsWindowTests: XCTestCase {

    // MARK: Formatting used by the window (shared UsageFormat)

    func testCompactTokensTrimsTrailingZeros() {
        XCTAssertEqual(UsageFormat.compactTokens(1_900_000), "1.9M")
        XCTAssertEqual(UsageFormat.compactTokens(2_000_000), "2M")
        XCTAssertEqual(UsageFormat.compactTokens(38_200_000), "38.2M")
    }

    func testPlainCost() {
        XCTAssertEqual(UsageFormat.cost(3.87), "$3.87")
        XCTAssertEqual(UsageFormat.cost(30.6), "$30.60")
    }

    // MARK: Tool identifier folding

    func testToolIdentifierFoldsOntoSeries() {
        XCTAssertEqual(UsageTool(toolIdentifier: "claude-code"), .claude)
        XCTAssertEqual(UsageTool(toolIdentifier: "Codex"), .codex)
        XCTAssertEqual(UsageTool(toolIdentifier: "gemini-cli"), .gemini)
        XCTAssertEqual(UsageTool(toolIdentifier: "kimi"), .kimi)
        XCTAssertEqual(UsageTool(toolIdentifier: "trae"), .other)
        XCTAssertEqual(UsageTool(toolIdentifier: "otherwise-unknown"), .other)
    }

    // MARK: Chart segment building

    func testSegmentsEmptyWhenNoData() {
        XCTAssertTrue(UsageChartBuilder.segments(for: []).isEmpty)
        let zeroBucket = UsageBucket(label: "07-11", values: [:])
        XCTAssertTrue(UsageChartBuilder.segments(for: [zeroBucket]).isEmpty)
    }

    func testSegmentsStackInToolOrderWithGap() {
        let bucket = UsageBucket(label: "07-11", values: [
            .claude: 1000, .codex: 400, .gemini: 100,
        ])
        let segments = UsageChartBuilder.segments(for: [bucket])
        XCTAssertEqual(segments.map(\.tool), [.claude, .codex, .gemini])

        let gap = 1500.0 * UsageChartBuilder.gapFraction

        // Bottom segment starts at 0 with no gap.
        XCTAssertEqual(segments[0].yStart, 0)
        XCTAssertEqual(segments[0].yEnd, 1000)
        XCTAssertFalse(segments[0].isTop)

        // Middle segment is inset by the gap but ends at its cumulative value.
        XCTAssertEqual(segments[1].yStart, 1000 + gap, accuracy: 0.001)
        XCTAssertEqual(segments[1].yEnd, 1400)

        // Top segment carries the rounding flag and the bucket total.
        XCTAssertTrue(segments[2].isTop)
        XCTAssertEqual(segments[2].bucketTotal, 1500)
    }

    func testSegmentsSkipZeroValueTools() {
        let bucket = UsageBucket(label: "07-11", values: [
            .claude: 500, .codex: 0,
        ])
        let segments = UsageChartBuilder.segments(for: [bucket])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].tool, .claude)
        XCTAssertTrue(segments[0].isTop)
    }

    func testTinySegmentKeepsVisibleSliver() {
        // A value far smaller than the gap must not produce an inverted range.
        let bucket = UsageBucket(label: "07-11", values: [
            .claude: 100_000, .kimi: 10,
        ])
        let segments = UsageChartBuilder.segments(for: [bucket])
        let kimi = segments.first { $0.tool == .kimi }!
        XCTAssertGreaterThan(kimi.yEnd, kimi.yStart)
        XCTAssertGreaterThanOrEqual(kimi.yStart, 100_000)
    }

    func testGapScalesWithTallestBucket() {
        let buckets = [
            UsageBucket(label: "a", values: [.claude: 5000, .codex: 5000]),
            UsageBucket(label: "b", values: [.claude: 20_000]),
        ]
        let segments = UsageChartBuilder.segments(for: buckets)
        let codex = segments.first { $0.tool == .codex }!
        // Gap derives from the tallest bucket (20_000), not this bucket's total.
        XCTAssertEqual(codex.yStart, 5000 + 20_000 * UsageChartBuilder.gapFraction, accuracy: 0.001)
    }

    // MARK: Snapshot totals

    func testSnapshotDetailTotals() {
        let snapshot = SampleUsageStatsProvider.snapshot(now: Date())
        XCTAssertEqual(snapshot.detailTotalInput, 3_406_000)
        XCTAssertEqual(snapshot.detailTotalOutput, 12_690_000)
        XCTAssertEqual(snapshot.detailTotalCacheWrite, 2_606_000)
        XCTAssertEqual(snapshot.detailTotalCacheRead, 38_170_000)
        XCTAssertEqual(snapshot.detailTotalCost!, 30.60, accuracy: 0.001)
    }

    func testSnapshotTotalCostNilWhenNoCosts() {
        var snapshot = UsageStatsSnapshot()
        snapshot.detailRows = [
            UsageDetailRow(
                tool: .claude, toolName: "Claude Code", model: "m",
                input: 1, output: 1, cacheWrite: 0, cacheRead: 0,
                cost: nil, share: 1
            )
        ]
        XCTAssertNil(snapshot.detailTotalCost)
    }

    func testSampleBucketsMatchMockupShape() {
        let snapshot = SampleUsageStatsProvider.snapshot(now: Date())
        XCTAssertEqual(snapshot.daily.count, 7)
        XCTAssertEqual(snapshot.weekly.count, 8)
        // Today (last daily bucket) matches the summary tile: 2.03M main-metric tokens.
        XCTAssertEqual(snapshot.daily.last!.total, 2_030_000)
        // Labels are unique so the categorical x-axis cannot merge buckets.
        XCTAssertEqual(Set(snapshot.daily.map(\.label)).count, 7)
        XCTAssertEqual(Set(snapshot.weekly.map(\.label)).count, 8)
    }

    // MARK: Top rankings

    func testProjectDisplayNameFoldsWorktreeSuffix() {
        XCTAssertEqual(UsageRankingBuilder.projectDisplayName("/Users/me/Workspace/CodeIsland"), "CodeIsland")
        XCTAssertEqual(UsageRankingBuilder.projectDisplayName("/Users/me/Workspace/CodeIsland_p-kstm"), "CodeIsland")
        XCTAssertEqual(UsageRankingBuilder.projectDisplayName("/Users/me/pins_p-26sp"), "pins")
        XCTAssertEqual(UsageRankingBuilder.projectDisplayName("/w/snake_project"), "snake_project", "only pins-style suffixes fold")
    }

    func testProjectRowsFoldWorktreesAndRankDescending() {
        let rows = UsageRankingBuilder.projectRows([
            ("/w/CodeIsland", 500),
            ("/w/CodeIsland_p-kstm", 700),
            ("/w/pins", 900),
            ("", 100),
        ])
        XCTAssertEqual(Array(rows.map(\.name).prefix(2)), ["CodeIsland", "pins"], "worktree usage merges into the main project")
        XCTAssertEqual(rows[0].tokens, 1200)
        XCTAssertEqual(rows[0].fraction, 1, "bar widths are relative to the largest row")
        XCTAssertEqual(rows[0].share, 1200.0 / 2200.0, accuracy: 0.0001)
        XCTAssertEqual(rows.count, 3, "no aggregate row for 3 entries")
    }

    func testRankFoldsTailIntoOthersOnlyWhenItSavesARow() {
        let color = UsageTool.claude.color
        let five = (1...5).map { (name: "p\($0)", tokens: $0 * 100, color: color) }
        let ranked = UsageRankingBuilder.rank(five)
        XCTAssertEqual(ranked.count, 4, "top 3 + one aggregate")
        XCTAssertEqual(ranked.last!.tokens, 300, "aggregate sums the folded tail (100 + 200)")

        let four = (1...4).map { (name: "p\($0)", tokens: $0 * 100, color: color) }
        XCTAssertEqual(UsageRankingBuilder.rank(four).count, 4, "folding one row would just rename it")
        XCTAssertTrue(UsageRankingBuilder.rank([]).isEmpty)
    }

    func testToolRowsGroupDetailRowsByTool() {
        let snapshot = SampleUsageStatsProvider.snapshot(now: Date())
        let rows = UsageRankingBuilder.toolRows(fromDetail: snapshot.detailRows)
        XCTAssertEqual(rows.first?.name, "Claude Code", "the two Claude model rows merge into one tool row")
        XCTAssertEqual(rows.first?.tokens, 1_900_000 + 8_600_000 + 310_000 + 720_000)
        let shareSum = rows.reduce(0.0) { $0 + $1.share }
        XCTAssertEqual(shareSum, 1.0, accuracy: 0.0001, "shares cover the whole ranking even with an aggregate row")
    }

    func testSampleSnapshotCarriesRankings() {
        let snapshot = SampleUsageStatsProvider.snapshot(now: Date())
        XCTAssertFalse(snapshot.topProjects.isEmpty)
        XCTAssertFalse(snapshot.topTools.isEmpty)
        XCTAssertEqual(snapshot.topProjects.first?.name, "CodeIsland")
    }

    // MARK: Weekly insight (L3)

    func testSampleSnapshotCarriesWeeklyInsight() {
        let snapshot = SampleUsageStatsProvider.snapshot(now: Date())
        let insight = snapshot.weeklyInsight
        XCTAssertTrue(insight.hasData)
        XCTAssertEqual(insight.weekTokens, 16_100_000)
        XCTAssertEqual(insight.deltaVsLastWeek, 0.23)
        XCTAssertEqual(insight.heatmap.count, 84, "7 weekdays × 12 two-hour buckets")
        XCTAssertTrue(insight.heatmap.contains { $0.intensity == 1.0 }, "the busiest cell reaches full intensity")
    }

    func testEmptyWeeklyInsightHasNoData() {
        XCTAssertFalse(UsageWeeklyInsight().hasData)
    }

    func testUsageRampInterpolatesBetweenEndpoints() {
        XCTAssertEqual(Color.usageRamp(0x181D26, 0x86B6EF, 0), Color(usageHex: 0x181D26))
        XCTAssertEqual(Color.usageRamp(0x181D26, 0x86B6EF, 1), Color(usageHex: 0x86B6EF))
        // Clamps out-of-range intensities instead of extrapolating past the endpoints.
        XCTAssertEqual(Color.usageRamp(0x181D26, 0x86B6EF, -1), Color(usageHex: 0x181D26))
        XCTAssertEqual(Color.usageRamp(0x181D26, 0x86B6EF, 2), Color(usageHex: 0x86B6EF))
    }

    func testInsightTextIncludesWeekTotalDeltaAndRankings() {
        let snapshot = SampleUsageStatsProvider.snapshot(now: Date())
        let text = UsageInsightText.build(snapshot: snapshot, l10n: L10n.shared)
        XCTAssertTrue(text.contains("16.1M"))
        XCTAssertTrue(text.contains("23%"))
        XCTAssertTrue(text.contains("CodeIsland"))
        XCTAssertTrue(text.contains("Claude"))
    }

    func testInsightTextOmitsMissingSections() {
        var snapshot = UsageStatsSnapshot()
        snapshot.weeklyInsight = UsageWeeklyInsight(weekTokens: 500_000, weekCost: nil, dailyAverageTokens: 0)
        let text = UsageInsightText.build(snapshot: snapshot, l10n: L10n.shared)
        XCTAssertEqual(text.split(separator: "\n").count, 1, "no delta, no daily-avg, no rankings — just the week total")
        XCTAssertTrue(text.contains("500K"))
    }
}
