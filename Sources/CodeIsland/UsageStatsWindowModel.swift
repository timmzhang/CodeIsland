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

    /// Linear-interpolates between two `usageHex` colors — the heatmap's
    /// continuous blue ramp. (`Color.mix` needs macOS 15+; this target is 14.)
    static func usageRamp(_ low: UInt32, _ high: UInt32, _ t: Double) -> Color {
        let t = min(1, max(0, t))
        func channel(_ shift: UInt32) -> Double {
            let lo = Double((low >> shift) & 0xFF)
            let hi = Double((high >> shift) & 0xFF)
            return lo + (hi - lo) * t
        }
        return Color(.sRGB, red: channel(16) / 255, green: channel(8) / 255, blue: channel(0) / 255, opacity: 1)
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

/// One row of a Top ranking card (Top projects / Top tools): name, horizontal
/// bar, and a value column. Rows are pre-ranked; the last row may be an
/// aggregate ("others").
struct UsageRankRow: Identifiable, Sendable {
    let name: String
    /// input + output tokens behind this row.
    let tokens: Int
    /// Bar width relative to the largest row, 0...1.
    let fraction: Double
    /// This row's share of the whole ranking, 0...1.
    let share: Double
    let color: Color

    var id: String { name }
}

struct UsageStatsSnapshot: Sendable {
    var summary = UsageSummary()
    /// Last 7 days, oldest first.
    var daily: [UsageBucket] = []
    /// Last 8 weeks, oldest first.
    var weekly: [UsageBucket] = []
    /// Detail table rows for the current week, largest share first.
    var detailRows: [UsageDetailRow] = []
    /// Top-projects ranking for the current week; empty hides the card.
    var topProjects: [UsageRankRow] = []
    /// Top-tools ranking for the current week; empty hides the card.
    var topTools: [UsageRankRow] = []
    /// L3 weekly-insight numbers (hero total/delta/avg/peak + activity heatmap).
    var weeklyInsight = UsageWeeklyInsight()

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

// MARK: - Top rankings

enum UsageRankingBuilder {
    /// Rows shown individually before everything else folds into "others".
    static let topCount = 3
    /// Neutral bar color for the aggregate row (mockup's #3F4756).
    static let othersColor = Color(usageHex: 0x3F4756)

    /// Display name for a raw project path: last path component, with the
    /// auto-worktree suffix ("CodeIsland_p-kstm" → "CodeIsland") folded away
    /// so a task worktree ranks together with its main checkout.
    static func projectDisplayName(_ rawPath: String) -> String {
        let base = (rawPath as NSString).lastPathComponent
        guard !base.isEmpty else { return rawPath }
        if let range = base.range(of: #"_p-[a-z0-9]{4,}$"#, options: .regularExpression) {
            let folded = String(base[..<range.lowerBound])
            if !folded.isEmpty { return folded }
        }
        return base
    }

    /// Fold raw `(project path, tokens)` pairs onto display names and rank
    /// them. Empty paths (rows that predate attribution, or tools that don't
    /// report one) surface as the localized "unattributed" bucket.
    static func projectRows(_ projects: [(project: String, tokens: Int)]) -> [UsageRankRow] {
        var byName: [String: Int] = [:]
        for (project, tokens) in projects where tokens > 0 {
            let name = project.isEmpty ? L10n.shared["usage_project_unknown"] : projectDisplayName(project)
            byName[name, default: 0] += tokens
        }
        let entries = byName.map { (name: $0.key, tokens: $0.value, color: UsageTool.claude.color) }
        return rank(entries)
    }

    /// Tool ranking derived from the detail table rows (tokens = input+output
    /// per tool), so providers don't need a separate query.
    static func toolRows(fromDetail rows: [UsageDetailRow]) -> [UsageRankRow] {
        var byTool: [UsageTool: (name: String, tokens: Int)] = [:]
        for row in rows {
            let tokens = row.input + row.output
            guard tokens > 0 else { continue }
            var entry = byTool[row.tool] ?? (row.toolName, 0)
            entry.tokens += tokens
            byTool[row.tool] = entry
        }
        let entries = byTool.map { (name: $0.value.name, tokens: $0.value.tokens, color: $0.key.color) }
        return rank(entries)
    }

    /// Sort descending, keep the top rows, fold the tail into one aggregate
    /// row. Bar widths are relative to the largest row.
    static func rank(_ entries: [(name: String, tokens: Int, color: Color)]) -> [UsageRankRow] {
        let sorted = entries.filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }
        guard !sorted.isEmpty else { return [] }
        let grandTotal = sorted.reduce(0) { $0 + $1.tokens }

        var rows = sorted
        var aggregate: (name: String, tokens: Int, color: Color)?
        // Folding a single row into "others" would just rename it — only fold 2+.
        if sorted.count > topCount + 1 {
            let tail = sorted[topCount...]
            aggregate = (
                String(format: L10n.shared["usage_rank_others"], tail.count),
                tail.reduce(0) { $0 + $1.tokens },
                othersColor
            )
            rows = Array(sorted[..<topCount])
        }
        if let aggregate { rows.append(aggregate) }

        let maxTokens = rows.map(\.tokens).max() ?? 1
        return rows.map { entry in
            UsageRankRow(
                name: entry.name,
                tokens: entry.tokens,
                fraction: Double(entry.tokens) / Double(maxTokens),
                share: grandTotal > 0 ? Double(entry.tokens) / Double(grandTotal) : 0,
                color: entry.color
            )
        }
    }
}

// MARK: - Weekly insight (L3 tab)

/// One 2-hour activity-heatmap cell: local weekday (Monday=0…Sunday=6) ×
/// hour-of-day bucket (0…11, each spanning 2 hours from `hourBucket*2`).
/// `intensity` is this cell's tokens relative to the grid's busiest cell —
/// the view interpolates the design's blue monochrome ramp from it.
struct UsageHeatmapCell: Identifiable, Sendable {
    let weekday: Int
    let hourBucket: Int
    let tokens: Int
    let intensity: Double

    var id: String { "\(weekday)-\(hourBucket)" }
}

/// L3 "weekly insight" numbers: current-week total + delta vs last week,
/// daily average and peak, and the activity heatmap. Top projects/tools
/// reuse `UsageStatsSnapshot.topProjects`/`topTools`, which are already
/// current-week scoped.
struct UsageWeeklyInsight: Sendable {
    var weekTokens: Int = 0
    var weekCost: Double?
    /// Fractional change vs the same elapsed portion of last week (0.23 = +23%); nil hides the delta line.
    var deltaVsLastWeek: Double?
    var dailyAverageTokens: Int = 0
    var peakDayLabel: String = ""
    var peakDayTokens: Int = 0
    /// e.g. "07-06 → 07-12".
    var rangeLabel: String = ""
    /// Always 84 cells (7×12), zero-filled where there's no data.
    var heatmap: [UsageHeatmapCell] = []

    var hasData: Bool { weekTokens > 0 }
}

/// Builds the L3 "copy as text" weekly-report blurb. Pure and testable —
/// the view only owns handing the result to the pasteboard.
enum UsageInsightText {
    static func build(snapshot: UsageStatsSnapshot, l10n: L10n) -> String {
        let insight = snapshot.weeklyInsight
        var lines: [String] = []

        let tokens = UsageFormat.compactTokens(insight.weekTokens)
        if let cost = insight.weekCost {
            lines.append(String(format: l10n["usage_insight_copy_line1"], tokens, UsageFormat.equivalentCost(cost)))
        } else {
            lines.append(String(format: l10n["usage_insight_copy_line1_no_cost"], tokens))
        }

        if let delta = insight.deltaVsLastWeek {
            let up = delta >= 0
            let pct = "\(up ? "▲" : "▼") \(Int((abs(delta) * 100).rounded()))%"
            lines.append(String(format: l10n["usage_insight_copy_delta"], pct))
        }

        if insight.dailyAverageTokens > 0 {
            lines.append(String(
                format: l10n["usage_insight_daily_avg_peak"],
                UsageFormat.compactTokens(insight.dailyAverageTokens),
                insight.peakDayLabel,
                UsageFormat.compactTokens(insight.peakDayTokens)
            ))
        }

        let sep = l10n["usage_insight_list_sep"]
        if !snapshot.topProjects.isEmpty {
            let joined = snapshot.topProjects
                .map { "\($0.name) \(UsageFormat.compactTokens($0.tokens))" }
                .joined(separator: sep)
            lines.append(String(format: l10n["usage_insight_copy_projects"], joined))
        }
        if !snapshot.topTools.isEmpty {
            let joined = snapshot.topTools
                .map { "\($0.name) \(UsageFormat.percentWhole($0.share))" }
                .joined(separator: sep)
            lines.append(String(format: l10n["usage_insight_copy_tools"], joined))
        }

        return lines.joined(separator: "\n")
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

        snapshot.topProjects = UsageRankingBuilder.projectRows([
            ("/Users/me/Workspace/CodeIsland", 6_200_000),
            ("/Users/me/Workspace/CodeIsland_p-kstm", 1_100_000),
            ("/Users/me/.agents/skills/pins", 3_800_000),
            ("/Users/me/Workspace/LarkMail", 2_400_000),
            ("/Users/me/Workspace/blog", 900_000),
            ("/Users/me/Workspace/dotfiles", 500_000),
            ("", 300_000),
        ])
        snapshot.topTools = UsageRankingBuilder.toolRows(fromDetail: snapshot.detailRows)

        snapshot.weeklyInsight = UsageWeeklyInsight(
            weekTokens: 16_100_000,
            weekCost: 30.60,
            deltaVsLastWeek: 0.23,
            dailyAverageTokens: 2_300_000,
            peakDayLabel: weekdaySymbols.indices.contains(2) ? weekdaySymbols[2] : "二",
            peakDayTokens: 4_700_000,
            rangeLabel: "\(dayFormatter.string(from: calendar.date(byAdding: .day, value: -6, to: now) ?? now)) → \(dayFormatter.string(from: now))",
            heatmap: Self.heatCells
        )
        return snapshot
    }

    // Matches docs/design/token-usage-mockup.html's HEAT grid (values 0…4,
    // Monday-first rows, 12 two-hour buckets); intensity is value / 4.
    private static let heatValues: [[Int]] = [
        [0,0,0,0,1,2,3,3,2,3,4,2],
        [0,0,0,0,2,3,4,4,3,4,4,3],
        [0,0,0,0,1,3,3,2,3,3,3,1],
        [1,0,0,0,2,3,4,3,2,4,3,2],
        [0,0,0,0,1,2,3,3,2,3,4,3],
        [0,0,0,1,1,2,2,3,2,2,3,2],
        [0,0,0,0,0,1,1,2,1,2,2,1],
    ]

    private static var heatCells: [UsageHeatmapCell] {
        heatValues.enumerated().flatMap { weekday, row in
            row.enumerated().map { hourBucket, value in
                UsageHeatmapCell(weekday: weekday, hourBucket: hourBucket, tokens: value * 250_000, intensity: Double(value) / 4.0)
            }
        }
    }
}
