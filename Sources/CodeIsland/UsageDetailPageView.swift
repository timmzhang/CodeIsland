import SwiftUI
import CodeIslandCore

// MARK: - In-panel usage detail page (design: p-cfj6 mockup ③)
//
// Reached from the toolbar entry / hover popover. Three today-cards on top,
// an N-day trend bar chart in the middle, and today's per-session (worktree)
// distribution at the bottom — the most actionable block: it shows which
// working session is burning the tokens.

/// Queries the aggregate store for the two blocks the L1 snapshot doesn't
/// carry: the N-day trend and today's per-project distribution.
@MainActor
@Observable
final class UsageDetailPageModel {
    struct TrendDay: Identifiable, Equatable {
        /// "yyyy-MM-dd" local day key
        let dayKey: String
        /// Day-of-month label, e.g. "07"; the view swaps today's for「今日」
        let label: String
        let tokens: Int
        let isToday: Bool
        var id: String { dayKey }
    }

    struct SessionRow: Identifiable, Equatable {
        let name: String
        let tokens: Int
        /// Bar width relative to the largest row, 0…1
        let fraction: Double
        var id: String { name }
    }

    private(set) var trend: [TrendDay] = []
    private(set) var sessions: [SessionRow] = []

    /// Preview/snapshot seeding — bypasses the store. `reload` keeps seeded
    /// data when the store isn't running (tests never start UsageManager).
    func seed(trend: [TrendDay], sessions: [SessionRow]) {
        self.trend = trend
        self.sessions = sessions
    }

    func reload(days: Int) async {
        guard let store = UsageManager.shared.currentStore() else { return }
        let now = Date()
        // Store queries serialize on the store's internal queue — keep the
        // wait off the main actor (same pattern as UsageStoreStatsProvider).
        let result = await Task.detached(priority: .userInitiated) { () -> ([DailyToolUsage], [ProjectUsage])? in
            guard
                let daily = try? store.totalsByDayAndTool(
                    in: UsageStore.trailingDaysInterval(days: days, endingAt: now)),
                let projects = try? store.totalsByProject(
                    in: UsageStore.dayInterval(containing: now))
            else { return nil }
            return (daily, projects)
        }.value
        guard let (daily, projects) = result else { return }
        trend = Self.trendDays(from: daily, dayKeys: UsageManager.trailingDayKeys(days: days, endingAt: now))
        sessions = Self.sessionRows(from: projects.map {
            (project: $0.project, tokens: Int($0.totals.chartTokens))
        })
    }

    // MARK: - Assembly (pure, unit-tested)

    /// Collapses day × tool rows onto per-day chart-token totals, zero-filled
    /// over `dayKeys` (oldest first; the last key is today).
    static func trendDays(from rows: [DailyToolUsage], dayKeys: [String]) -> [TrendDay] {
        var totals: [String: Int] = [:]
        for row in rows { totals[row.day, default: 0] += Int(row.totals.chartTokens) }
        return dayKeys.enumerated().map { index, key in
            TrendDay(
                dayKey: key,
                label: String(key.suffix(2)),
                tokens: totals[key] ?? 0,
                isToday: index == dayKeys.count - 1
            )
        }
    }

    /// Rows shown individually before the tail folds into "others".
    static let maxSessionRows = 8

    /// Ranks today's per-project rows. Unlike the weekly Top-projects ranking,
    /// worktree suffixes are NOT folded away ("pins_p-pgy1" stays distinct
    /// from "pins") — each task worktree ≈ one working session, which is the
    /// whole point of this block.
    static func sessionRows(from projects: [(project: String, tokens: Int)]) -> [SessionRow] {
        var byName: [String: Int] = [:]
        for (project, tokens) in projects where tokens > 0 {
            let name = project.isEmpty
                ? L10n.shared["usage_project_unknown"]
                : (project as NSString).lastPathComponent
            byName[name, default: 0] += tokens
        }
        var entries = byName
            .map { (name: $0.key, tokens: $0.value) }
            .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.name < $1.name }
        // Folding a single row into "others" would just rename it — only fold 2+.
        if entries.count > maxSessionRows + 1 {
            let tail = entries[maxSessionRows...]
            entries = Array(entries[..<maxSessionRows])
            entries.append((
                name: String(format: L10n.shared["usage_rank_others"], tail.count),
                tokens: tail.reduce(0) { $0 + $1.tokens }
            ))
        }
        let maxTokens = max(entries.map(\.tokens).max() ?? 0, 1)
        return entries.map {
            SessionRow(name: $0.name, tokens: $0.tokens, fraction: Double($0.tokens) / Double(maxTokens))
        }
    }
}

// MARK: - View

