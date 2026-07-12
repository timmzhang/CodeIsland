import XCTest
@testable import CodeIslandCore

final class UsagePricingTests: XCTestCase {

    // MARK: - Built-in rule resolution

    func testCurrentAnthropicTiers() {
        let table = UsagePriceTable()
        XCTAssertEqual(table.price(forModel: "claude-opus-4-8")?.input, 5)
        XCTAssertEqual(table.price(forModel: "claude-opus-4-8")?.output, 25)
        XCTAssertEqual(table.price(forModel: "claude-fable-5")?.input, 10)
        XCTAssertEqual(table.price(forModel: "claude-sonnet-5")?.output, 15)
        XCTAssertEqual(table.price(forModel: "claude-haiku-4-5-20251001")?.input, 1)
    }

    func testSpecificTierWinsOverFamilyFallback() {
        let table = UsagePriceTable()
        // Opus 4.5+ dropped to $5/$25; older Opus stays at the $15/$75 fallback.
        XCTAssertEqual(table.price(forModel: "claude-opus-4-5-20251101")?.input, 5)
        XCTAssertEqual(table.price(forModel: "claude-opus-4-1-20250805")?.input, 15)
        XCTAssertEqual(table.price(forModel: "claude-3-opus-20240229")?.input, 15)
        XCTAssertEqual(table.price(forModel: "claude-3-haiku-20240307")?.input, 0.25)
    }

    func testMatchingIsCaseInsensitiveSubstring() {
        let table = UsagePriceTable()
        XCTAssertEqual(table.price(forModel: "GPT-5-Codex")?.input, 1.25)
        XCTAssertEqual(table.price(forModel: "gpt-5.1-codex-max")?.output, 10)
        XCTAssertEqual(table.price(forModel: "kimi-k2")?.cacheRead, 0.15)
    }

    func testUnknownModelIsUnpriced() {
        XCTAssertNil(UsagePriceTable().price(forModel: "totally-new-model"))
        XCTAssertNil(UsagePriceTable().price(forModel: "unknown"))
    }

    func testAnthropicCacheMultipliers() {
        let price = UsagePriceTable().price(forModel: "claude-opus-4-8")
        XCTAssertEqual(price?.cacheWrite, 6.25, "write = 1.25× input")
        XCTAssertEqual(price?.cacheRead, 0.5, "read = 0.1× input")
    }

    // MARK: - Cost computation

    func testCostSumsAllFourCounters() {
        let table = UsagePriceTable()
        // 1M of each counter on opus-4-8: 5 + 25 + 6.25 + 0.5
        let totals = UsageTotals(
            inputTokens: 1_000_000, outputTokens: 1_000_000,
            cacheReadTokens: 1_000_000, cacheWriteTokens: 1_000_000
        )
        XCTAssertEqual(table.cost(of: totals, model: "claude-opus-4-8")!, 36.75, accuracy: 0.0001)
    }

    func testAggregateCostTracksUnpricedRows() {
        let table = UsagePriceTable()
        let rows = [
            ToolModelUsage(
                tool: "claude-code", model: "claude-opus-4-8",
                totals: UsageTotals(inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
            ),
            ToolModelUsage(
                tool: "mystery", model: "no-such-model",
                totals: UsageTotals(inputTokens: 300, outputTokens: 400, cacheReadTokens: 999, cacheWriteTokens: 0)
            ),
        ]
        let cost = table.cost(of: rows)
        XCTAssertEqual(cost.usd, 5, accuracy: 0.0001)
        XCTAssertEqual(cost.unpricedChartTokens, 700, "cache tokens stay out of the footnote counter")
    }

    // MARK: - Overrides

    func testOverrideWinsOverBuiltin() {
        var table = UsagePriceTable()
        table.overrides = [("opus-4-8", ModelPrice(input: 1, output: 2, cacheWrite: 3, cacheRead: 4))]
        XCTAssertEqual(table.price(forModel: "claude-opus-4-8")?.input, 1)
        XCTAssertEqual(table.price(forModel: "claude-sonnet-5")?.input, 3, "unrelated models keep built-in prices")
    }

    func testParseOverridesFillsCacheDefaults() throws {
        let rules = try XCTUnwrap(UsagePriceTable.parseOverrides(json: #"{"my-model": {"input": 8, "output": 40}}"#))
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].price.cacheWrite, 10, "defaults to 1.25× input")
        XCTAssertEqual(rules[0].price.cacheRead, 0.8, accuracy: 0.0001, "defaults to 0.1× input")
    }

    func testParseOverridesEmptyAndInvalid() {
        XCTAssertEqual(UsagePriceTable.parseOverrides(json: "")?.count, 0)
        XCTAssertEqual(UsagePriceTable.parseOverrides(json: "  \n")?.count, 0)
        XCTAssertNil(UsagePriceTable.parseOverrides(json: "{not json"))
        XCTAssertNil(UsagePriceTable.parseOverrides(json: #"{"m": {"input": 5}}"#), "output is required")
        XCTAssertNil(UsagePriceTable.parseOverrides(json: #"[1, 2]"#), "top level must be an object")
    }

    func testParseOverridesSortsLongestPatternFirst() throws {
        let rules = try XCTUnwrap(UsagePriceTable.parseOverrides(json: #"""
            {"opus": {"input": 1, "output": 2}, "opus-4-8": {"input": 9, "output": 9}}
            """#))
        XCTAssertEqual(rules.map(\.pattern), ["opus-4-8", "opus"])
        var table = UsagePriceTable(overrides: rules)
        XCTAssertEqual(table.price(forModel: "claude-opus-4-8")?.input, 9)
        XCTAssertEqual(table.price(forModel: "claude-opus-4-1")?.input, 1)
        table.overrides = []
        XCTAssertEqual(table.price(forModel: "claude-opus-4-8")?.input, 5)
    }
}
