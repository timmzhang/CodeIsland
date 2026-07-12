import XCTest
@testable import CodeIslandCore

final class ClaudeUsageTests: XCTestCase {

    // MARK: - ClaudeUsageEvent.from(line:)

    func testParsesRealisticAssistantUsageLine() throws {
        let json = try line(usageLine(
            messageId: "msg_01", requestId: "req_01", model: "claude-fable-5",
            input: 2, output: 984, cacheWrite: 28367, cacheRead: 11433,
            sessionId: "sess-1", timestamp: "2026-07-11T10:58:04.084Z", sidechain: false
        ))
        let event = try XCTUnwrap(ClaudeUsageEvent.from(line: json))

        XCTAssertEqual(event.messageId, "msg_01")
        XCTAssertEqual(event.requestId, "req_01")
        XCTAssertEqual(event.model, "claude-fable-5")
        XCTAssertEqual(event.sessionId, "sess-1")
        XCTAssertEqual(event.inputTokens, 2)
        XCTAssertEqual(event.outputTokens, 984)
        XCTAssertEqual(event.cacheCreationTokens, 28367)
        XCTAssertEqual(event.cacheReadTokens, 11433)
        XCTAssertEqual(event.totalTokens, 2 + 984 + 28367 + 11433)
        XCTAssertFalse(event.isSidechain)
        let ts = try XCTUnwrap(event.timestamp)
        XCTAssertEqual(ts.timeIntervalSince1970, 1783767484.084, accuracy: 0.001)
    }

    func testParsesSidechainFlagAndSecondsOnlyTimestamp() throws {
        var json = try line(usageLine(messageId: "m", requestId: "r"))
        json["isSidechain"] = true
        json["timestamp"] = "2026-07-11T10:58:04Z"
        let event = try XCTUnwrap(ClaudeUsageEvent.from(line: json))
        XCTAssertTrue(event.isSidechain)
        XCTAssertNotNil(event.timestamp)
    }

    func testFallbackSessionIdUsedWhenLineOmitsIt() throws {
        let json = try line(usageLine(messageId: "m", requestId: "r", sessionId: nil))
        let event = try XCTUnwrap(ClaudeUsageEvent.from(line: json, fallbackSessionId: "from-filename"))
        XCTAssertEqual(event.sessionId, "from-filename")
    }

    func testRejectsNonAssistantMissingUsageSyntheticAndZeroRows() throws {
        var user = try line(usageLine(messageId: "m", requestId: "r"))
        user["type"] = "user"
        XCTAssertNil(ClaudeUsageEvent.from(line: user))

        let noUsage: [String: Any] = [
            "type": "assistant",
            "message": ["id": "m", "model": "claude-fable-5"]
        ]
        XCTAssertNil(ClaudeUsageEvent.from(line: noUsage))

        let synthetic = try line(usageLine(messageId: "m", requestId: "r", model: "<synthetic>"))
        XCTAssertNil(ClaudeUsageEvent.from(line: synthetic))

        let zeros = try line(usageLine(
            messageId: "m", requestId: "r",
            input: 0, output: 0, cacheWrite: 0, cacheRead: 0
        ))
        XCTAssertNil(ClaudeUsageEvent.from(line: zeros))

        let noId = try line(usageLine(messageId: nil, requestId: "r"))
        XCTAssertNil(ClaudeUsageEvent.from(line: noId))
    }

    // MARK: - Deduplicator

    func testDeduplicatorKeysOnMessageIdPlusRequestId() throws {
        let dedup = ClaudeUsageDeduplicator()
        let a = try XCTUnwrap(ClaudeUsageEvent.from(line: line(usageLine(messageId: "m1", requestId: "r1"))))
        let sameKey = try XCTUnwrap(ClaudeUsageEvent.from(line: line(usageLine(messageId: "m1", requestId: "r1", output: 999))))
        let otherRequest = try XCTUnwrap(ClaudeUsageEvent.from(line: line(usageLine(messageId: "m1", requestId: "r2"))))

        XCTAssertTrue(dedup.markSeen(a))
        XCTAssertFalse(dedup.markSeen(sameKey))
        XCTAssertTrue(dedup.markSeen(otherRequest))
        XCTAssertEqual(dedup.count, 2)
    }

    // MARK: - JSONLTailer scanLines carries usage

    func testScanLinesEmitsUsageEventsInFileOrder() {
        let blob = Data(([
            usageLine(messageId: "m1", requestId: "r1", output: 10),
            #"{"type":"user","message":{"content":"hi"}}"#,
            usageLine(messageId: "m2", requestId: "r2", output: 20),
        ].joined(separator: "\n") + "\n").utf8)

        let result = JSONLTailer.scanLines(blob)
        XCTAssertEqual(result.delta.usageEvents.map(\.messageId), ["m1", "m2"])
        XCTAssertEqual(result.delta.usageEvents.map(\.outputTokens), [10, 20])
        XCTAssertFalse(result.delta.isEmpty)
    }