@MainActor
struct UsageDetailView: View {
    var appState: AppState
    var model = UsageStatsModel.shared
    @State private var page: UsageDetailPageModel
    @State private var rangeDays = 7

    init(appState: AppState, page: UsageDetailPageModel? = nil) {
        self.appState = appState
        _page = State(initialValue: page ?? UsageDetailPageModel())
    }
    @State private var backHovered = false
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.maxVisibleSessions) private var maxVisibleSessions = SettingsDefaults.maxVisibleSessions

    private static let cardBackground = Color.white.opacity(0.05)
    private static let cardStroke = Color.white.opacity(0.07)
    private static let cacheValue = Color(usageHex: 0x7EE0B8)
    private static let pastBar = Color(usageHex: 0x5C3423)
    private static let barTrack = Color(usageHex: 0x23272F)
    private static let plotHeight: CGFloat = 96

    var body: some View {
        VStack(spacing: 10) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    statCards
                    trendCard
                    if !page.sessions.isEmpty { sessionsCard }
                }
            }
            .frame(maxHeight: CGFloat(maxVisibleSessions) * 90 + 30)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .task(id: rangeDays) { await page.reload(days: rangeDays) }
    }

    // MARK: Header — back + title + range menu

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(NotchAnimation.close) { appState.surface = .sessionList }
            } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(backHovered ? 0.95 : 0.6))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(backHovered ? 0.1 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(NotchAnimation.micro) { backHovered = h } }

            Text(l10n["usage_detail_title"])
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))

            Spacer()

            Menu {
                ForEach([7, 14, 30], id: \.self) { days in
                    Button {
                        rangeDays = days
                    } label: {
                        if days == rangeDays {
                            Label(rangeLabel(days), systemImage: "checkmark")
                        } else {
                            Text(rangeLabel(days))
                        }
                    }
                }
                Divider()
                Button(l10n["usage_full_report"]) {
                    NotificationCenter.default.post(name: .openUsageStatsWindow, object: nil)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(rangeLabel(rangeDays))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func rangeLabel(_ days: Int) -> String {
        String(format: l10n["usage_range_days"], days)
    }

    // MARK: Stat cards — today / cache hit / equivalent cost

    private var statCards: some View {
        HStack(spacing: 8) {
            statCard(
                label: l10n["usage_today"],
                value: UsageFormat.compactTokens(model.today.totalTokens),
                color: .white.opacity(0.95)
            )
            statCard(
                label: l10n["usage_cache_hit"],
                value: model.today.cacheHitRate.map(UsageFormat.percentWhole) ?? "—",
                color: Self.cacheValue
            )
            statCard(
                label: l10n["usage_equiv_cost"],
                value: model.today.equivalentCostUSD.map(UsageFormat.equivalentCost) ?? "—",
                color: .white.opacity(0.95)
            )
        }
    }

    private func statCard(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Self.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Self.cardStroke, lineWidth: 1))
    }

    // MARK: Trend — N-day bars, today highlighted

    private var trendCard: some View {
        let days = page.trend
        let maxTokens = max(days.map(\.tokens).max() ?? 0, 1)
        // Thin out x-axis labels when bars get dense (14 → every 2nd, 30 → every 5th)
        let labelStride = max(1, Int((Double(days.count) / 7.0).rounded(.up)))
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(format: l10n["usage_trend_days"], rangeDays))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))

            HStack(alignment: .bottom, spacing: days.count > 14 ? 3 : 6) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    let showLabel = day.isToday || index % labelStride == 0
                    VStack(spacing: 4) {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 3, bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0, topTrailingRadius: 3
                        )
                        .fill(day.isToday ? UsageTool.claude.color : Self.pastBar)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, Self.plotHeight * CGFloat(day.tokens) / CGFloat(maxTokens)))
                        Text(day.isToday ? l10n["usage_today"] : day.label)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(day.isToday ? UsageTool.claude.color : .white.opacity(0.35))
                            .lineLimit(1)
                            .fixedSize()
                            .opacity(showLabel ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Self.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Self.cardStroke, lineWidth: 1))
    }

    // MARK: Today by session (worktree) distribution

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n["usage_by_session_today"])
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))

            ForEach(page.sessions) { row in
                HStack(spacing: 9) {
                    Text(row.name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 132, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Self.barTrack)
                            Capsule()
                                .fill(UsageTool.claude.color)
                                .frame(width: max(3, geo.size.width * row.fraction))
                        }
                    }
                    .frame(height: 5)
                    Text(UsageFormat.compactTokens(row.tokens))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 52, alignment: .trailing)
                        .monospacedDigit()
                }
                .frame(height: 18)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Self.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Self.cardStroke, lineWidth: 1))
    }
}
