import SwiftUI

// MARK: - L1 usage surfaces (design: docs/design/token-usage.md, mockup: token-usage-mockup.html)

/// Collapsed compact-bar badge: 7-day mini bars + today's tokens + equivalent cost.
/// Rendered to the right of the session status; ~90pt wide; hidden until data exists.
@MainActor
struct UsageBadgeView: View {
    var model = UsageStatsModel.shared

    private var snapshot: UsageTodaySnapshot { model.today }

    var body: some View {
        HStack(spacing: 6) {
            UsageSparkBars(values: snapshot.last7DayTokens)

            Text(UsageFormat.compactTokens(snapshot.totalTokens))
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))

            if let cost = snapshot.equivalentCostUSD {
                Text(UsageFormat.equivalentCost(cost))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Last-7-days mini bar chart (3pt bars, 2pt gaps, today highlighted).
private struct UsageSparkBars: View {
    /// Oldest first; last element is today
    let values: [Int]

    private static let todayColor = Color(red: 0.851, green: 0.349, blue: 0.149)  // #d95926
    private static let pastColor = Color(red: 0.247, green: 0.278, blue: 0.337)   // #3f4756

    var body: some View {
        let maxValue = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                let isToday = index == values.count - 1
                RoundedRectangle(cornerRadius: 1)
                    .fill(isToday ? Self.todayColor : Self.pastColor)
                    .frame(width: 3, height: max(2, 14 * CGFloat(value) / CGFloat(maxValue)))
            }
        }
        .frame(height: 14, alignment: .bottom)
    }
}

/// Expanded toolbar entry「今日 token 燃烧 N.NM」— underlined label + bold count.
/// Clicking posts `.openUsageStatsWindow` for the stats window (p-rzqe) to handle.
@MainActor
struct UsageToolbarEntry: View {
    var model = UsageStatsModel.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var hovering = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .openUsageStatsWindow, object: nil)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(l10n["usage_burn_today"])
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.55))
                    .underline(true, color: .white.opacity(hovering ? 0.55 : 0.3))
                Text(UsageFormat.compactTokens(model.today.totalTokens))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(NotchAnimation.micro) { hovering = h } }
    }
}

/// Expanded panel section「今日 Token 用量」— per-tool subtotal bars,
/// footer with cache hit rate and equivalent cost.
@MainActor
struct UsageTodaySection: View {
    var model = UsageStatsModel.shared
    @ObservedObject private var l10n = L10n.shared

    private var snapshot: UsageTodaySnapshot { model.today }

    private static let barBackground = Color(red: 0.137, green: 0.153, blue: 0.184)  // #23272f

    private var todayLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: title + date · scope note
            HStack(alignment: .firstTextBaseline) {
                Text(l10n["usage_today_title"])
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text("\(todayLabel) · \(l10n["usage_excl_cache_reads"])")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.bottom, 6)

            // Per-tool subtotal bars — width is each tool's share of today's total
            let totalTokens = max(snapshot.perTool.map(\.tokens).reduce(0, +), 1)
            ForEach(snapshot.perTool) { usage in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(usageToolColor(usage.tool))
                        .frame(width: 8, height: 8)
                    Text(usageToolDisplayName(usage.tool))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 56, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Self.barBackground)
                            Capsule()
                                .fill(usageToolColor(usage.tool))
                                .frame(width: max(3, geo.size.width * CGFloat(usage.tokens) / CGFloat(totalTokens)))
                        }
                    }
                    .frame(height: 5)
                    Text(UsageFormat.compactTokens(usage.tokens))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 52, alignment: .trailing)
                        .monospacedDigit()
                }
                .padding(.vertical, 3.5)
            }

            // Footer: cache hit rate | equivalent cost
            if snapshot.cacheHitRate != nil || snapshot.equivalentCostUSD != nil {
                HStack {
                    if let hitRate = snapshot.cacheHitRate {
                        Text("\(l10n["usage_cache_hit"]) \(UsageFormat.percent(hitRate))")
                    }
                    Spacer()
                    if let cost = snapshot.equivalentCostUSD {
                        Text("\(UsageFormat.equivalentCost(cost)) \(l10n["usage_equiv_cost"])")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 8)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: 0.5)
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
