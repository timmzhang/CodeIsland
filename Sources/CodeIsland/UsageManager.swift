import Foundation
import os.log
import CodeIslandCore

/// Wires the usage data layer into the running app: owns the SQLite
/// `UsageStore` and one `UsageProvider` per supported tool, runs the
/// launch-time backfill, funnels live tail events into the store, and pushes
/// today's aggregates to `UsageStatsModel` for the notch L1 surfaces.
///
/// All bookkeeping runs on an internal utility queue; only the final snapshot
/// push hops to the main actor. The stats window (p-rzqe) plugs in behind
/// `UsageStatsProviding` once its branch lands — the store queries it needs
/// are already served by `UsageStore`.
final class UsageManager: @unchecked Sendable {
    static let shared = UsageManager()

    private static let log = Logger(subsystem: "com.codeisland", category: "UsageManager")

    private let queue = DispatchQueue(label: "com.codeisland.usage-manager", qos: .utility)
    private let claudeProvider = ClaudeUsageProvider()
    private let codexProvider = CodexUsageProvider()
    private var store: UsageStore?
    private var started = false
    private var refreshPending = false
    private var rolloverTimer: DispatchSourceTimer?

    /// Coalesces snapshot recomputes so per-file backfill batches don't
    /// recompute hundreds of times; the trailing refresh after this delay
    /// picks up whatever arrived in between.
    private let refreshDelay: TimeInterval = 1.0

    func start(storePath: String = UsageStore.defaultPath) {
        queue.async { [self] in
            guard !started else { return }
            started = true
            do {
                store = try UsageStore(path: storePath)
            } catch {
                Self.log.error("Cannot open usage store: \(String(describing: error))")
                return
            }

            // Show whatever earlier runs persisted before the rescan finishes.
            pushSnapshot()

            let sink: ([UsageEvent]) -> Void = { [weak self] events in
                guard let self else { return }
                self.queue.async { self.recordEvents(events) }
            }
            // Tail before backfilling so no live event can fall in between;
            // overlap is harmless (dedup keys).
            claudeProvider.startTailing(sink: sink)
            codexProvider.startTailing(sink: sink)
            let backfillDone: () -> Void = { [weak self] in
                guard let self else { return }
                self.queue.async { self.pushSnapshot() }
            }
            claudeProvider.backfill(sink: sink, completion: backfillDone)
            codexProvider.backfill(sink: sink, completion: backfillDone)
            startRolloverTimer()
        }
    }

    func stop() {
        queue.async { [self] in
            claudeProvider.stopTailing()
            codexProvider.stopTailing()
            rolloverTimer?.cancel()
            rolloverTimer = nil
        }
    }

    /// Entry point for usage rows discovered by the app's live transcript
    /// tailer (see `AppState.applyTranscriptDelta`).
    func ingestClaude(_ events: [ClaudeUsageEvent]) {
        claudeProvider.ingest(events)
    }

    /// Entry points for Codex app-server notifications
    /// (see `AppState.handleCodexAppServerMessage`).
    func ingestCodexTokenUsage(params: [String: AnyCodableLike]) {
        codexProvider.ingestTokenUsage(params: params)
    }

    func noteCodexThreadSettings(params: [String: AnyCodableLike]) {
        codexProvider.noteThreadSettings(params: params)
    }

    /// Store handle for ad-hoc readers (the stats window provider). Nil
    /// briefly until `start()` finishes opening the database, or for good
    /// when opening failed.
    func currentStore() -> UsageStore? {
        queue.sync { store }
    }

    // MARK: - Store + snapshot (on `queue`)

    private func recordEvents(_ events: [UsageEvent]) {
        guard let store else { return }
        do {
            guard try store.record(events) > 0 else { return }
        } catch {
            Self.log.error("Failed to record usage events: \(String(describing: error))")
            return
        }
        scheduleSnapshotRefresh()
    }

    private func scheduleSnapshotRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        queue.asyncAfter(deadline: .now() + refreshDelay) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.pushSnapshot()
        }
    }

    /// Keeps "today" honest across midnight even when no events arrive;
    /// `UsageStatsModel.update` drops unchanged snapshots, so the steady-state
    /// tick is three cheap SQL sums and no UI work.
    private func startRolloverTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.pushSnapshot() }
        timer.resume()
        rolloverTimer = timer
    }

    private func pushSnapshot() {
        guard let store else { return }
        let now = Date()
        do {
            let rows = try store.totalsByDayAndTool(in: UsageStore.trailingDaysInterval(days: 7, endingAt: now))
            var snapshot = Self.todaySnapshot(from: rows, dayKeys: Self.trailingDayKeys(days: 7, endingAt: now))
            // Equivalent API cost for the badge, per tool × model row so each
            // model bills at its own price; nil when today's usage is all
            // unpriced (the badge omits the cost segment).
            let todayCost = UsagePriceTable.fromSettings()
                .cost(of: try store.totalsByToolAndModel(in: UsageStore.dayInterval(containing: now)))
            if todayCost.usd > 0 || todayCost.unpricedChartTokens == 0 {
                snapshot.equivalentCostUSD = todayCost.usd
            }
            Task { @MainActor in
                UsageStatsModel.shared.update(snapshot)
            }
        } catch {
            Self.log.error("Failed to query usage snapshot: \(String(describing: error))")
        }
    }

    // MARK: - Snapshot assembly (pure, unit-tested)

    /// Local-timezone "yyyy-MM-dd" keys for the trailing `days` days ending
    /// with (and including) `date`, oldest first — matches the `day` strings
    /// produced by `UsageStore.totalsByDayAndTool`.
    static func trailingDayKeys(
        days: Int,
        endingAt date: Date = Date(),
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return (0..<days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: date).map(formatter.string(from:))
        }
    }

    /// Folds day × tool aggregate rows into the L1 snapshot. `dayKeys` are
    /// oldest-first and the last entry is "today"; rows outside `dayKeys`
    /// are ignored. Cache hit rate is reads / (reads + uncached input).
    static func todaySnapshot(from rows: [DailyToolUsage], dayKeys: [String]) -> UsageTodaySnapshot {
        var snapshot = UsageTodaySnapshot()
        guard let todayKey = dayKeys.last else { return snapshot }

        var last7 = Array(repeating: 0, count: dayKeys.count)
        var todayTotals = UsageTotals.zero
        var perTool: [String: Int] = [:]
        for row in rows {
            if let index = dayKeys.firstIndex(of: row.day) {
                last7[index] += Int(row.totals.chartTokens)
            }
            if row.day == todayKey {
                todayTotals = todayTotals + row.totals
                perTool[row.tool, default: 0] += Int(row.totals.chartTokens)
            }
        }

        snapshot.totalTokens = Int(todayTotals.chartTokens)
        snapshot.last7DayTokens = last7
        let cacheDenominator = todayTotals.cacheReadTokens + todayTotals.inputTokens
        if cacheDenominator > 0 {
            snapshot.cacheHitRate = Double(todayTotals.cacheReadTokens) / Double(cacheDenominator)
        }
        snapshot.perTool = perTool
            .filter { $0.value > 0 }
            .map { UsageTodaySnapshot.ToolUsage(tool: $0.key, tokens: $0.value) }
            .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.tool < $1.tool }
        return snapshot
    }
}
