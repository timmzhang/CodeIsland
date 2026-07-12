import Foundation

/// A single token-usage sample emitted by one AI tool for one assistant turn.
///
/// Providers normalize their native telemetry (Claude Code transcript JSONL,
/// Codex app-server events, …) into this shape before handing it to
/// `UsageStore`. Token counts are per-event deltas, never running totals.
public struct UsageEvent: Equatable, Sendable {
    /// Stable tool identifier, e.g. "claude-code", "codex", "gemini".
    /// Becomes the `tool` dimension of the hourly aggregate rows.
    public let tool: String
    /// Session the event belongs to. Not persisted into aggregate rows;
    /// kept on the event so providers can build dedup keys and callers can
    /// attribute live activity.
    public let sessionId: String
    /// Model identifier as reported by the tool, e.g. "claude-opus-4-8".
    public let model: String
    /// Project the turn ran in — the working directory's absolute path as
    /// reported by the tool (Claude Code transcripts carry it as `cwd`).
    /// Empty when unknown. Kept as a raw path; display folding (basename,
    /// worktree suffixes) is a UI concern.
    public let project: String
    /// Wall-clock time of the assistant turn. Bucketed to the local hour
    /// when aggregated.
    public let timestamp: Date
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64
    /// Idempotency key, e.g. "<messageId>:<requestId>" for Claude Code where
    /// streaming/retry can repeat the same usage payload across JSONL lines.
    /// Events sharing a key are counted at most once across the store's whole
    /// lifetime (survives restarts). `nil` means "no dedup info, always count".
    public let dedupKey: String?
    /// Whether the turn ran inside a subagent/sidechain. Kept as a separate
    /// aggregate dimension so reports can split or merge it as needed.
    public let isSubagent: Bool

    public init(
        tool: String,
        sessionId: String,
        model: String,
        project: String = "",
        timestamp: Date,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheWriteTokens: Int64,
        dedupKey: String? = nil,
        isSubagent: Bool = false
    ) {
        self.tool = tool
        self.sessionId = sessionId
        self.model = model
        self.project = project
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.dedupKey = dedupKey
        self.isSubagent = isSubagent
    }
}

/// Sum of the four token counters over some slice of the aggregate table.
public struct UsageTotals: Equatable, Sendable {
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheWriteTokens: Int64

    /// The main-chart metric: input + output. Cache traffic is reported in
    /// summary cards / detail tables only (design decision #1 — cache reads
    /// are ~10× the volume at ~1/10 the price and would distort the bars).
    public var chartTokens: Int64 { inputTokens + outputTokens }

    public var isZero: Bool {
        inputTokens == 0 && outputTokens == 0 && cacheReadTokens == 0 && cacheWriteTokens == 0
    }

    public static let zero = UsageTotals(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)

    public init(inputTokens: Int64, outputTokens: Int64, cacheReadTokens: Int64, cacheWriteTokens: Int64) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    public static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        UsageTotals(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens
        )
    }
}

/// One day × tool cell of the daily stacked chart. `day` is a local-timezone
/// "yyyy-MM-dd" string.
public struct DailyToolUsage: Equatable, Sendable {
    public let day: String
    public let tool: String
    public let totals: UsageTotals

    public init(day: String, tool: String, totals: UsageTotals) {
        self.day = day
        self.tool = tool
        self.totals = totals
    }
}

/// One tool × model row of the detail table.
public struct ToolModelUsage: Equatable, Sendable {
    public let tool: String
    public let model: String
    public let totals: UsageTotals

    public init(tool: String, model: String, totals: UsageTotals) {
        self.tool = tool
        self.model = model
        self.totals = totals
    }
}

/// One project row of the Top-projects ranking. `project` is the raw working
/// directory path recorded on the events ("" when the tool reported none).
public struct ProjectUsage: Equatable, Sendable {
    public let project: String
    public let totals: UsageTotals

    public init(project: String, totals: UsageTotals) {
        self.project = project
        self.totals = totals
    }
}

/// One hour × tool cell, for the weekly activity heatmap. `dateHour` is a
/// local-timezone "yyyy-MM-dd HH" string matching the aggregate table key.
public struct HourlyToolUsage: Equatable, Sendable {
    public let dateHour: String
    public let tool: String
    public let totals: UsageTotals

    public init(dateHour: String, tool: String, totals: UsageTotals) {
        self.dateHour = dateHour
        self.tool = tool
        self.totals = totals
    }
}

/// Per-tool extension point that turns a tool's native telemetry into
/// `UsageEvent`s. One instance per supported tool (Claude Code, Codex, …);
/// the app owns the instances and funnels every batch into `UsageStore`.
///
/// Implementations decide their own threading; `sink` may be called from any
/// queue and must be treated as escaping for the provider's lifetime.
public protocol UsageProvider: AnyObject {
    /// Stable tool identifier, used as the `tool` dimension in storage.
    var toolName: String { get }

    /// One-shot scan of historical data (e.g. all existing transcript JSONL
    /// files), delivering events in batches via `sink`, then calling
    /// `completion`. Dedup keys make it safe to re-run on every launch —
    /// already-counted events are ignored by the store.
    func backfill(sink: @escaping ([UsageEvent]) -> Void, completion: @escaping () -> Void)

    /// Start streaming incremental events (tailing live files, subscribing to
    /// an event stream, …). Safe to call after `backfill`; providers must not
    /// double-report rows covered by the backfill scan (dedup keys are the
    /// safety net, not the primary mechanism).
    func startTailing(sink: @escaping ([UsageEvent]) -> Void)

    /// Stop streaming. The provider may be restarted with `startTailing`.
    func stopTailing()
}
