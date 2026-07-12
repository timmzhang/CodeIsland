import XCTest
@testable import CodeIsland

final class UsageStatsTests: XCTestCase {

    // MARK: - UsageFormat.compactTokens

    func testCompactTokensBelowThousand() {
        XCTAssertEqual(UsageFormat.compactTokens(0), "0")
        XCTAssertEqual(UsageFormat.compactTokens(950), "950")
    }

    func testCompactTokensThousands() {
        XCTAssertEqual(UsageFormat.compactTokens(30_000), "30K")
        XCTAssertEqual(UsageFormat.compactTokens(410_000), "410K")
    }

    func testCompactTokensMillions() {
        XCTAssertEqual(UsageFormat.compactTokens(2_030_000), "2.03M")
        XCTAssertEqual(UsageFormat.compactTokens(1_420_000), "1.42M")
        XCTAssertEqual(UsageFormat.compactTokens(15_600_000), "15.6M")
        XCTAssertEqual(UsageFormat.compactTokens(230_000_000), "230M")
    }

    func testEquivalentCostAndPercent() {
        XCTAssertEqual(UsageFormat.equivalentCost(3.87), "≈$3.87")
        XCTAssertEqual(UsageFormat.percent(0.914), "91.4%")
    }

    // MARK: - Tool identifier mapping

    func testToolDisplayNameFoldsProviderIdentifiers() {
        // Providers report ids like "claude-code" (ClaudeUsageProvider.toolIdentifier)
        XCTAssertEqual(usageToolDisplayName("claude-code"), "Claude")
        XCTAssertEqual(usageToolDisplayName("claude"), "Claude")
        XCTAssertEqual(usageToolDisplayName("codex"), "Codex")
        XCTAssertEqual(usageToolDisplayName("trae"), "Trae")
    }

    // MARK: - UsageTodaySnapshot.hasData

    func testEmptySnapshotHasNoData() {
        XCTAssertFalse(UsageTodaySnapshot().hasData)
    }

    func testSnapshotWithTodayTokensHasData() {
        var snapshot = UsageTodaySnapshot()
        snapshot.totalTokens = 1
        XCTAssertTrue(snapshot.hasData)
    }

    func testSnapshotWithOnlyHistoryHasData() {
        // Zero usage today but activity earlier in the week still renders the badge
        var snapshot = UsageTodaySnapshot()
        snapshot.last7DayTokens = [500_000, 0, 0, 0, 0, 0, 0]
        XCTAssertTrue(snapshot.hasData)
    }

    // MARK: - Model update

    @MainActor
    func testModelUpdatePublishesSnapshot() {
        var snapshot = UsageTodaySnapshot()
        snapshot.totalTokens = 42
        UsageStatsModel.shared.update(snapshot)
        XCTAssertEqual(UsageStatsModel.shared.today.totalTokens, 42)
        UsageStatsModel.shared.update(UsageTodaySnapshot())
    }
}
