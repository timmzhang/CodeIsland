import XCTest
@testable import CodeIslandCore

final class JSONLTailerTests: XCTestCase {

    // MARK: - scanLines (pure)

    func testScanLinesEmptyInputProducesEmptyDeltaAndFragment() {
        let result = JSONLTailer.scanLines(Data())
        XCTAssertTrue(result.delta.isEmpty)
        XCTAssertEqual(result.trailingFragment, Data())
    }

    func testScanLinesExtractsAssistantTextFromSingleLine() {
        let line = assistantLine(text: "hello world") + "\n"
        let result = JSONLTailer.scanLines(Data(line.utf8))
        XCTAssertEqual(result.delta.lastAssistantMessage, "hello world")
        XCTAssertNil(result.delta.lastUserPrompt)
        XCTAssertEqual(result.trailingFragment, Data())
    }

    func testScanLinesExtractsUserPromptFromSingleLine() {
        let line = userLine(text: "what's the weather?") + "\n"
        let result = JSONLTailer.scanLines(Data(line.utf8))
        XCTAssertEqual(result.delta.lastUserPrompt, "what's the weather?")
        XCTAssertNil(result.delta.lastAssistantMessage)
    }

    func testScanLinesLatestLineWinsForEachRole() {
        let bytes = Data(([
            assistantLine(text: "first reply"),
            userLine(text: "first question"),
            assistantLine(text: "second reply"),
            userLine(text: "second question"),
        ].joined(separator: "\n") + "\n").utf8)

        let result = JSONLTailer.scanLines(bytes)
        XCTAssertEqual(result.delta.lastAssistantMessage, "second reply")
        XCTAssertEqual(result.delta.lastUserPrompt, "second question")
    }

    func testScanLinesTrailingPartialLineReturnsAsFragment() {
        let completeLine = assistantLine(text: "done") + "\n"
        let partial = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"half"
        let combined = Data((completeLine + partial).utf8)

        let result = JSONLTailer.scanLines(combined)
        XCTAssertEqual(result.delta.lastAssistantMessage, "done")
        XCTAssertEqual(result.trailingFragment, Data(partial.utf8))
    }

    func testScanLinesIgnoresIsMetaLines() {
        let meta = """
        {"type":"assistant","isMeta":true,"message":{"content":[{"type":"text","text":"boot"}]}}
        """
        let real = assistantLine(text: "real reply")
        let combined = Data((meta + "\n" + real + "\n").utf8)

        let result = JSONLTailer.scanLines(combined)
        XCTAssertEqual(result.delta.lastAssistantMessage, "real reply")
    }

    func testScanLinesIgnoresUnknownType() {
        let line = """
        {"type":"tool_use","message":{"content":[{"type":"text","text":"internal"}]}}
        """
        let result = JSONLTailer.scanLines(Data((line + "\n").utf8))
        XCTAssertTrue(result.delta.isEmpty)
    }

    func testScanLinesExtractsClaudePermissionDecisionAttachment() {
        let line = """
        {"type":"attachment","attachment":{"type":"hook_permission_decision","decision":"allow","toolUseID":"toolu_native"}}
        """
        let result = JSONLTailer.scanLines(Data((line + "\n").utf8))

        XCTAssertEqual(
            result.delta.permissionDecisions,
            [TranscriptPermissionDecision(toolUseId: "toolu_native", decision: "allow")]
        )
        XCTAssertNil(result.delta.lastUserPrompt)
        XCTAssertNil(result.delta.lastAssistantMessage)
    }

    func testScanLinesExtractsCodexTokenCountWithCurrentModel() {
        let bytes = Data(([
            codexTurnContext(model: "gpt-5.6"),
            codexTokenCount(total: 300, input: 120, cached: 20, output: 30),
        ].joined(separator: "\n") + "\n").utf8)

        let result = JSONLTailer.scanLines(bytes, codexSessionId: "codex-session")

        XCTAssertEqual(result.codexModel, "gpt-5.6")
        XCTAssertEqual(result.delta.codexUsageEvents.count, 1)
        let event = result.delta.codexUsageEvents[0]
        XCTAssertEqual(event.sessionId, "codex-session")
        XCTAssertEqual(event.model, "gpt-5.6")
        XCTAssertEqual(event.last.inputTokens, 120)
        XCTAssertEqual(event.last.cachedInputTokens, 20)
        XCTAssertEqual(event.last.outputTokens, 30)
        XCTAssertEqual(event.cumulativeTotalTokens, 300)
    }

