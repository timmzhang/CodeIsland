import XCTest
@testable import CodeIslandCore

final class CodexUsageTests: XCTestCase {

    // MARK: - Rollout line parsing

    func testParsesTokenCountLine() {
        let json = tokenCountLine(
            timestamp: "2026-04-29T07:06:09.213Z",
            totalTotal: 26_280,
            lastInput: 26_084, lastCached: 6_528, lastOutput: 196
        )
        let event = CodexUsageEvent.from(line: json, sessionId: "sess", model: "gpt-5.4")

        XCTAssertNotNil(event)
        XCTAssertEqual(event?.sessionId, "sess")
        XCTAssertEqual(event?.model, "gpt-5.4")
        XCTAssertEqual(event?.last.inputTokens, 26_084)
        XCTAssertEqual(event?.last.cachedInputTokens, 6_528)
        XCTAssertEqual(event?.last.outputTokens, 196)
        XCTAssertEqual(event?.cumulativeTotalTokens, 26_280)
        XCTAssertEqual(
            event?.timestamp,
            ClaudeUsageEvent.parseTimestamp("2026-04-29T07:06:09.213Z")
        )
    }

    func testSkipsRateLimitOnlyLine() {
        var json = tokenCountLine(totalTotal: 0, lastInput: 0, lastCached: 0, lastOutput: 0)
        var payload = json["payload"] as! [String: Any]
        payload["info"] = NSNull()
        json["payload"] = payload
        XCTAssertNil(CodexUsageEvent.from(line: json, sessionId: "sess", model: nil))
    }

    func testSkipsZeroUsageLine() {
        let json = tokenCountLine(totalTotal: 100, lastInput: 0, lastCached: 0, lastOutput: 0)
        XCTAssertNil(CodexUsageEvent.from(line: json, sessionId: "sess", model: nil))
    }

    func testSkipsNonTokenCountLines() {
        let json: [String: Any] = ["type": "response_item", "payload": ["type": "message"]]
        XCTAssertNil(CodexUsageEvent.from(line: json, sessionId: "sess", model: nil))
    }

    // MARK: - Normalization (口径对齐 Claude)

