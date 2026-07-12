import XCTest
@testable import CodeIslandCore

final class ClaudeUsageProviderTests: XCTestCase {

    // MARK: - normalized()

    func testNormalizedMapsAllFields() {
        let ts = Date(timeIntervalSince1970: 1_783_767_484)
        let claude = ClaudeUsageEvent(
            sessionId: "sess", messageId: "m1", requestId: "r1",
            model: "claude-fable-5", timestamp: ts,
            inputTokens: 1, outputTokens: 2, cacheCreationTokens: 3, cacheReadTokens: 4,
            isSidechain: true
        )
        let event = claude.normalized()

        XCTAssertEqual(event.tool, "claude-code")
        XCTAssertEqual(event.sessionId, "sess")
        XCTAssertEqual(event.model, "claude-fable-5")
        XCTAssertEqual(event.timestamp, ts)
        XCTAssertEqual(event.inputTokens, 1)
        XCTAssertEqual(event.outputTokens, 2)
        XCTAssertEqual(event.cacheWriteTokens, 3)
        XCTAssertEqual(event.cacheReadTokens, 4)
        XCTAssertEqual(event.dedupKey, "m1|r1")
        XCTAssertTrue(event.isSubagent)
    }

    func testNormalizedLabelsMissingDimensionsInsteadOfDropping() {
        let now = Date(timeIntervalSince1970: 1_000)
        let claude = ClaudeUsageEvent(
            sessionId: nil, messageId: "m1", requestId: nil,
            model: nil, timestamp: nil,
            inputTokens: 1, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0,
            isSidechain: false
        )
        let event = claude.normalized(now: now)
        XCTAssertEqual(event.sessionId, "unknown")
        XCTAssertEqual(event.model, "unknown")
        XCTAssertEqual(event.timestamp, now)
        XCTAssertEqual(event.dedupKey, "m1|")
    }

    // MARK: - backfill

    func testBackfillDeliversNormalizedEventsThenCompletion() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let proj = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try Data((usageLine(messageId: "m1", requestId: "r1") + "\n").utf8)
            .write(to: proj.appendingPathComponent("s1.jsonl"))

        let provider = ClaudeUsageProvider(projectsRoot: root)
        let done = expectation(description: "backfill completes")
        let collected = Collected()
        provider.backfill(
            sink: { collected.append($0) },
            completion: { done.fulfill() }
        )
        wait(for: [done], timeout: 5)

        XCTAssertEqual(collected.all.count, 1)
        XCTAssertEqual(collected.all.first?.tool, "claude-code")
        XCTAssertEqual(collected.all.first?.dedupKey, "m1|r1")
    }

    // MARK: - ingest / tailing

    func testIngestForwardsOnlyWhileTailingAndDeduplicates() {
        let provider = ClaudeUsageProvider(projectsRoot: URL(fileURLWithPath: "/nonexistent"))
        let collected = Collected()

        let event = claudeEvent(messageId: "m1", requestId: "r1")
        provider.ingest([event])  // no sink yet — dropped, not consumed

        provider.startTailing(sink: { collected.append($0) })
        provider.ingest([event])
        provider.ingest([event])  // duplicate delta replay
        XCTAssertEqual(collected.all.count, 1)

        provider.ingest([claudeEvent(messageId: "m2", requestId: "r2")])
        XCTAssertEqual(collected.all.count, 2)

        provider.stopTailing()
        provider.ingest([claudeEvent(messageId: "m3", requestId: "r3")])
        XCTAssertEqual(collected.all.count, 2)
    }

    func testIngestSkipsRowsAlreadyCountedByBackfill() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let proj = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try Data((usageLine(messageId: "m1", requestId: "r1") + "\n").utf8)
            .write(to: proj.appendingPathComponent("s1.jsonl"))

        let provider = ClaudeUsageProvider(projectsRoot: root)
        let done = expectation(description: "backfill completes")
        provider.backfill(sink: { _ in }, completion: { done.fulfill() })
        wait(for: [done], timeout: 5)

        let collected = Collected()
        provider.startTailing(sink: { collected.append($0) })
        provider.ingest([claudeEvent(messageId: "m1", requestId: "r1")])
        XCTAssertTrue(collected.all.isEmpty)
    }

    // MARK: - Fixtures

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [UsageEvent] = []
        func append(_ new: [UsageEvent]) {
            lock.lock()
            events.append(contentsOf: new)
            lock.unlock()
        }
        var all: [UsageEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private func claudeEvent(messageId: String, requestId: String) -> ClaudeUsageEvent {
        ClaudeUsageEvent(
            sessionId: "sess", messageId: messageId, requestId: requestId,
            model: "claude-fable-5", timestamp: Date(),
            inputTokens: 1, outputTokens: 1, cacheCreationTokens: 0, cacheReadTokens: 0,
            isSidechain: false
        )
    }

    private func usageLine(messageId: String, requestId: String) -> String {
        let payload: [String: Any] = [
            "type": "assistant",
            "requestId": requestId,
            "sessionId": "sess",
            "timestamp": "2026-07-11T10:58:04.084Z",
            "message": [
                "id": messageId,
                "model": "claude-fable-5",
                "content": [["type": "text", "text": "reply"]],
                "usage": [
                    "input_tokens": 2,
                    "output_tokens": 42,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-usage-provider-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