    func testScanLinesCarriesCodexModelAndPartialTokenLineAcrossReads() {
        let tokenLine = codexTokenCount(total: 300, input: 120, cached: 20, output: 30)
        let split = tokenLine.index(tokenLine.startIndex, offsetBy: tokenLine.count / 2)
        let firstBytes = Data((codexTurnContext(model: "gpt-5.6") + "\n" + tokenLine[..<split]).utf8)

        let first = JSONLTailer.scanLines(firstBytes, codexSessionId: "codex-session")
        XCTAssertTrue(first.delta.codexUsageEvents.isEmpty)
        XCTAssertEqual(first.codexModel, "gpt-5.6")

        let secondBytes = first.trailingFragment + Data((tokenLine[split...] + "\n").utf8)
        let second = JSONLTailer.scanLines(
            secondBytes,
            codexSessionId: "codex-session",
            codexModel: first.codexModel
        )
        XCTAssertEqual(second.delta.codexUsageEvents.count, 1)
        XCTAssertEqual(second.delta.codexUsageEvents[0].model, "gpt-5.6")
        XCTAssertEqual(second.trailingFragment, Data())
    }

    // MARK: - extractText

    func testExtractTextFromPlainString() {
        XCTAssertEqual(JSONLTailer.extractText(from: "hi"), "hi")
        XCTAssertEqual(JSONLTailer.extractText(from: "  hi  "), "hi")
        XCTAssertNil(JSONLTailer.extractText(from: ""))
        XCTAssertNil(JSONLTailer.extractText(from: "   "))
    }

    func testExtractTextFromMixedBlocks() {
        let blocks: [[String: Any]] = [
            ["type": "text", "text": "part one"],
            ["type": "tool_use", "name": "Bash", "input": ["command": "ls"]],
            ["type": "text", "text": "part two"]
        ]
        XCTAssertEqual(JSONLTailer.extractText(from: blocks), "part one\npart two")
    }

    func testExtractTextFromEmptyArrayReturnsNil() {
        XCTAssertNil(JSONLTailer.extractText(from: [[String: Any]]()))
    }

    func testExtractTextFromUnknownShapeReturnsNil() {
        XCTAssertNil(JSONLTailer.extractText(from: 42))
        XCTAssertNil(JSONLTailer.extractText(from: nil))
    }

    // MARK: - Integration: tail a real file

