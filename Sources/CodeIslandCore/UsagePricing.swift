import Foundation

/// Per-million-token USD prices for one model.
///
/// "Equivalent API cost" (design decision #2): what the same usage would cost
/// on the vendor's pay-as-you-go API. Subscription users don't actually pay
/// this — every cost surface must carry the footnote saying so.
public struct ModelPrice: Equatable, Sendable, Codable {
    /// $/MTok for uncached input tokens.
    public var input: Double
    /// $/MTok for output tokens.
    public var output: Double
    /// $/MTok for cache-write (cache creation) tokens.
    public var cacheWrite: Double
    /// $/MTok for cache-read (cache hit) tokens.
    public var cacheRead: Double

    public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    /// Anthropic's standard cache multipliers: write 1.25× input (5m TTL),
    /// read 0.1× input.
    static func anthropic(_ input: Double, _ output: Double) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheWrite: input * 1.25, cacheRead: input * 0.1)
    }

    /// OpenAI charges nothing extra for cache writes (bill them at the input
    /// rate) and 10% of input for cached reads.
    static func openAI(_ input: Double, _ output: Double) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheWrite: input, cacheRead: input * 0.1)
    }

    /// Google bills implicit-cache hits at 25% of input; no separate write fee.
    static func google(_ input: Double, _ output: Double) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheWrite: input, cacheRead: input * 0.25)
    }
}

/// Cost of some usage slice: priced dollars plus the chart tokens that hit
/// no price rule (surfaced as a footnote instead of silently dropped).
public struct UsageCost: Equatable, Sendable {
    public var usd: Double
    /// input+output tokens of rows whose model matched no price rule.
    public var unpricedChartTokens: Int64

    public static let zero = UsageCost(usd: 0, unpricedChartTokens: 0)

    public init(usd: Double, unpricedChartTokens: Int64) {
        self.usd = usd
        self.unpricedChartTokens = unpricedChartTokens
    }

    public static func + (lhs: UsageCost, rhs: UsageCost) -> UsageCost {
        UsageCost(usd: lhs.usd + rhs.usd, unpricedChartTokens: lhs.unpricedChartTokens + rhs.unpricedChartTokens)
    }
}

/// Maps model identifiers to prices. Built-in rules ship with the app and are
/// updated release-by-release; user overrides (Settings, JSON) win over them.
///
/// Matching is case-insensitive substring containment, first rule wins, so
/// more specific patterns must precede family fallbacks.
public struct UsagePriceTable: Sendable {
    public typealias Rule = (pattern: String, price: ModelPrice)

    /// User-supplied rules checked before the built-in table.
    public var overrides: [Rule]
    private let builtin: [Rule]

    public init(overrides: [Rule] = []) {
        self.overrides = overrides
        self.builtin = UsagePriceTable.builtinRules
    }

    /// Built-in $/MTok table, last reviewed 2026-07 (Anthropic prices from the
    /// official models list; OpenAI/Google/Moonshot from their public pricing).
    static let builtinRules: [Rule] = [
        // Anthropic — specific tiers before the family fallbacks.
        ("claude-fable", .anthropic(10, 50)),
        ("claude-mythos", .anthropic(10, 50)),
        ("opus-4-5", .anthropic(5, 25)),
        ("opus-4-6", .anthropic(5, 25)),
        ("opus-4-7", .anthropic(5, 25)),
        ("opus-4-8", .anthropic(5, 25)),
        ("opus", .anthropic(15, 75)),           // Opus 4.1/4.0/3
        ("sonnet", .anthropic(3, 15)),          // Sonnet 5/4.6/4.5/4/3.7/3.5
        ("haiku-3-5", .anthropic(0.80, 4)),
        ("3-haiku", .anthropic(0.25, 1.25)),
        ("haiku", .anthropic(1, 5)),            // Haiku 4.5+
        // OpenAI (Codex).
        ("gpt-5-nano", .openAI(0.05, 0.40)),
        ("gpt-5.1-nano", .openAI(0.05, 0.40)),
        ("gpt-5-mini", .openAI(0.25, 2)),
        ("gpt-5.1-mini", .openAI(0.25, 2)),
        ("codex-mini", .openAI(1.5, 6)),
        ("gpt-5", .openAI(1.25, 10)),           // gpt-5 / 5.1 / 5-codex / 5.1-codex
        ("o4-mini", .openAI(1.1, 4.4)),
        ("o3", .openAI(2, 8)),
        // Google (Gemini CLI).
        ("gemini-3-flash", .google(0.50, 3)),
        ("gemini-3", .google(2, 12)),
        ("gemini-2.5-flash", .google(0.30, 2.50)),
        ("gemini-2.5", .google(1.25, 10)),
        ("gemini", .google(1.25, 10)),
        // Moonshot (Kimi).
        ("kimi", ModelPrice(input: 0.60, output: 2.50, cacheWrite: 0.60, cacheRead: 0.15)),
    ]

    /// Price for `model`, or nil when no rule (override or built-in) matches.
    public func price(forModel model: String) -> ModelPrice? {
        let lowered = model.lowercased()
        for (pattern, price) in overrides where lowered.contains(pattern.lowercased()) {
            return price
        }
        for (pattern, price) in builtin where lowered.contains(pattern) {
            return price
        }
        return nil
    }

    /// Equivalent API cost of `totals` under `model`'s price, or nil when the
    /// model is unpriced.
    public func cost(of totals: UsageTotals, model: String) -> Double? {
        guard let p = price(forModel: model) else { return nil }
        let m = 1_000_000.0
        return Double(totals.inputTokens) / m * p.input
            + Double(totals.outputTokens) / m * p.output
            + Double(totals.cacheWriteTokens) / m * p.cacheWrite
            + Double(totals.cacheReadTokens) / m * p.cacheRead
    }

    /// Aggregate cost over tool × model rows (the detail-table shape).
    /// Unpriced rows contribute their chart tokens to the footnote counter.
    public func cost(of rows: [ToolModelUsage]) -> UsageCost {
        rows.reduce(.zero) { acc, row in
            if let usd = cost(of: row.totals, model: row.model) {
                return acc + UsageCost(usd: usd, unpricedChartTokens: 0)
            }
            return acc + UsageCost(usd: 0, unpricedChartTokens: row.totals.chartTokens)
        }
    }

    // MARK: - Overrides (Settings JSON)

    /// Parse a user-override JSON document of the form
    /// `{"<model pattern>": {"input": 5, "output": 25, "cacheWrite": 6.25, "cacheRead": 0.5}, ...}`.
    /// Missing cache fields default to the Anthropic-style multipliers so a
    /// two-field override stays cheap to write. Returns nil on malformed JSON.
    public static func parseOverrides(json: String) -> [Rule]? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var rules: [Rule] = []
        for (pattern, value) in object {
            guard let fields = value as? [String: Any],
                  let input = doubleValue(fields["input"]),
                  let output = doubleValue(fields["output"])
            else { return nil }
            let price = ModelPrice(
                input: input,
                output: output,
                cacheWrite: doubleValue(fields["cacheWrite"]) ?? input * 1.25,
                cacheRead: doubleValue(fields["cacheRead"]) ?? input * 0.1
            )
            rules.append((pattern, price))
        }
        // Longest pattern first so overlapping user patterns behave predictably.
        return rules.sorted { $0.pattern.count > $1.pattern.count }
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let n as Double: return n
        case let n as Int: return Double(n)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }
}