    func testScanLinesEmitsUsageForThinkingOnlyAssistantLine() {
        let raw = """
        {"type":"assistant","message":{"id":"m9","model":"claude-fable-5","content":[{"type":"thinking","thinking":"…"}],"usage":{"input_tokens":5,"output_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"requestId":"r9"}
        """
        let result = JSONLTailer.scanLines(Data((raw + "\n").utf8))
        XCTAssertNil(result.delta.lastAssistantMessage)
        XCTAssertEqual(result.delta.usageEvents.map(\.messageId), ["m9"])
    }

    func testScanLinesDoesNotDeduplicateWithinBurst() {
        let dup = usageLine(messageId: "m1", requestId: "r1")
        let blob = Data((dup + "\n" + dup + "\n").utf8)
        let result = JSONLTailer.scanLines(blob)
        // Dedup is the consumer's job (shared with backfill) — scanLines stays pure.
        XCTAssertEqual(result.delta.usageEvents.count, 2)
    }

    // MARK: - Backfill

    func testScanFilePrefiltersDeduplicatesAndFallsBackToFilename() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sess-abc.jsonl")
        let rows = [
            usageLine(messageId: "m1", requestId: "r1", sessionId: nil),
            usageLine(messageId: "m1", requestId: "r1", sessionId: nil), // streaming dup
            #"{"type":"user","message":{"content":"no usage here"}}"#,
            "not json at all",
            usageLine(messageId: "m2", requestId: "r2", sessionId: "sess-explicit"),
        ]
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: file)

        let dedup = ClaudeUsageDeduplicator()
        let result = ClaudeUsageBackfill.scanFile(at: file, deduplicator: dedup)

        XCTAssertEqual(result.events.map(\.messageId), ["m1", "m2"])
        XCTAssertEqual(result.duplicates, 1)
        XCTAssertEqual(result.events[0].sessionId, "sess-abc")
        XCTAssertEqual(result.events[1].sessionId, "sess-explicit")
    }

    func testScanFileHandlesMissingTrailingNewline() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        try Data(usageLine(messageId: "m1", requestId: "r1").utf8).write(to: file)

        let result = ClaudeUsageBackfill.scanFile(at: file, deduplicator: nil)
        XCTAssertEqual(result.events.map(\.messageId), ["m1"])
    }

    func testFullScanWalksTreeAndDeduplicatesAcrossFiles() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Simulate `--resume`: the same message appears in two session files.
        let projA = root.appendingPathComponent("proj-a")
        let projB = root.appendingPathComponent("proj-b")
        try FileManager.default.createDirectory(at: projA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projB, withIntermediateDirectories: true)
        try Data((usageLine(messageId: "shared", requestId: "r0") + "\n"
            + usageLine(messageId: "a1", requestId: "r1") + "\n").utf8)
            .write(to: projA.appendingPathComponent("s1.jsonl"))
        try Data((usageLine(messageId: "shared", requestId: "r0") + "\n"
            + usageLine(messageId: "b1", requestId: "r2") + "\n").utf8)
            .write(to: projB.appendingPathComponent("s2.jsonl"))
        try Data("ignored".utf8).write(to: projB.appendingPathComponent("notes.txt"))

        let collected = Collected()
        let summary = ClaudeUsageBackfill.scan(projectsRoot: root, concurrency: 2) { _, events in
            collected.append(events)
        }

        XCTAssertEqual(summary.filesScanned, 2)
        XCTAssertEqual(summary.eventsEmitted, 3)
        XCTAssertEqual(summary.duplicatesSkipped, 1)
        XCTAssertEqual(Set(collected.all.map(\.messageId)), ["shared", "a1", "b1"])
    }

    func testFullScanOnEmptyOrMissingRootReturnsEmptySummary() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-usage-missing-\(UUID().uuidString)")
        let summary = ClaudeUsageBackfill.scan(projectsRoot: missing) { _, _ in
            XCTFail("no events expected")
        }
        XCTAssertEqual(summary, ClaudeUsageBackfill.Summary())
    }

    // MARK: - Fixtures

    /// Thread-safe accumulator for scan callbacks (which fire on worker threads).
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ClaudeUsageEvent] = []
        func append(_ new: [ClaudeUsageEvent]) {
            lock.lock()
            events.append(contentsOf: new)
            lock.unlock()
        }
        var all: [ClaudeUsageEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private func usageLine(
        messageId: String?,
        requestId: String?,
        model: String = "claude-fable-5",
        input: Int = 2,
        output: Int = 42,
        cacheWrite: Int = 100,
        cacheRead: Int = 200,
        sessionId: String? = "sess-1",
        timestamp: String = "2026-07-11T10:58:04.084Z",
        sidechain: Bool = false
    ) -> String {
        var message: [String: Any] = [
            "model": model,
            "role": "assistant",
            "content": [["type": "text", "text": "reply"]],
            "usage": [
                "input_tokens": input,
                "output_tokens": output,
                "cache_creation_input_tokens": cacheWrite,
                "cache_read_input_tokens": cacheRead,
            ],
        ]
        if let messageId { message["id"] = messageId }
        var payload: [String: Any] = [
            "type": "assistant",
            "message": message,
            "timestamp": timestamp,
            "isSidechain": sidechain,
        ]
        if let requestId { payload["requestId"] = requestId }
        if let sessionId { payload["sessionId"] = sessionId }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }

    private func line(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-usage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