    func testAttachAndDetectAppendedLine() throws {
        let url = temporaryFileURL()
        try Data("".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expectation = self.expectation(description: "delta delivered")
        // onDelta fires on the tailer's serial queue; the test reads `captured`
        // only after wait(for:), so the access is ordered, not racy.
        nonisolated(unsafe) var captured: ConversationTailDelta?

        let tailer = JSONLTailer(
            queue: DispatchQueue(label: "tailer-test"),
            onDelta: { delta in
                captured = delta
                expectation.fulfill()
            }
        )
        tailer.attach(sessionId: "s1", filePath: url.path)

        // Let the DispatchSource attach before appending.
        Thread.sleep(forTimeInterval: 0.15)

        let line = assistantLine(text: "ping") + "\n"
        try appendToFile(url: url, content: line)

        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(captured?.sessionId, "s1")
        XCTAssertEqual(captured?.lastAssistantMessage, "ping")

        tailer.detach(sessionId: "s1")
    }

    func testAttachIgnoresPreexistingContentByDefault() throws {
        let url = temporaryFileURL()
        let pre = assistantLine(text: "already written") + "\n"
        try Data(pre.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let receivedDelta = self.expectation(description: "delta fires for new append only")

        let tailer = JSONLTailer(
            queue: DispatchQueue(label: "tailer-test"),
            onDelta: { delta in
                XCTAssertEqual(delta.lastAssistantMessage, "fresh")
                receivedDelta.fulfill()
            }
        )
        tailer.attach(sessionId: "s1", filePath: url.path)
        Thread.sleep(forTimeInterval: 0.15)
        try appendToFile(url: url, content: assistantLine(text: "fresh") + "\n")

        wait(for: [receivedDelta], timeout: 2)
        tailer.detach(sessionId: "s1")
    }

    func testAttachCanReplayPreexistingCodexUsageForMissedHookRecovery() throws {
        let url = temporaryFileURL()
        let existing = [
            codexTurnContext(model: "gpt-5.6"),
            codexTokenCount(total: 300, input: 120, cached: 20, output: 30),
        ].joined(separator: "\n") + "\n"
        try Data(existing.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let received = expectation(description: "preexisting Codex usage replayed")
        nonisolated(unsafe) var captured: ConversationTailDelta?
        let tailer = JSONLTailer(
            queue: DispatchQueue(label: "tailer-codex-replay-test"),
            onDelta: { delta in
                captured = delta
                received.fulfill()
            }
        )

        tailer.attach(
            sessionId: "tracked-session",
            filePath: url.path,
            replayExisting: true,
            usageSessionId: "provider-session"
        )

        wait(for: [received], timeout: 2)
        XCTAssertEqual(captured?.sessionId, "tracked-session")
        XCTAssertEqual(captured?.codexUsageEvents.first?.sessionId, "provider-session")
        XCTAssertEqual(captured?.codexUsageEvents.first?.model, "gpt-5.6")
        tailer.detach(sessionId: "tracked-session")
    }

    func testFlushReadsCodexUsageWithoutWaitingForFilesystemCallback() throws {
        let url = temporaryFileURL()
        try Data("".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let received = expectation(description: "Codex usage flushed")
        nonisolated(unsafe) var callbackCount = 0
        let tailer = JSONLTailer(
            queue: DispatchQueue(label: "tailer-codex-flush-test"),
            onDelta: { delta in
                callbackCount += 1
                XCTAssertEqual(delta.codexUsageEvents.first?.last.outputTokens, 30)
                received.fulfill()
            }
        )
        tailer.attach(
            sessionId: "tracked-session",
            filePath: url.path,
            usageSessionId: "provider-session",
            codexModel: "gpt-5.6"
        )
        Thread.sleep(forTimeInterval: 0.15)

        try appendToFile(
            url: url,
            content: codexTokenCount(total: 300, input: 120, cached: 20, output: 30) + "\n"
        )
        tailer.flush(sessionId: "tracked-session")

        wait(for: [received], timeout: 2)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(callbackCount, 1)
        tailer.detach(sessionId: "tracked-session")
    }

    func testDetachStopsFurtherCallbacks() throws {
        let url = temporaryFileURL()
        try Data("".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // onDelta fires on the tailer's serial queue; reads happen after the
        // sleeps below, so this access is ordered, not racy.
        nonisolated(unsafe) var callCount = 0
        let tailer = JSONLTailer(
            queue: DispatchQueue(label: "tailer-test"),
            onDelta: { _ in callCount += 1 }
        )
        tailer.attach(sessionId: "s1", filePath: url.path)
        Thread.sleep(forTimeInterval: 0.15)

        try appendToFile(url: url, content: assistantLine(text: "first") + "\n")
        // Give the dispatch source a moment to deliver.
        Thread.sleep(forTimeInterval: 0.2)

        tailer.detach(sessionId: "s1")
        // Allow detach to flush.
        Thread.sleep(forTimeInterval: 0.15)

        try appendToFile(url: url, content: assistantLine(text: "ignored") + "\n")
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertEqual(callCount, 1)
    }

    // MARK: - Fixtures

    private func assistantLine(text: String) -> String {
        let payload: [String: Any] = [
            "type": "assistant",
            "message": [
                "content": [
                    ["type": "text", "text": text]
                ]
            ]
        ]
        return jsonString(payload)
    }

    private func userLine(text: String) -> String {
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "content": text
            ]
        ]
        return jsonString(payload)
    }

    private func codexTurnContext(model: String) -> String {
        jsonString([
            "type": "turn_context",
            "payload": ["model": model],
        ])
    }

    private func codexTokenCount(total: Int, input: Int, cached: Int, output: Int) -> String {
        jsonString([
            "timestamp": "2026-07-15T03:07:20.890Z",
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": total - output,
                        "cached_input_tokens": cached,
                        "output_tokens": output,
                        "total_tokens": total,
                    ],
                    "last_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output,
                        "total_tokens": input + output,
                    ],
                ],
            ],
        ])
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    private func temporaryFileURL() -> URL {
        let name = "jsonl-tailer-\(UUID().uuidString).jsonl"
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    private func appendToFile(url: URL, content: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(content.utf8))
        try handle.close()
    }
}
