import XCTest
@testable import CodeIsland

final class UsageStatsWindowTests: XCTestCase {

    // MARK: Token formatting

    func testAbbreviatedBelowThousand() {
        XCTAssertEqual(UsageTokenFormat.abbreviated(0), "0")
        XCTAssertEqual(UsageTokenFormat.abbreviated(940), "940")
    }

    func testAbbreviatedThousands() {
        XCTAssertEqual(UsageTokenFormat.abbreviated(1000), "1K")
        XCTAssertEqual(UsageTokenFormat.abbreviated(410_000), "410K")
        XCTAssertEqual(UsageTokenFormat.abbreviated(999_400), "999K")
    }

    func testAbbreviatedMillions() {
        XCTAssertEqual(UsageTokenFormat.abbreviated(2_600_000), "2.6M")
        XCTAssertEqual(UsageTokenFormat.abbreviated(2_034_000, millionDecimals: 2), "2.03M")
        // ≥10M drops decimals, matching the mockup formatter.
        XCTAssertEqual(UsageTokenFormat.abbreviated(12_700_000), "13M")
        XCTAssertEqual(UsageTokenFormat.abbreviated(38_200_000), "38M")
    }

    func testCostAndPercent() {
        XCTAssertEqual(UsageTokenFormat.cost(3.87), "$3.87")
        XCTAssertEqual(UsageTokenFormat.percent(0.914), "91.4%")
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
}
