import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Codex `request_user_input_async` queues a question in the Codex TUI and keeps
/// the turn running; no hook fires. The transcript tail records the question on
/// the session (independent of `status`), raises a display-only reminder card and
/// keeps the row hint until a user message row shows the question was handled.
@MainActor
final class AppStateCodexAsyncQuestionTests: XCTestCase {

    private let sessionId = "01a0c8ab-062d-7ef0-9820-36184f1d90ac"

    private func codexSession(status: AgentStatus = .running) -> SessionSnapshot {
        var session = SessionSnapshot()
        session.source = "codex"
        session.status = status
        session.cwd = "/tmp/OnCue_p-phij"
        session.transcriptPath = "/tmp/rollout.jsonl"
        return session
    }

    private func pendingDelta(_ prompt: String, askedAt: Date? = Date()) -> ConversationTailDelta {
        ConversationTailDelta(
            sessionId: sessionId,
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            hasActivity: true,
            codexAsyncQuestion: .pending(prompt: prompt, askedAt: askedAt)
        )
    }

    private func clearedDelta() -> ConversationTailDelta {
        ConversationTailDelta(
            sessionId: sessionId,
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            codexAsyncQuestion: .cleared
        )
    }

    // MARK: - applyCodexAsyncQuestionSignal (pure transition)

    func testPendingRecordsQuestionWithoutTouchingStatus() {
        var session = codexSession(status: .running)
        session.currentTool = "Bash"

        let result = AppState.applyCodexAsyncQuestionSignal(
            .pending(prompt: "Which DB?", askedAt: Date()),
            to: &session
        )

        XCTAssertEqual(result, .markedPending(fresh: true))
        XCTAssertEqual(session.codexPendingQuestion, "Which DB?")
        XCTAssertEqual(session.status, .running, "the async question never blocks the turn")
        XCTAssertEqual(session.currentTool, "Bash")
    }

    func testSamePendingQuestionAgainIsNotFresh() {
        var session = codexSession()
        session.codexPendingQuestion = "Which DB?"
        let result = AppState.applyCodexAsyncQuestionSignal(
            .pending(prompt: "Which DB?", askedAt: Date()),
            to: &session
        )
        XCTAssertEqual(result, .markedPending(fresh: false))
    }

    func testStalePendingQuestionIsIgnored() {
        var session = codexSession()
        let now = Date()
        let result = AppState.applyCodexAsyncQuestionSignal(
            .pending(prompt: "Old", askedAt: now.addingTimeInterval(-AppState.codexAsyncQuestionMaxAge - 1)),
            to: &session,
            now: now
        )
        XCTAssertEqual(result, .ignored)
        XCTAssertNil(session.codexPendingQuestion)
    }

    func testPendingWithoutTimestampIsAccepted() {
        var session = codexSession()
        let result = AppState.applyCodexAsyncQuestionSignal(
            .pending(prompt: "Q", askedAt: nil),
            to: &session
        )
        XCTAssertEqual(result, .markedPending(fresh: true))
    }

    func testNonCodexSessionIgnoresSignal() {
        var session = codexSession()
        session.source = "claude"
        let result = AppState.applyCodexAsyncQuestionSignal(
            .pending(prompt: "Q", askedAt: Date()),
            to: &session
        )
        XCTAssertEqual(result, .ignored)
        XCTAssertNil(session.codexPendingQuestion)
    }

    func testClearedRemovesQuestionAndIsIgnoredWhenNothingPending() {
        var session = codexSession()
        XCTAssertEqual(AppState.applyCodexAsyncQuestionSignal(.cleared, to: &session), .ignored)

        session.codexPendingQuestion = "Q"
        XCTAssertEqual(AppState.applyCodexAsyncQuestionSignal(.cleared, to: &session), .clearedPending)
        XCTAssertNil(session.codexPendingQuestion)
    }

    // MARK: - applyTranscriptDelta wiring

    func testTranscriptDeltaPendingRaisesReminderCard() {
        let appState = AppState()
        appState.sessions[sessionId] = codexSession(status: .running)

        appState.applyTranscriptDelta(pendingDelta("Which DB?"))

        XCTAssertEqual(appState.sessions[sessionId]?.codexPendingQuestion, "Which DB?")
        XCTAssertEqual(appState.sessions[sessionId]?.status, .running)
        XCTAssertEqual(appState.codexAsyncQuestionCardSessionId, sessionId)
        XCTAssertEqual(appState.surface, .questionCard(sessionId: sessionId))
        XCTAssertTrue(appState.codexAsyncQuestionCardIsShowing)
        XCTAssertEqual(appState.activeSessionId, sessionId)
    }

