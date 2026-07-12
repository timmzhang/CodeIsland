import SwiftUI

// MARK: - L1 Usage Snapshot (contract with the usage data layer)
//
// The SQLite-backed usage store (p-t3qf) pushes a fresh snapshot via
// `UsageStatsModel.shared.update(_:)` whenever today's aggregates change.
// Until that layer lands, the snapshot stays empty and all L1 UI stays hidden.

/// Today's usage figures for the notch L1 surfaces.
/// Token counts follow the agreed scope: input + output only, cache reads excluded.
struct UsageTodaySnapshot: Equatable {
    struct ToolUsage: Equatable, Identifiable {
        /// Session source id, e.g. "claude" / "codex" / "gemini" / "kimi"
        var tool: String
        /// Today's input + output tokens for this tool
        var tokens: Int
        var id: String { tool }
    }

    /// Today's input + output tokens across all tools
    var totalTokens: Int = 0
    /// "Equivalent API cost" in USD — nil until the pricing layer (P2) lands
    var equivalentCostUSD: Double? = nil
    /// Overall cache hit rate today (0…1) — nil when unknown
    var cacheHitRate: Double? = nil
    /// Last 7 days of input + output tokens, oldest first; index 6 is today
    var last7DayTokens: [Int] = Array(repeating: 0, count: 7)
    /// Per-tool subtotals for today, sorted descending by tokens
    var perTool: [ToolUsage] = []

    /// Whether there is anything worth rendering — gates every L1 surface
    var hasData: Bool {
        totalTokens > 0 || last7DayTokens.contains { $0 > 0 }
    }
}

/// Shared observable model the notch views render from.
@MainActor
@Observable
final class UsageStatsModel {
    static let shared = UsageStatsModel()

    private(set) var today = UsageTodaySnapshot()

    func update(_ snapshot: UsageTodaySnapshot) {
        guard snapshot != today else { return }
        today = snapshot
    }
}

extension Notification.Name {
    /// Posted when the user clicks an L1 entry point. The stats window
    /// controller (p-rzqe) observes this and opens the usage report window.
    static let openUsageStatsWindow = Notification.Name("CodeIsland.openUsageStatsWindow")
}

// MARK: - Formatting

enum UsageFormat {
    /// 2034000 → "2.03M", 410000 → "410K", 950 → "950"
    static func compactTokens(_ tokens: Int) -> String {
        let n = Double(tokens)
        switch tokens {
        case 1_000_000...:
            let m = n / 1_000_000
            if m < 10 { return String(format: "%.2fM", m) }
            if m < 100 { return String(format: "%.1fM", m) }
            return String(format: "%.0fM", m)
        case 1_000...:
            return String(format: "%.0fK", n / 1_000)
        default:
            return "\(tokens)"
        }
    }

    /// 3.87 → "≈$3.87"
    static func equivalentCost(_ usd: Double) -> String {
        String(format: "≈$%.2f", usd)
    }

    /// 0.914 → "91.4%"
    static func percent(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }
}

// MARK: - Series colors (from docs/design/token-usage.md)

/// Canonical family for a usage tool identifier. Providers report ids like
/// "claude-code"; prefix matching folds them onto the design's five series.
private func usageToolFamily(_ tool: String) -> String {
    let lowered = tool.lowercased()
    for family in ["claude", "codex", "gemini", "kimi", "qwen", "opencode"] where lowered.hasPrefix(family) {
        return family
    }
    return lowered
}

/// Chart series color per tool — validated for color-blind distinction
/// and contrast on the dark panel background.
func usageToolColor(_ tool: String) -> Color {
    switch usageToolFamily(tool) {
    case "claude": return Color(red: 0.851, green: 0.349, blue: 0.149)  // #d95926
    case "codex":  return Color(red: 0.098, green: 0.620, blue: 0.439)  // #199e70
    case "gemini": return Color(red: 0.224, green: 0.529, blue: 0.898)  // #3987e5
    case "kimi":   return Color(red: 0.788, green: 0.522, blue: 0.000)  // #c98500
    default:       return Color(red: 0.565, green: 0.522, blue: 0.914)  // #9085e9
    }
}

/// Display name for a usage tool identifier in usage lists
func usageToolDisplayName(_ tool: String) -> String {
    switch usageToolFamily(tool) {
    case "claude": return "Claude"
    case "codex": return "Codex"
    case "gemini": return "Gemini"
    case "kimi": return "Kimi"
    case "qwen": return "Qwen"
    case "opencode": return "OpenCode"
    default: return tool.prefix(1).uppercased() + tool.dropFirst()
    }
}
