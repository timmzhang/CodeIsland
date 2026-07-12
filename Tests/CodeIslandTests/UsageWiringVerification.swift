import XCTest
import SwiftUI
import CodeIslandCore
@testable import CodeIsland

/// End-to-end verification harness for the usage wiring: drives the real
/// UsageManager pipeline — full backfill of the machine's actual
/// ~/.claude/projects transcripts into a scratch SQLite store, live ingest,
/// dedup, snapshot push — then renders the real L1 views and the L2 stats
/// window from that data. Skipped unless USAGE_VERIFY_DIR is set (it reads
/// the operator's real transcripts, so it can't run in CI).
@MainActor
final class UsageWiringVerification: XCTestCase {

    func testRealPipeline() async throws {
        guard let dir = ProcessInfo.processInfo.environment["USAGE_VERIFY_DIR"] else {
            throw XCTSkip("USAGE_VERIFY_DIR not set")
        }

        let storePath = dir + "/usage-verify.sqlite"
        UsageManager.shared.start(storePath: storePath)

        // Wait until backfill has populated today's snapshot and it stays
        // stable for 3 consecutive seconds (throttled pushes keep landing
        // while the scan runs).
        var lastTotal = -1
        var stableSeconds = 0
        var waited = 0
        while stableSeconds < 3 && waited < 180 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
            let total = UsageStatsModel.shared.today.totalTokens
            if total == lastTotal && total > 0 {
                stableSeconds += 1
            } else {
                stableSeconds = 0
                lastTotal = total
            }
        }
        let l1 = UsageStatsModel.shared.today
        print("VERIFY-L1 waited=\(waited)s totalTokens=\(l1.totalTokens) cacheHitRate=\(String(describing: l1.cacheHitRate)) last7=\(l1.last7DayTokens) perTool=\(l1.perTool.map { "\($0.tool):\($0.tokens)" })")
        XCTAssertTrue(l1.hasData, "backfill of real transcripts produced no data")
        XCTAssertGreaterThan(l1.totalTokens, 0, "this machine has Claude usage today; today must be > 0")

        // Live-tail path: inject one synthetic event through the same entry
        // point AppState.applyTranscriptDelta uses and watch the snapshot bump.
        let before = l1.totalTokens
        let runId = UUID().uuidString
        UsageManager.shared.ingestClaude([
            ClaudeUsageEvent(
                sessionId: "verify-harness", messageId: "verify-\(runId)", requestId: "verify-req-1",
                model: "claude-fable-5", timestamp: Date(),
                inputTokens: 123_456, outputTokens: 654_321,
                cacheCreationTokens: 0, cacheReadTokens: 0, isSidechain: false
            )
        ])
        var bumped = false
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if UsageStatsModel.shared.today.totalTokens == before + 777_777 {
                bumped = true
                break
            }
        }
        print("VERIFY-INGEST before=\(before) after=\(UsageStatsModel.shared.today.totalTokens) bumped=\(bumped)")
        XCTAssertTrue(bumped, "live ingest did not reach the L1 snapshot")

        // Idempotency: same dedup key again must not double-count.
        UsageManager.shared.ingestClaude([
            ClaudeUsageEvent(
                sessionId: "verify-harness", messageId: "verify-\(runId)", requestId: "verify-req-1",
                model: "claude-fable-5", timestamp: Date(),
                inputTokens: 123_456, outputTokens: 654_321,
                cacheCreationTokens: 0, cacheReadTokens: 0, isSidechain: false
            )
        ])
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let afterDup = UsageStatsModel.shared.today.totalTokens
        print("VERIFY-DEDUP after-duplicate=\(afterDup)")
        XCTAssertEqual(afterDup, before + 777_777, "duplicate event was double-counted")

        // L2 provider over the same store.
        let store = try XCTUnwrap(UsageManager.shared.currentStore())
        let l2 = try UsageStoreStatsProvider.snapshot(store: store, now: Date(), activeSessions: 7)
        print("VERIFY-L2 today=\(l2.summary.todayTokens) deltaVsYtd=\(String(describing: l2.summary.todayDeltaVsYesterday)) cacheHit=\(String(describing: l2.summary.cacheHitRate)) tools=\(l2.summary.activeToolCount) dailyTotals=\(l2.daily.map(\.total)) weeklyTotals=\(l2.weekly.map(\.total)) detailRows=\(l2.detailRows.map { "\($0.toolName)/\($0.model) in=\($0.input) out=\($0.output) share=\(String(format: "%.2f", $0.share))" })")
        XCTAssertEqual(l2.summary.todayTokens, UsageStatsModel.shared.today.totalTokens,
                       "L1 and L2 must agree on today's total")
        XCTAssertFalse(l2.detailRows.isEmpty)

        // Render the real views from this data.
        try render(UsageBadgeView().padding(8), to: "\(dir)/l1-badge-real.png")
        try render(UsageToolbarEntry().padding(8), to: "\(dir)/l1-entry-real.png")
        try render(UsageTodaySection().frame(width: 380), to: "\(dir)/l1-section-real.png")
        // ImageRenderer skips ScrollView content; capture through NSHostingView.
        let hosting = NSHostingView(
            rootView: UsageStatsView(provider: UsageStoreStatsProvider(activeSessionCount: { 7 }), initialSnapshot: l2)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 880, height: 1000)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "\(dir)/l2-window-real.png"))
        UsageManager.shared.stop()
    }

    private func render(_ view: some View, to path: String) throws {
        let renderer = ImageRenderer(content: view.background(Color.black))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else {
            return XCTFail("render failed for \(path)")
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
