import Foundation
import CodeIslandCore

/// `UsageStatsProviding` backed by the app's SQLite aggregate store (owned
/// by `UsageManager`). Every number is derived from the hourly rows except
/// the active-session count, which the app delegate injects from `AppState`.
struct UsageStoreStatsProvider: UsageStatsProviding {
    var isSampleData: Bool { false }

    /// Fetches the number of currently tracked sessions on the main actor.
    let activeSessionCount: @Sendable () async -> Int

    func loadSnapshot() async throws -> UsageStatsSnapshot {
        guard let store = UsageManager.shared.currentStore() else {
            return UsageStatsSnapshot()
        }
        let sessions = await activeSessionCount()
        let now = Date()
        let priceTable = UsagePriceTable.fromSettings()
        // Store queries serialize on the store's internal queue — keep the
        // wait off the main actor.
        return try await Task.detached(priority: .userInitiated) {
            try Self.snapshot(store: store, now: now, activeSessions: sessions, priceTable: priceTable)
        }.value
    }

    // MARK: - Assembly (pure given a store; unit-tested)

    static func snapshot(
        store: UsageStore,
        now: Date,
        activeSessions: Int,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current,
        priceTable: UsagePriceTable = UsagePriceTable()
    ) throws -> UsageStatsSnapshot {
        let dayKeyFormatter = DateFormatter()
        dayKeyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayKeyFormatter.timeZone = timeZone
        dayKeyFormatter.dateFormat = "yyyy-MM-dd"

        let labelFormatter = DateFormatter()
        labelFormatter.timeZone = timeZone
        labelFormatter.dateFormat = "MM-dd"
        let weekdaySymbols = labelFormatter.veryShortWeekdaySymbols ?? []

        var snapshot = UsageStatsSnapshot()

        // Summary tiles ---------------------------------------------------
        let todayTotals = try store.totals(in: UsageStore.dayInterval(containing: now, calendar: calendar))
        var summary = UsageSummary()
        summary.todayTokens = Int(todayTotals.chartTokens)
        summary.cacheReadTokens = Int(todayTotals.cacheReadTokens)
        summary.cacheWriteTokens = Int(todayTotals.cacheWriteTokens)
        let cacheDenominator = todayTotals.cacheReadTokens + todayTotals.inputTokens
        if cacheDenominator > 0 {
            summary.cacheHitRate = Double(todayTotals.cacheReadTokens) / Double(cacheDenominator)
        }
        // vs the same time yesterday, at the store's hour-bucket granularity
        if let yesterdayNow = calendar.date(byAdding: .day, value: -1, to: now) {
            let yesterdayStart = UsageStore.dayInterval(containing: yesterdayNow, calendar: calendar).start
            if yesterdayNow > yesterdayStart {
                let yesterdayTotals = try store.totals(in: DateInterval(start: yesterdayStart, end: yesterdayNow))
                if yesterdayTotals.chartTokens > 0 {
                    summary.todayDeltaVsYesterday =
                        Double(todayTotals.chartTokens - yesterdayTotals.chartTokens)
                        / Double(yesterdayTotals.chartTokens)
                }
            }
        }
        // Equivalent API cost (design decision #2): computed per tool × model
        // row so each model bills at its own price. Nil when everything that
        // ran today is unpriced — the tile shows "—" instead of a false $0.
        let todayInterval = UsageStore.dayInterval(containing: now, calendar: calendar)
        summary.equivalentCostToday = displayCost(
            priceTable.cost(of: try store.totalsByToolAndModel(in: todayInterval))
        )
        summary.activeSessions = activeSessions

        // Daily buckets (last 7 days) --------------------------------------
        let dailyRows = try store.totalsByDayAndTool(
            in: UsageStore.trailingDaysInterval(days: 7, endingAt: now, calendar: calendar)
        )
        var dayMeta: [(key: String, label: String)] = []
        for offset in (0..<7).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let weekday = calendar.component(.weekday, from: date) - 1
            let symbol = weekdaySymbols.indices.contains(weekday) ? " \(weekdaySymbols[weekday])" : ""
            dayMeta.append((dayKeyFormatter.string(from: date), labelFormatter.string(from: date) + symbol))
        }
        var dailyValues = Array(repeating: [UsageTool: Int](), count: dayMeta.count)
        let todayKey = dayMeta.last?.key
        var todayTools: Set<UsageTool> = []
        for row in dailyRows {
            guard let index = dayMeta.firstIndex(where: { $0.key == row.day }) else { continue }
            let tool = UsageTool(toolIdentifier: row.tool)
            dailyValues[index][tool, default: 0] += Int(row.totals.chartTokens)
            if row.day == todayKey, row.totals.chartTokens > 0 {
                todayTools.insert(tool)
            }
        }
        snapshot.daily = zip(dayMeta, dailyValues).map { meta, values in
            UsageBucket(label: meta.label, values: values)
        }
        summary.activeToolCount = todayTools.count
        snapshot.summary = summary

