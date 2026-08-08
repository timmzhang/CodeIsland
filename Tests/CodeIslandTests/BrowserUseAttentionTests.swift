import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

@MainActor
final class BrowserUseAttentionTests: XCTestCase {
    func testDetectorRecognizesCodexBrowserUseAndExtractsTarget() throws {
        let event = try makeEvent(
            name: "PreToolUse",
            toolUseId: "exec-browser-1",
            code: #"const tab = await browser.tabs.new(); await tab.goto("http://127.0.0.1:48137/codeisland-browser-poc");"#
        )

        let candidate = try XCTUnwrap(BrowserUseAttentionDetector.candidate(for: event))
        XCTAssertEqual(candidate.toolUseId, "exec-browser-1")
        XCTAssertEqual(candidate.sessionId, "s1")
        XCTAssertEqual(candidate.target, "http://127.0.0.1:48137/codeisland-browser-poc")
        XCTAssertEqual(
            BrowserUseAttentionDetector.displayTarget(candidate.target),
            "127.0.0.1:48137/codeisland-browser-poc"
        )
    }

    func testDetectorRejectsNonBrowserNodeCodeAndNonCodexEvents() throws {
        let plain = try makeEvent(
            name: "PreToolUse",
            toolUseId: "exec-plain",
            code: "nodeRepl.write({ value: 1 })"
        )
        XCTAssertNil(BrowserUseAttentionDetector.candidate(for: plain))

        let otherSource = try makeEvent(
            name: "PreToolUse",
            toolUseId: "exec-other",
            code: "await browser.tabs.list()",
            source: "claude"
        )
        XCTAssertNil(BrowserUseAttentionDetector.candidate(for: otherSource))
    }

    func testAttentionAppearsAfterDelayAndPostToolUseClearsIt() async throws {
        let state = AppState()
        state.sessions["s1"] = codexSession()
        let pre = try makeEvent(
            name: "PreToolUse",
            toolUseId: "exec-browser-2",
            code: "await agent.browsers.getForUrl(\"https://example.com/path\")"
        )
        state.cachePreToolUseIfApplicable(pre)
        state.updateBrowserUseAttention(for: pre, delayNanoseconds: 0, playSound: false)
        try await Task.sleep(nanoseconds: 2_000_000)

        XCTAssertEqual(state.browserUseAttention?.toolUseId, "exec-browser-2")
        XCTAssertEqual(state.surface, .browserUseAttention(sessionId: "s1"))

        let post = try makeEvent(
            name: "PostToolUse",
            toolUseId: "exec-browser-2",
            code: nil
        )
        state.updateBrowserUseAttention(for: post)

        XCTAssertNil(state.browserUseAttention)
        XCTAssertEqual(state.surface, .collapsed)
    }

    func testStopCancelsCandidateBeforeItCanAppear() async throws {
        let state = AppState()
        state.sessions["s1"] = codexSession()
        let pre = try makeEvent(
            name: "PreToolUse",
            toolUseId: "exec-browser-3",
            code: "await browser.user.openTabs()"
        )
        state.cachePreToolUseIfApplicable(pre)
        state.updateBrowserUseAttention(for: pre, delayNanoseconds: 20_000_000, playSound: false)
        state.updateBrowserUseAttention(
            for: try makeEvent(name: "Stop", toolUseId: nil, code: nil)
        )
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertNil(state.browserUseAttention)
        XCTAssertNil(state.pendingToolUses["exec-browser-3"])
    }

    func testStopClearsVisibleAttentionAndItsCachedToolUse() async throws {
        let state = AppState()
        state.sessions["s1"] = codexSession()
        let pre = try makeEvent(
            name: "PreToolUse",
            toolUseId: "exec-browser-visible-stop",
            code: "await browser.tabs.list()"
        )
        state.cachePreToolUseIfApplicable(pre)
        state.updateBrowserUseAttention(for: pre, delayNanoseconds: 0, playSound: false)
        try await Task.sleep(nanoseconds: 2_000_000)

        XCTAssertNotNil(state.browserUseAttention)
        XCTAssertNotNil(state.pendingToolUses["exec-browser-visible-stop"])

        state.updateBrowserUseAttention(
            for: try makeEvent(name: "Stop", toolUseId: nil, code: nil)
        )

        XCTAssertNil(state.browserUseAttention)
        XCTAssertNil(state.pendingToolUses["exec-browser-visible-stop"])
        XCTAssertEqual(state.surface, .collapsed)
    }

    func testTranscriptToolCallEndClearsVisibleAttentionWithoutPostToolUse() {
        let state = AppState()
        state.sessions["s1"] = codexSession()
        state.browserUseAttention = BrowserUseAttention(
            toolUseId: "exec-browser-4",
            sessionId: "s1",
            target: nil,
            detectedAt: Date()
        )
        state.surface = .browserUseAttention(sessionId: "s1")
        state.pendingToolUses["exec-browser-4"] = PreToolUseRecord(
            sessionId: "s1",
            toolName: BrowserUseAttentionDetector.toolName,
            toolDescription: nil,
            toolInput: nil,
            receivedAt: Date()
        )

        state.applyTranscriptDelta(ConversationTailDelta(
            sessionId: "s1",
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            completedToolCallIds: ["exec-browser-4"]
        ))

        XCTAssertNil(state.browserUseAttention)
        XCTAssertNil(state.pendingToolUses["exec-browser-4"])
        XCTAssertEqual(state.surface, .collapsed)
    }

    private func codexSession() -> SessionSnapshot {
        var session = SessionSnapshot()
        session.source = "codex"
        session.status = .running
        session.cwd = "/tmp/browser-use"
        return session
    }

    private func makeEvent(
        name: String,
        toolUseId: String?,
        code: String?,
        source: String = "codex"
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": name,
            "session_id": "s1",
            "tool_name": BrowserUseAttentionDetector.toolName,
            "_source": source
        ]
        if let toolUseId { payload["tool_use_id"] = toolUseId }
        if let code { payload["tool_input"] = ["code": code] }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}
