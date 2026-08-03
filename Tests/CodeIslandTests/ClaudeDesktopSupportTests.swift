import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Claude Desktop's hook subprocesses inherit
/// `__CFBundleIdentifier=com.anthropic.claudefordesktop`. These regressions
/// ensure the resulting Claude session follows native-app lifecycle and
/// visibility rules instead of being treated as a terminal CLI session.
@MainActor
final class ClaudeDesktopSupportTests: XCTestCase {
    private func makeSession(termBundleId: String?, source: String) -> SessionSnapshot {
        var session = SessionSnapshot()
        session.source = source
        session.termBundleId = termBundleId
        return session
    }

    func testDesktopClaudeSessionIsNativeAppMode() {
        let session = makeSession(
            termBundleId: "com.anthropic.claudefordesktop",
            source: "claude"
        )

        XCTAssertTrue(session.isNativeAppMode)
        XCTAssertFalse(session.isIDETerminal)
        XCTAssertEqual(session.terminalName, "Claude")
    }

    func testTerminalClaudeSessionIsNotNativeAppMode() {
        let session = makeSession(termBundleId: "com.googlecode.iterm2", source: "claude")
        XCTAssertFalse(session.isNativeAppMode)
    }

    func testNonClaudeSourceInsideClaudeDesktopIsNotNativeAppMode() {
        let session = makeSession(
            termBundleId: "com.anthropic.claudefordesktop",
            source: "codex"
        )
        XCTAssertFalse(session.isNativeAppMode)
    }

    func testClickJumpDoesNotStealTerminalClaudeSessions() {
        XCTAssertNil(TerminalActivator.sourceToNativeAppBundleId["claude"])
    }

    func testDesktopAskUserQuestionOpensQuestionCard() async throws {
        let appState = AppState()
        let sessionId = "claude-desktop-question"
        appState.sessions[sessionId] = makeSession(
            termBundleId: "com.anthropic.claudefordesktop",
            source: "claude"
        )

        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [[
                    "header": "列名",
                    "question": "「判定」列改叫什么？",
                    "multiSelect": false,
                    "options": [[
                        "label": "结论 + 说明",
                        "description": "图标列叫结论，文字列改叫说明。",
                    ]],
                ]],
            ],
            "_source": "claude",
            "_term_bundle_id": "com.anthropic.claudefordesktop",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }
        await Task.yield()

        XCTAssertEqual(appState.questionQueue.count, 1)
        XCTAssertEqual(appState.surface, .questionCard(sessionId: sessionId))

        appState.skipQuestion()
        _ = await responseTask.value
    }
}
