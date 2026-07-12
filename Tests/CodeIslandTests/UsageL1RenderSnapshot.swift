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
        try render(UsageToolbarEntry().padding(8), to: "\(dir)/entry.png")
        try render(UsageTodaySection().frame(width: 380), to: "\(dir)/section.png")
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
