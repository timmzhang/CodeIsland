import XCTest
@testable import CodeIslandCore

/// Codex `request_user_input_async` leaves no hook and no blocking wait: the
/// rollout records an `item_completed` AgentMessage with `delivery: "async"` and
/// a `questions` array, answers the tool call with `{"accepted":true}` at once and
/// keeps working while the TUI parks the question under "Queued follow-up inputs".
/// The tailer derives a `CodexAsyncQuestionSignal` from those rows; a later user
/// message row (the answer is submitted as an ordinary turn input) clears it.
final class JSONLTailerCodexAsyncQuestionTests: XCTestCase {

    // MARK: - Line builders (shapes copied from a codex-cli 0.155 rollout)

    private func asyncQuestionLine(
        titles: [String],
        options: String = "null",
        timestamp: String = "2026-09-23T01:28:54.028Z"
    ) -> String {
        let questions = titles.map { #"{"title":"\#($0)","options":\#(options)}"# }.joined(separator: ",")
        let text = titles.first ?? ""
        return #"{"timestamp":"\#(timestamp)","ordinal":434,"type":"event_msg","payload":{"type":"item_completed","thread_id":"t-1","turn_id":"turn-1","item":{"type":"AgentMessage","id":"call_1","content":[{"type":"Text","text":"\#(text)"}],"phase":"final_answer","delivery":"async","questions":[\#(questions)]},"started_at_ms":1,"completed_at_ms":1}}"#
    }

    private func plainAgentMessageLine(text: String) -> String {
        #"{"timestamp":"2026-09-23T01:34:51.326Z","ordinal":657,"type":"event_msg","payload":{"type":"item_completed","thread_id":"t-1","turn_id":"turn-1","item":{"type":"AgentMessage","id":"msg_1","content":[{"type":"Text","text":"\#(text)"}],"phase":"final_answer"},"started_at_ms":1,"completed_at_ms":1}}"#
    }

    private func asyncToolCallLine(title: String) -> String {
        #"{"timestamp":"2026-09-23T01:28:53.957Z","ordinal":433,"type":"response_item","payload":{"type":"function_call","id":"fc_1","name":"request_user_input_async","arguments":"{\"questions\":[{\"title\":\"\#(title)\"}]}","call_id":"call_1"}}"#
    }

    private func asyncToolOutputLine() -> String {
        #"{"timestamp":"2026-09-23T01:28:54.210Z","ordinal":436,"type":"response_item","payload":{"type":"function_call_output","id":"fco_1","call_id":"call_1","output":"{\"accepted\":true}"}}"#
    }

    private func codexUserMessageLine(text: String) -> String {
        #"{"timestamp":"2026-09-23T01:40:00.000Z","ordinal":700,"type":"response_item","payload":{"type":"message","id":"msg_u1","role":"user","content":[{"type":"input_text","text":"\#(text)"}]}}"#
    }

    private func codexAssistantMessageLine(text: String) -> String {
        #"{"timestamp":"2026-09-23T01:41:00.000Z","ordinal":701,"type":"response_item","payload":{"type":"message","id":"msg_a1","role":"assistant","content":[{"type":"output_text","text":"\#(text)"}]}}"#
    }

    private func taskCompleteLine() -> String {
        #"{"timestamp":"2026-09-23T01:34:51.326Z","ordinal":658,"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":"done"}}"#
    }

    private func scan(_ lines: [String]) -> JSONLTailer.ScanResult {
        JSONLTailer.scanLines(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    // MARK: - Pending detection

    func testAsyncQuestionItemMarksPendingWithTitleAndTimestamp() {
        let result = scan([
            asyncToolCallLine(title: "请在手机上点“请求通知权限”"),
            asyncQuestionLine(titles: ["请在手机上点“请求通知权限”"]),
            asyncToolOutputLine(),
        ])

        guard case .pending(let prompt, let askedAt)? = result.delta.codexAsyncQuestion else {
            return XCTFail("expected pending, got \(String(describing: result.delta.codexAsyncQuestion))")
        }
        XCTAssertEqual(prompt, "请在手机上点“请求通知权限”")
        XCTAssertEqual(askedAt?.timeIntervalSince1970 ?? 0, 1_790_126_934.028, accuracy: 0.001)
        XCTAssertTrue(result.delta.hasActivity)
    }

    func testMultipleAsyncQuestionsGetNumericSuffix() {
        let result = scan([asyncQuestionLine(titles: ["Which DB?", "Which CI?", "Which tests?"])])
        guard case .pending(let prompt, _)? = result.delta.codexAsyncQuestion else {
            return XCTFail("expected pending")
        }
        XCTAssertEqual(prompt, "Which DB? (+2)")
    }

    func testAsyncQuestionWithOptionsStillUsesTitle() {
        let result = scan([asyncQuestionLine(titles: ["确认废除？"], options: #"["确认废除","取消"]"#)])
        guard case .pending(let prompt, _)? = result.delta.codexAsyncQuestion else {
            return XCTFail("expected pending")
        }
        XCTAssertEqual(prompt, "确认废除？")
    }

    func testAsyncQuestionWithoutTitleFallsBackToMessageText() {
        let prompt = JSONLTailer.codexAsyncQuestionPrompt(inItem: [
            "type": "AgentMessage",
            "delivery": "async",
            "questions": [["title": "   "]],
            "content": [["type": "Text", "text": "Fallback text"]],
        ])
        XCTAssertEqual(prompt, "Fallback text")
    }

    func testUnparseableTimestampYieldsNilAskedAt() {
        let result = scan([asyncQuestionLine(titles: ["Q"], timestamp: "not-a-date")])
        guard case .pending(_, let askedAt)? = result.delta.codexAsyncQuestion else {
            return XCTFail("expected pending")
        }
        XCTAssertNil(askedAt)
    }

    // MARK: - Non-question rows stay silent

    func testPlainAgentMessageIsNotAQuestion() {
        let result = scan([plainAgentMessageLine(text: "All tests pass.")])
        XCTAssertNil(result.delta.codexAsyncQuestion)
    }

    func testToolCallAndOutputRowsAloneDoNotSignal() {
        // The `function_call` row is not used as the trigger: the `item_completed`
        // row carries the structured questions and is what the TUI renders from.
        let result = scan([asyncToolCallLine(title: "Q"), asyncToolOutputLine()])
        XCTAssertNil(result.delta.codexAsyncQuestion)
    }

    func testTurnEndDoesNotClearQueuedQuestion() {
        // The TUI keeps the question queued after the turn finishes; the final
        // agent message even repeats it. Only a user row clears.
        let result = scan([
            asyncQuestionLine(titles: ["Q"]),
            plainAgentMessageLine(text: "Q — please answer."),
            taskCompleteLine(),
        ])
        guard case .pending(let prompt, _)? = result.delta.codexAsyncQuestion else {
            return XCTFail("expected pending after task_complete")
        }
        XCTAssertEqual(prompt, "Q")
        XCTAssertEqual(result.delta.turnStatus, .idle)
    }

    // MARK: - Clearing

    func testCodexUserMessageRowClears() {
        let result = scan([
            asyncQuestionLine(titles: ["Q"]),
            codexUserMessageLine(text: "> Q\\n\\n已完成"),
        ])
        XCTAssertEqual(result.delta.codexAsyncQuestion, .cleared)
    }

    func testCodexUserRowAloneEmitsClearedWithoutChatText() {
        // Chat text for Codex stays hook-sourced; the transcript row only proves
        // the user is back in the terminal.
        let result = scan([codexUserMessageLine(text: "继续")])
        XCTAssertEqual(result.delta.codexAsyncQuestion, .cleared)
        XCTAssertNil(result.delta.lastUserPrompt)
    }

    func testCodexAssistantMessageRowDoesNotClear() {
        let result = scan([
            asyncQuestionLine(titles: ["Q"]),
            codexAssistantMessageLine(text: "Still working."),
        ])
        guard case .pending? = result.delta.codexAsyncQuestion else {
            return XCTFail("assistant row must not clear the queued question")
        }
    }

    func testClaudeUserRowDoesNotEmitCodexSignal() {
        // Claude nests `"role":"user"` inside `message`; the type probe routes the
        // row before the Codex marker is consulted.
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#
        let result = scan([line])
        XCTAssertNil(result.delta.codexAsyncQuestion)
        XCTAssertEqual(result.delta.lastUserPrompt, "hi")
    }

    func testDeltaIsEmptyTracksCodexSignal() {
        var delta = JSONLTailer.ScanResult.Delta()
        XCTAssertTrue(delta.isEmpty)
        delta.codexAsyncQuestion = .cleared
        XCTAssertFalse(delta.isEmpty)
    }
}
