import XCTest
import SwiftUI
@testable import CodeIsland

/// Visual verification utility: renders the three L1 usage views to PNGs
/// in $USAGE_SNAPSHOT_DIR for eyeballing against the design mockup.
/// Skipped unless that env var is set.
@MainActor
final class UsageL1RenderSnapshot: XCTestCase {

    func testRenderL1Views() throws {
        guard let dir = ProcessInfo.processInfo.environment["USAGE_SNAPSHOT_DIR"] else {
            throw XCTSkip("USAGE_SNAPSHOT_DIR not set")
        }

        var snapshot = UsageTodaySnapshot()
        snapshot.totalTokens = 2_030_000
        snapshot.equivalentCostUSD = 3.87
        snapshot.cacheHitRate = 0.914
        snapshot.last7DayTokens = [1_200_000, 800_000, 1_600_000, 2_100_000, 1_500_000, 1_900_000, 2_030_000]
        snapshot.perTool = [
            .init(tool: "claude", tokens: 1_420_000),
            .init(tool: "codex", tokens: 410_000),
            .init(tool: "gemini", tokens: 150_000),
            .init(tool: "kimi", tokens: 30_000),
        ]
        UsageStatsModel.shared.update(snapshot)

        try render(UsageBadgeView().padding(8), to: "\(dir)/badge.png")
        try render(UsageToolbarEntry(popover: UsagePopoverState(), onOpenDetail: {}).padding(8), to: "\(dir)/entry.png")
        try render(UsageTodaySection().frame(width: 380), to: "\(dir)/section.png")
        try render(UsageHoverPopover(popover: UsagePopoverState(), onOpenDetail: {}).padding(8), to: "\(dir)/popover.png")

        let page = UsageDetailPageModel()
        page.seed(
            trend: [
                .init(dayKey: "2026-07-07", label: "07", tokens: 1_200_000, isToday: false),
                .init(dayKey: "2026-07-08", label: "08", tokens: 800_000, isToday: false),
                .init(dayKey: "2026-07-09", label: "09", tokens: 1_600_000, isToday: false),
                .init(dayKey: "2026-07-10", label: "10", tokens: 2_100_000, isToday: false),
                .init(dayKey: "2026-07-11", label: "11", tokens: 1_500_000, isToday: false),
                .init(dayKey: "2026-07-12", label: "12", tokens: 1_900_000, isToday: false),
                .init(dayKey: "2026-07-13", label: "13", tokens: 2_030_000, isToday: true),
            ],
            sessions: [
                .init(name: "pins_p-pgy1", tokens: 4_500_000, fraction: 1.0),
                .init(name: "pins", tokens: 2_500_000, fraction: 0.55),
                .init(name: "CodeIsland_p-cfj6", tokens: 1_100_000, fraction: 0.24),
            ]
        )
        // ImageRenderer skips ScrollView/Menu content; capture through NSHostingView.
        let hosting = NSHostingView(
            rootView: UsageDetailView(appState: AppState(), page: page)
                .frame(width: 580)
                .background(Color.black)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 580, height: 520)
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "\(dir)/detail-page.png"))
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
