import SwiftUI

// MARK: - Tool identity

/// Tool identity for usage stats. `allCases` order is the chart stacking
/// order (bottom → top) and the legend order. Colors come from the design
/// spec (docs/design/token-usage.md §3) and are validated against the dark
/// window background #111318 — do not swap them for system accent colors.
enum UsageTool: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude
    case codex
    case gemini
    case kimi
    case other

    var id: String { rawValue }

    /// Folds provider tool identifiers ("claude-code", "codex", …) onto the
    /// five chart series; unrecognized tools land in `.other`.
    init(toolIdentifier: String) {
        let lowered = toolIdentifier.lowercased()
        self = UsageTool.allCases.first { $0 != .other && lowered.hasPrefix($0.rawValue) } ?? .other
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .kimi: return "Kimi"
        case .other: return L10n.shared["usage_tool_other"]
        }
    }

    var color: Color {
        switch self {
        case .claude: return Color(usageHex: 0xD95926)
        case .codex: return Color(usageHex: 0x199E70)
        case .gemini: return Color(usageHex: 0x3987E5)
        case .kimi: return Color(usageHex: 0xC98500)
        case .other: return Color(usageHex: 0x9085E9)
        }
    }
}

extension Color {
    /// 0xRRGGBB → opaque Color, sRGB.
    init(usageHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1
        )
    }
}

// MARK: - Snapshot model (view-facing)

/// One chart bucket (a day or a week). `values` hold main-metric tokens
/// (input + output — cache reads are excluded from the chart by design).
struct UsageBucket: Identifiable, Sendable {
    let label: String
    let values: [UsageTool: Int]

    var id: String { label }
    var total: Int { values.values.reduce(0, +) }
}

/// One row of the tool × model detail table. Token counts are raw tokens.
/// `cost` is the equivalent API cost in USD; nil until cost conversion
/// lands (P2). `share` is this row's fraction of the main metric, 0...1.
struct UsageDetailRow: Identifiable, Sendable {
    let tool: UsageTool
    let toolName: String
    let model: String
    let input: Int
    let output: Int
    let cacheWrite: Int
    let cacheRead: Int
    let cost: Double?
    let share: Double

    var id: String { "\(tool.rawValue)|\(model)" }
}

/// Numbers for the four summary tiles.
struct UsageSummary: Sendable {
    /// Today's input + output tokens.
    var todayTokens: Int = 0
    /// Fractional change vs the same time yesterday (0.12 = +12%); nil hides the delta line.
    var todayDeltaVsYesterday: Double?
    /// Equivalent API cost today, USD; nil until cost conversion lands.
    var equivalentCostToday: Double?
    /// Week-to-date equivalent cost, USD.
    var costWeekToDate: Double?
    /// Cache hit rate 0...1; nil hides the tile value.
    var cacheHitRate: Double?
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var activeSessions: Int = 0
    var activeToolCount: Int = 0
}

struct UsageStatsSnapshot: Sendable {
    var summary = UsageSummary()
    /// Last 7 days, oldest first.
    var daily: [UsageBucket] = []
    /// Last 8 weeks, oldest first.
    var weekly: [UsageBucket] = []
    /// Detail table rows for the current week, largest share first.
    var detailRows: [UsageDetailRow] = []

    var detailTotalInput: Int { detailRows.reduce(0) { $0 + $1.input } }
    var detailTotalOutput: Int { detailRows.reduce(0) { $0 + $1.output } }
    var detailTotalCacheWrite: Int { detailRows.reduce(0) { $0 + $1.cacheWrite } }
    var detailTotalCacheRead: Int { detailRows.reduce(0) { $0 + $1.cacheRead } }
    /// Sum of known costs; nil when no row has a cost yet.
    var detailTotalCost: Double? {
        let costs = detailRows.compactMap(\.cost)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }
}

/// Data source for the stats window. The SQLite aggregate store (p-t3qf)
/// plugs in behind this; until it is wired up the window runs on
/// `SampleUsageStatsProvider`.
protocol UsageStatsProviding: Sendable {
    /// True while the data is canned demo data — the window shows a badge.
    var isSampleData: Bool { get }
    func loadSnapshot() async throws -> UsageStatsSnapshot
}

// MARK: - Stacked chart segments

/// One drawable segment of a stacked bar. yStart/yEnd are in token units;
/// a small gap (fraction of the tallest bar) separates segments, matching
/// the mockup's 2px spacing, and only the topmost segment gets the large
/// corner radius.
struct UsageChartSegment: Identifiable, Sendable {
    let bucketLabel: String
    let tool: UsageTool
    let value: Int
    let yStart: Double
    let yEnd: Double
    let isTop: Bool
    let bucketTotal: Int

    var id: String { "\(bucketLabel)|\(tool.rawValue)" }
}

enum UsageChartBuilder {
    /// Gap between stacked segments as a fraction of the tallest bar
    /// (≈2px at the design's ~220px plot height).
    static let gapFraction = 0.009

    static func segments(for buckets: [UsageBucket]) -> [UsageChartSegment] {
        let maxTotal = buckets.map(\.total).max() ?? 0
        guard maxTotal > 0 else { return [] }
        let gap = Double(maxTotal) * gapFraction

        var result: [UsageChartSegment] = []
        for bucket in buckets {
            let tools = UsageTool.allCases.filter { (bucket.values[$0] ?? 0) > 0 }
            var cumulative = 0.0
            for (index, tool) in tools.enumerated() {
                let value = bucket.values[tool] ?? 0
                let yEnd = cumulative + Double(value)
                // Keep a sliver visible even when the value is smaller than the gap.
                var yStart = index == 0 ? cumulative : cumulative + gap
                if yEnd - yStart < gap * 0.75 {
                    yStart = max(cumulative, yEnd - gap * 0.75)
                }
                result.append(UsageChartSegment(
                    bucketLabel: bucket.label,
                    tool: tool,
                    value: value,
                    yStart: yStart,
                    yEnd: yEnd,
                    isTop: index == tools.count - 1,
                    bucketTotal: bucket.total
                ))
                cumulative = yEnd
            }
        }
        return result
    }
}