    func testDismissKeepsRowHintButCollapsesCard() {
        let appState = AppState()
        appState.sessions[sessionId] = codexSession()
        appState.applyTranscriptDelta(pendingDelta("Which DB?"))

        appState.dismissCodexAsyncQuestionCard()

        XCTAssertNil(appState.codexAsyncQuestionCardSessionId)
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.sessions[sessionId]?.codexPendingQuestion, "Which DB?")
        XCTAssertFalse(appState.codexAsyncQuestionCardIsShowing)
    }

    func testClearedDeltaRemovesHintAndCollapsesCard() {
        let appState = AppState()
        appState.sessions[sessionId] = codexSession()
        appState.applyTranscriptDelta(pendingDelta("Which DB?"))

        appState.applyTranscriptDelta(clearedDelta())

        XCTAssertNil(appState.sessions[sessionId]?.codexPendingQuestion)
        XCTAssertNil(appState.codexAsyncQuestionCardSessionId)
        XCTAssertEqual(appState.surface, .collapsed)
    }

    func testReplayOfSameQuestionDoesNotReopenDismissedCard() {
        let appState = AppState()
        appState.sessions[sessionId] = codexSession()
        appState.applyTranscriptDelta(pendingDelta("Which DB?"))
        appState.dismissCodexAsyncQuestionCard()

        appState.applyTranscriptDelta(pendingDelta("Which DB?"))

        XCTAssertNil(appState.codexAsyncQuestionCardSessionId)
        XCTAssertEqual(appState.surface, .collapsed)
    }

    func testTurnEndKeepsHintWhileCardStaysUp() {
        // The turn can finish with the question still queued (the final message
        // repeats it). Idle status must not erase the reminder.
        let appState = AppState()
        appState.sessions[sessionId] = codexSession(status: .processing)
        appState.applyTranscriptDelta(pendingDelta("Which DB?"))

        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: sessionId,
            lastUserPrompt: nil,
            lastAssistantMessage: "Which DB? Please answer.",
            turnStatus: .idle
        ))

        XCTAssertEqual(appState.sessions[sessionId]?.status, .idle)
        XCTAssertEqual(appState.sessions[sessionId]?.codexPendingQuestion, "Which DB?")
        XCTAssertTrue(appState.codexAsyncQuestionCardIsShowing)
    }

    func testStaleReplayDoesNotRaiseCard() {
        let appState = AppState()
        appState.sessions[sessionId] = codexSession()

        appState.applyTranscriptDelta(pendingDelta("Old", askedAt: Date().addingTimeInterval(-3 * 3600)))

        XCTAssertNil(appState.sessions[sessionId]?.codexPendingQuestion)
        XCTAssertNil(appState.codexAsyncQuestionCardSessionId)
        XCTAssertEqual(appState.surface, .collapsed)
    }

    func testCardWaitsBehindInteractiveApproval() throws {
        // A real approval keeps the surface; the reminder is revealed by
        // showNextPending() once the approval resolves.
        let appState = AppState()
        appState.sessions[sessionId] = codexSession()
        let otherId = "claude-session"
        var other = SessionSnapshot()
        other.source = "claude"
        other.status = .waitingApproval
        appState.sessions[otherId] = other
        appState.surface = .approvalCard(sessionId: otherId)

        appState.applyTranscriptDelta(pendingDelta("Which DB?"))

        XCTAssertEqual(appState.codexAsyncQuestionCardSessionId, sessionId)
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: otherId))
        XCTAssertFalse(appState.codexAsyncQuestionCardIsShowing)

        XCTAssertTrue(appState.showNextPending())
        XCTAssertEqual(appState.surface, .questionCard(sessionId: sessionId))
        XCTAssertTrue(appState.codexAsyncQuestionCardIsShowing)
    }

    func testHookActivityDoesNotEraseHint() throws {
        // The turn keeps running after the question: a PreToolUse from the same
        // session must leave the reminder alone (there is nothing to drain).
        let appState = AppState()
        appState.sessions[sessionId] = codexSession(status: .running)
        appState.applyTranscriptDelta(pendingDelta("Which DB?"))

        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PreToolUse",
            "session_id": sessionId,
            "_source": "codex",
            "cwd": "/tmp/OnCue_p-phij",
            "transcript_path": "/tmp/rollout.jsonl",
            "tool_name": "Bash",
            "tool_input": ["command": "swift test"],
            "tool_use_id": "call_9",
        ])
        appState.handleEvent(try XCTUnwrap(HookEvent(from: data)))

        XCTAssertEqual(appState.sessions[sessionId]?.codexPendingQuestion, "Which DB?")
        XCTAssertEqual(appState.codexAsyncQuestionCardSessionId, sessionId)
    }

    func testDeltaIsEmptyTracksCodexSignal() {
        let empty = ConversationTailDelta(sessionId: sessionId, lastUserPrompt: nil, lastAssistantMessage: nil)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(clearedDelta().isEmpty)
    }
}