        // Weekly buckets (last 8 weeks) -------------------------------------
        if let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now) {
            var weeks: [DateInterval] = []
            for offset in (0..<8).reversed() {
                if let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: currentWeek.start),
                   let interval = calendar.dateInterval(of: .weekOfYear, for: start) {
                    weeks.append(interval)
                }
            }
            if let first = weeks.first {
                let weeklyRows = try store.totalsByDayAndTool(
                    in: DateInterval(start: first.start, end: currentWeek.end)
                )
                var weeklyValues = Array(repeating: [UsageTool: Int](), count: weeks.count)
                for row in weeklyRows {
                    // Half-open week membership: DateInterval.contains includes
                    // the end instant, which would put a week-start day (00:00
                    // == previous week's end) into the previous bucket.
                    guard let date = dayKeyFormatter.date(from: row.day),
                          let index = weeks.firstIndex(where: { date >= $0.start && date < $0.end }) else { continue }
                    weeklyValues[index][UsageTool(toolIdentifier: row.tool), default: 0]
                        += Int(row.totals.chartTokens)
                }
                snapshot.weekly = zip(weeks, weeklyValues).map { week, values in
                    UsageBucket(label: labelFormatter.string(from: week.start), values: values)
                }
            }

            // Detail table (current week to date) --------------------------
            // Raw tool ids folding onto the same series (e.g. "claude-code"
            // and a future "claude-desktop") merge into one row so the row
            // ids (tool|model) stay unique.
            var detailKeys: [String] = []
            var detailTotals: [String: (tool: UsageTool, model: String, totals: UsageTotals)] = [:]
            let weekRows = try store.totalsByToolAndModel(in: currentWeek)
            snapshot.summary.costWeekToDate = displayCost(priceTable.cost(of: weekRows))
            for row in weekRows {
                let tool = UsageTool(toolIdentifier: row.tool)
                let key = "\(tool.rawValue)|\(row.model)"
                if var existing = detailTotals[key] {
                    existing.totals = existing.totals + row.totals
                    detailTotals[key] = existing
                } else {
                    detailKeys.append(key)
                    detailTotals[key] = (tool, row.model, row.totals)
                }
            }
            let weekChartTotal = detailTotals.values.reduce(Int64(0)) { $0 + $1.totals.chartTokens }
            snapshot.detailRows = detailKeys
                .compactMap { detailTotals[$0] }
                .map { entry in
                    UsageDetailRow(
                        tool: entry.tool,
                        toolName: entry.tool.displayName,
                        model: entry.model,
                        input: Int(entry.totals.inputTokens),
                        output: Int(entry.totals.outputTokens),
                        cacheWrite: Int(entry.totals.cacheWriteTokens),
                        cacheRead: Int(entry.totals.cacheReadTokens),
                        cost: priceTable.cost(of: entry.totals, model: entry.model),
                        share: weekChartTotal > 0
                            ? Double(entry.totals.chartTokens) / Double(weekChartTotal)
                            : 0
                    )
                }
                .sorted { ($0.input + $0.output) > ($1.input + $1.output) }

            // Top rankings (current week to date) ---------------------------
            snapshot.topProjects = UsageRankingBuilder.projectRows(
                try store.totalsByProject(in: currentWeek).map {
                    (project: $0.project, tokens: Int($0.totals.chartTokens))
                }
            )
            snapshot.topTools = UsageRankingBuilder.toolRows(fromDetail: snapshot.detailRows)
        }

        return snapshot
    }

    /// Cost for display: nil (rendered "—") when the only usage is unpriced,
    /// so an unknown model reads as "unknown" rather than a false $0.
    private static func displayCost(_ cost: UsageCost) -> Double? {
        cost.usd > 0 || cost.unpricedChartTokens == 0 ? cost.usd : nil
    }
}