// MARK: - Sample provider

/// Canned data matching the design mockup, used until the real aggregate
/// store is wired in. Bucket labels are generated from the current date so
/// the window always looks plausible.
struct SampleUsageStatsProvider: UsageStatsProviding {
    var isSampleData: Bool { true }

    func loadSnapshot() async throws -> UsageStatsSnapshot {
        Self.snapshot(now: Date())
    }

    // Values are thousands of tokens (input + output), per the mockup.
    private static let dayRows: [[UsageTool: Int]] = [
        [.claude: 1840, .codex: 620, .gemini: 210, .kimi: 90, .other: 40],
        [.claude: 950, .codex: 300, .gemini: 80, .other: 20],
        [.claude: 2610, .codex: 880, .gemini: 340, .kimi: 120, .other: 60],
        [.claude: 3120, .codex: 1040, .gemini: 280, .kimi: 200, .other: 80],
        [.claude: 2260, .codex: 760, .gemini: 420, .kimi: 60, .other: 30],
        [.claude: 2980, .codex: 1180, .gemini: 190, .kimi: 140, .other: 50],
        [.claude: 1420, .codex: 410, .gemini: 150, .kimi: 30, .other: 20],
    ]

    private static let weekRows: [[UsageTool: Int]] = [
        [.claude: 8200, .codex: 2100, .gemini: 900, .kimi: 300, .other: 150],
        [.claude: 9800, .codex: 2600, .gemini: 700, .kimi: 450, .other: 200],
        [.claude: 7400, .codex: 3100, .gemini: 1200, .kimi: 200, .other: 100],
        [.claude: 11200, .codex: 2900, .gemini: 800, .kimi: 500, .other: 260],
        [.claude: 10100, .codex: 3400, .gemini: 1500, .kimi: 350, .other: 180],
        [.claude: 12600, .codex: 2800, .gemini: 1100, .kimi: 600, .other: 240],
        [.claude: 10900, .codex: 3800, .gemini: 900, .kimi: 400, .other: 210],
        [.claude: 11180, .codex: 5190, .gemini: 1670, .kimi: 640, .other: 300],
    ]

    static func snapshot(now: Date, calendar: Calendar = .current) -> UsageStatsSnapshot {
        var snapshot = UsageStatsSnapshot()
        snapshot.summary = UsageSummary(
            todayTokens: 2_030_000,
            todayDeltaVsYesterday: 0.12,
            equivalentCostToday: 3.87,
            costWeekToDate: 31.20,
            cacheHitRate: 0.914,
            cacheReadTokens: 38_200_000,
            cacheWriteTokens: 3_400_000,
            activeSessions: 14,
            activeToolCount: 4
        )

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MM-dd"
        let weekdaySymbols = dayFormatter.veryShortWeekdaySymbols ?? []

        snapshot.daily = dayRows.enumerated().map { offset, values in
            let date = calendar.date(byAdding: .day, value: offset - (dayRows.count - 1), to: now) ?? now
            let weekday = calendar.component(.weekday, from: date) - 1
            let symbol = weekdaySymbols.indices.contains(weekday) ? " \(weekdaySymbols[weekday])" : ""
            return UsageBucket(
                label: dayFormatter.string(from: date) + symbol,
                values: values.mapValues { $0 * 1000 }
            )
        }

        snapshot.weekly = weekRows.enumerated().map { offset, values in
            let date = calendar.date(byAdding: .weekOfYear, value: offset - (weekRows.count - 1), to: now) ?? now
            return UsageBucket(
                label: dayFormatter.string(from: date),
                values: values.mapValues { $0 * 1000 }
            )
        }

        snapshot.detailRows = [
            UsageDetailRow(
                tool: .claude, toolName: "Claude Code", model: "claude-fable-5",
                input: 1_900_000, output: 8_600_000, cacheWrite: 2_100_000, cacheRead: 26_400_000,
                cost: 21.40, share: 0.68
            ),
            UsageDetailRow(
                tool: .claude, toolName: "Claude Code", model: "claude-haiku-4-5",
                input: 310_000, output: 720_000, cacheWrite: 96_000, cacheRead: 1_800_000,
                cost: 1.10, share: 0.07
            ),
            UsageDetailRow(
                tool: .codex, toolName: "Codex", model: "gpt-5-codex",
                input: 820_000, output: 2_400_000, cacheWrite: 410_000, cacheRead: 6_200_000,
                cost: 5.60, share: 0.19
            ),
            UsageDetailRow(
                tool: .gemini, toolName: "Gemini CLI", model: "gemini-2.5-pro",
                input: 280_000, output: 760_000, cacheWrite: 0, cacheRead: 2_900_000,
                cost: 1.90, share: 0.05
            ),
            UsageDetailRow(
                tool: .kimi, toolName: "Kimi CLI", model: "kimi-k2",
                input: 96_000, output: 210_000, cacheWrite: 0, cacheRead: 870_000,
                cost: 0.60, share: 0.01
            ),
        ]
        return snapshot
    }
}