    func testNormalizedSubtractsCachedFromInput() {
        let event = CodexUsageEvent(
            sessionId: "sess", model: "gpt-5.4",
            timestamp: Date(timeIntervalSince1970: 1_000),
            last: CodexTokenCounts(inputTokens: 26_084, cachedInputTokens: 6_528, outputTokens: 196, totalTokens: 26_280),
            cumulativeTotalTokens: 26_280
        )
        let normalized = event.normalized()

        XCTAssertEqual(normalized.tool, "codex")
        XCTAssertEqual(normalized.inputTokens, 19_556)  // input excludes cache reads, like Claude
        XCTAssertEqual(normalized.cacheReadTokens, 6_528)
        XCTAssertEqual(normalized.cacheWriteTokens, 0)
        XCTAssertEqual(normalized.outputTokens, 196)
        XCTAssertEqual(normalized.timestamp, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(normalized.dedupKey, "codex|26280|26084|6528|196")
        XCTAssertFalse(normalized.isSubagent)
    }

    func testNormalizedLabelsMissingDimensionsInsteadOfDropping() {
        let now = Date(timeIntervalSince1970: 2_000)
        let event = CodexUsageEvent(
            sessionId: "sess", model: nil, timestamp: nil,
            last: CodexTokenCounts(inputTokens: 10, cachedInputTokens: 0, outputTokens: 5, totalTokens: 15),
            cumulativeTotalTokens: 15
        )
        let normalized = event.normalized(now: now)
        XCTAssertEqual(normalized.model, "unknown")
        XCTAssertEqual(normalized.timestamp, now)
    }

    // MARK: - Dedup semantics

    func testDedupKeyIgnoresSessionIdAndTimestampSoForkCopiesCollapse() {
        // fork/resume copies history lines under a NEW session id and rewrites
        // their timestamps to the fork moment — only the counters survive.
        let original = CodexUsageEvent(
            sessionId: "original", model: "gpt-5.5",
            timestamp: ClaudeUsageEvent.parseTimestamp("2026-05-07T02:30:33.206Z"),
            last: CodexTokenCounts(inputTokens: 27_000, cachedInputTokens: 0, outputTokens: 755, totalTokens: 27_755),
            cumulativeTotalTokens: 27_755
        )
        let forkCopy = CodexUsageEvent(
            sessionId: "forked", model: "gpt-5.5",
            timestamp: ClaudeUsageEvent.parseTimestamp("2026-05-08T07:32:29.723Z"),
            last: original.last,
            cumulativeTotalTokens: 27_755
        )
        XCTAssertEqual(original.dedupKey, forkCopy.dedupKey)

        let dedup = CodexUsageDeduplicator()
        XCTAssertTrue(dedup.markSeen(original))
        XCTAssertFalse(dedup.markSeen(forkCopy))
    }

    func testTurnStartSnapshotReemissionCollapses() {
        // Codex re-emits the previous sample at turn start (same total, same last).
        let dedup = CodexUsageDeduplicator()
        let sample = CodexUsageEvent(
            sessionId: "sess", model: nil, timestamp: nil,
            last: CodexTokenCounts(inputTokens: 100, cachedInputTokens: 0, outputTokens: 50, totalTokens: 150),
            cumulativeTotalTokens: 696_566
        )
        XCTAssertTrue(dedup.markSeen(sample))
        XCTAssertFalse(dedup.markSeen(sample))
    }

    func testRewoundBranchesBothCount() {
        // After an esc/retry the cumulative total rewinds and re-diverges; both
        // branches were real API spend and must both survive dedup.
        let dedup = CodexUsageDeduplicator()
        let discarded = CodexUsageEvent(
            sessionId: "sess", model: nil, timestamp: nil,
            last: CodexTokenCounts(inputTokens: 100_000, cachedInputTokens: 90_000, outputTokens: 3_739, totalTokens: 103_739),
            cumulativeTotalTokens: 8_311_690
        )
        let replayed = CodexUsageEvent(
            sessionId: "sess", model: nil, timestamp: nil,
            last: CodexTokenCounts(inputTokens: 100_000, cachedInputTokens: 90_000, outputTokens: 2_587, totalTokens: 102_587),
            cumulativeTotalTokens: 8_310_538
        )
        XCTAssertTrue(dedup.markSeen(discarded))
        XCTAssertTrue(dedup.markSeen(replayed))
    }

    // MARK: - scanFile

    func testScanFileTracksSessionMetaAndTurnContext() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout-2026-04-29T15-05-17-\(uuidA).jsonl")
        let lines = [
            sessionMetaLine(id: "meta-session"),
            turnContextLine(model: "gpt-5.4"),
            jsonString(tokenCountLine(totalTotal: 100, lastInput: 80, lastCached: 0, lastOutput: 20)),
            turnContextLine(model: "gpt-5.5"),
            jsonString(tokenCountLine(totalTotal: 300, lastInput: 150, lastCached: 0, lastOutput: 50)),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let (events, duplicates) = CodexUsageBackfill.scanFile(at: file, deduplicator: nil)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(duplicates, 0)
        XCTAssertEqual(events[0].sessionId, "meta-session")
        XCTAssertEqual(events[0].model, "gpt-5.4")
        XCTAssertEqual(events[1].model, "gpt-5.5")
    }

    func testScanFileFirstSessionMetaWinsOverForkEmbeddedMeta() throws {
        // A fork file's own meta comes first; the copied original meta must not
        // steal attribution of subsequent samples.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout-2026-05-08T15-32-29-\(uuidA).jsonl")
        let lines = [
            sessionMetaLine(id: "fork-session"),
            sessionMetaLine(id: "original-session"),
            jsonString(tokenCountLine(totalTotal: 100, lastInput: 80, lastCached: 0, lastOutput: 20)),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let (events, _) = CodexUsageBackfill.scanFile(at: file, deduplicator: nil)
        XCTAssertEqual(events.first?.sessionId, "fork-session")
    }

    func testScanFileFallsBackToFilenameUUID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout-2026-04-29T15-05-17-\(uuidA).jsonl")
        let line = jsonString(tokenCountLine(totalTotal: 100, lastInput: 80, lastCached: 0, lastOutput: 20))
        try Data((line + "\n").utf8).write(to: file)

        let (events, _) = CodexUsageBackfill.scanFile(at: file, deduplicator: nil)
        XCTAssertEqual(events.first?.sessionId, uuidA)
    }

    func testScanDeduplicatesForkCopiedHistoryAcrossFiles() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("2026/05/07")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        let shared = jsonString(tokenCountLine(totalTotal: 27_755, lastInput: 27_000, lastCached: 0, lastOutput: 755))
        let forkOnly = jsonString(tokenCountLine(totalTotal: 59_003, lastInput: 30_000, lastCached: 0, lastOutput: 1_248))
        try Data((sessionMetaLine(id: "orig") + "\n" + shared + "\n").utf8)
            .write(to: day.appendingPathComponent("rollout-2026-05-07T10-29-43-\(uuidA).jsonl"))
        try Data((sessionMetaLine(id: "fork") + "\n" + shared + "\n" + forkOnly + "\n").utf8)
            .write(to: day.appendingPathComponent("rollout-2026-05-07T11-00-00-\(uuidB).jsonl"))

        let collected = Collected<CodexUsageEvent>()
        let summary = CodexUsageBackfill.scan(sessionsRoot: root, concurrency: 1) { _, events in
            collected.append(events)
        }
        XCTAssertEqual(summary.filesScanned, 2)
        XCTAssertEqual(summary.eventsEmitted, 2)
        XCTAssertEqual(summary.duplicatesSkipped, 1)
        // The shared sample was counted once, under the (chronologically first) original.
        let sessions = collected.all.map(\.sessionId).sorted()
        XCTAssertEqual(sessions, ["fork", "orig"])
    }

    // MARK: - Fixtures

    private let uuidA = "019dd80e-6cd2-77d3-a997-20862fab210d"
    private let uuidB = "019e0680-9137-7d60-806c-460f58d86ee4"

    private func tokenCountLine(
        timestamp: String = "2026-04-29T07:06:09.213Z",
        totalTotal: Int,
        lastInput: Int, lastCached: Int, lastOutput: Int
    ) -> [String: Any] {
        [
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": totalTotal - lastOutput,
                        "cached_input_tokens": lastCached,
                        "output_tokens": lastOutput,
                        "reasoning_output_tokens": 0,
                        "total_tokens": totalTotal,
                    ],
                    "last_token_usage": [
                        "input_tokens": lastInput,
                        "cached_input_tokens": lastCached,
                        "output_tokens": lastOutput,
                        "reasoning_output_tokens": 0,
                        "total_tokens": lastInput + lastOutput,
                    ],
                    "model_context_window": 258_400,
                ],
                "rate_limits": ["limit_id": "codex"],
            ],
        ]
    }

    private func sessionMetaLine(id: String) -> String {
        jsonString([
            "timestamp": "2026-04-29T07:06:03.532Z",
            "type": "session_meta",
            "payload": ["id": id, "cwd": "/tmp", "source": "cli"],
        ])
    }

    private func turnContextLine(model: String) -> String {
        jsonString([
            "timestamp": "2026-04-29T07:06:03.533Z",
            "type": "turn_context",
            "payload": ["model": model, "cwd": "/tmp"],
        ])
    }

    private func jsonString(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-usage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class CodexUsageProviderTests: XCTestCase {

    func testBackfillDeliversNormalizedEventsThenCompletion() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRollout(
            in: root, name: "rollout-2026-04-29T15-05-17-\(uuid).jsonl",
            lines: [
                sessionMeta(id: uuid),
                turnContext(model: "gpt-5.4"),
                tokenCount(total: 26_280, input: 26_084, cached: 6_528, output: 196),
            ]
        )

        let provider = CodexUsageProvider(sessionsRoot: root)
        let done = expectation(description: "backfill completes")
        let collected = Collected<UsageEvent>()
        provider.backfill(
            sink: { collected.append($0) },
            completion: { done.fulfill() }
        )
        wait(for: [done], timeout: 5)

        XCTAssertEqual(collected.all.count, 1)
        let event = collected.all[0]
        XCTAssertEqual(event.tool, "codex")
        XCTAssertEqual(event.model, "gpt-5.4")
        XCTAssertEqual(event.inputTokens, 19_556)
        XCTAssertEqual(event.cacheReadTokens, 6_528)
        XCTAssertEqual(event.cacheWriteTokens, 0)
        XCTAssertEqual(event.outputTokens, 196)
    }

    func testIngestForwardsOnlyWhileTailingAndDeduplicates() {
        let provider = CodexUsageProvider(sessionsRoot: URL(fileURLWithPath: "/nonexistent"))
        let collected = Collected<UsageEvent>()

        let params = tokenUsageParams(threadId: "t1", total: 150, input: 100, cached: 0, output: 50)
        provider.ingestTokenUsage(params: params)  // no sink yet — dropped, not consumed

        provider.startTailing(sink: { collected.append($0) })
        provider.ingestTokenUsage(params: params)
        provider.ingestTokenUsage(params: params)  // duplicate notification replay
        XCTAssertEqual(collected.all.count, 1)

        provider.ingestTokenUsage(params: tokenUsageParams(threadId: "t1", total: 300, input: 120, cached: 0, output: 30))
        XCTAssertEqual(collected.all.count, 2)

        provider.stopTailing()
        provider.ingestTokenUsage(params: tokenUsageParams(threadId: "t1", total: 450, input: 120, cached: 0, output: 30))
        XCTAssertEqual(collected.all.count, 2)
    }

    func testIngestSkipsSamplesAlreadyCountedByBackfill() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRollout(
            in: root, name: "rollout-2026-04-29T15-05-17-\(uuid).jsonl",
            lines: [
                sessionMeta(id: uuid),
                tokenCount(total: 150, input: 100, cached: 0, output: 50),
            ]
        )

        let provider = CodexUsageProvider(sessionsRoot: root)
        let done = expectation(description: "backfill completes")
        provider.backfill(sink: { _ in }, completion: { done.fulfill() })
        wait(for: [done], timeout: 5)

        let collected = Collected<UsageEvent>()
        provider.startTailing(sink: { collected.append($0) })
        provider.ingestTokenUsage(
            params: tokenUsageParams(threadId: uuid, total: 150, input: 100, cached: 0, output: 50)
        )
        XCTAssertTrue(collected.all.isEmpty)
    }

    func testIngestAttributesModelFromSettingsNotification() {
        let provider = CodexUsageProvider(sessionsRoot: URL(fileURLWithPath: "/nonexistent"))
        let collected = Collected<UsageEvent>()
        provider.startTailing(sink: { collected.append($0) })

        provider.ingestTokenUsage(params: tokenUsageParams(threadId: "t1", total: 150, input: 100, cached: 0, output: 50))
        XCTAssertEqual(collected.all.last?.model, "unknown")

        provider.noteThreadSettings(params: [
            "threadId": .string("t1"),
            "threadSettings": .object(["model": .string("gpt-5.5")]),
        ])
        provider.ingestTokenUsage(params: tokenUsageParams(threadId: "t1", total: 300, input: 120, cached: 0, output: 30))
        XCTAssertEqual(collected.all.last?.model, "gpt-5.5")
    }

    func testBackfillSeedsModelForResumedLiveThread() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRollout(
            in: root, name: "rollout-2026-04-29T15-05-17-\(uuid).jsonl",
            lines: [
                sessionMeta(id: uuid),
                turnContext(model: "gpt-5.4"),
                tokenCount(total: 150, input: 100, cached: 0, output: 50),
            ]
        )

        let provider = CodexUsageProvider(sessionsRoot: root)
        let done = expectation(description: "backfill completes")
        provider.backfill(sink: { _ in }, completion: { done.fulfill() })
        wait(for: [done], timeout: 5)

        let collected = Collected<UsageEvent>()
        provider.startTailing(sink: { collected.append($0) })
        provider.ingestTokenUsage(
            params: tokenUsageParams(threadId: uuid, total: 300, input: 120, cached: 0, output: 30)
        )
        XCTAssertEqual(collected.all.last?.model, "gpt-5.4")
    }

    // MARK: - Fixtures

    private let uuid = "019dd80e-6cd2-77d3-a997-20862fab210d"

    private func tokenUsageParams(
        threadId: String, total: Int64, input: Int64, cached: Int64, output: Int64
    ) -> [String: AnyCodableLike] {
        [
            "threadId": .string(threadId),
            "turnId": .string("turn-1"),
            "tokenUsage": .object([
                "last": .object([
                    "inputTokens": .int(input),
                    "cachedInputTokens": .int(cached),
                    "outputTokens": .int(output),
                    "reasoningOutputTokens": .int(0),
                    "totalTokens": .int(input + output),
                ]),
                "total": .object([
                    "inputTokens": .int(total - output),
                    "cachedInputTokens": .int(cached),
                    "outputTokens": .int(output),
                    "reasoningOutputTokens": .int(0),
                    "totalTokens": .int(total),
                ]),
                "modelContextWindow": .int(258_400),
            ]),
        ]
    }

    private func sessionMeta(id: String) -> String {
        json(["timestamp": "2026-04-29T07:06:03.532Z", "type": "session_meta", "payload": ["id": id]])
    }

    private func turnContext(model: String) -> String {
        json(["timestamp": "2026-04-29T07:06:03.533Z", "type": "turn_context", "payload": ["model": model]])
    }

    private func tokenCount(total: Int, input: Int, cached: Int, output: Int) -> String {
        json([
            "timestamp": "2026-04-29T07:06:09.213Z",
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": total - output, "cached_input_tokens": cached,
                        "output_tokens": output, "reasoning_output_tokens": 0, "total_tokens": total,
                    ],
                    "last_token_usage": [
                        "input_tokens": input, "cached_input_tokens": cached,
                        "output_tokens": output, "reasoning_output_tokens": 0, "total_tokens": input + output,
                    ],
                ],
            ],
        ])
    }

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func writeRollout(in root: URL, name: String, lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: root.appendingPathComponent(name))
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-usage-provider-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Thread-safe event collector shared by the usage tests in this file.
final class Collected<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    func append(_ new: [Element]) {
        lock.lock()
        items.append(contentsOf: new)
        lock.unlock()
    }
    var all: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
