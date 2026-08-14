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
        state.browserUseOriginPolicyProvider = { _ in .empty }
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
        state.browserUseOriginPolicyProvider = { _ in .empty }
        let pre = try makeEvent(
            name: "PreToolUse",
            toolUseId: "exec-browser-3",
            code: #"await browser.tabs.new(); await tab.goto("https://example.com/a");"#
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
        state.browserUseOriginPolicyProvider = { _ in .empty }
        let pre = try makeEvent(
            name: "PreToolUse",
            toolUseId: "exec-browser-visible-stop",
            code: #"await browser.tabs.new(); await tab.goto("https://example.com/b");"#
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
        state.browserUseOriginPolicyProvider = { _ in .empty }
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

    // MARK: - Origin policy

    func testOriginPolicyParsesBothArrayShapesAndNormalizesPorts() {
        let policy = BrowserUseOriginPolicy.parse("""
        [origins]
        allowed = [
            "http://127.0.0.1:5195",
            "https://tq.bytedance.net",  # trailing comment
        ]
        denied = ["http://localhost:48137/"]

        [other]
        allowed = ["http://not-origins.example"]
        """)

        XCTAssertEqual(policy.decision(forURL: "http://127.0.0.1:5195/gmail-ops?tab=list"), .allowed)
        XCTAssertEqual(policy.decision(forURL: "https://tq.bytedance.net:443/x"), .allowed)
        XCTAssertEqual(policy.decision(forURL: "http://localhost:48137/poc"), .denied)
        XCTAssertEqual(policy.decision(forURL: "http://not-origins.example"), .unknown)
        XCTAssertEqual(policy.decision(forURL: "http://127.0.0.1:5196/"), .unknown)
        XCTAssertEqual(policy.decision(forURL: nil), .unknown)
    }

    func testTriggerClassificationDrivesTheDelay() throws {
        let state = AppState()
        state.sessions["s1"] = codexSession()
        state.browserUseOriginPolicyProvider = { _ in
            BrowserUseOriginPolicy.parse("""
            [origins]
            allowed = ["http://127.0.0.1:5195"]
            """)
        }

        func attention(_ id: String, _ navigation: BrowserUseNavigation) -> BrowserUseAttention {
            var url: String?
            if case .direct(let value) = navigation { url = value }
            return BrowserUseAttention(
                toolUseId: id,
                sessionId: "s1",
                target: url,
                detectedAt: Date(),
                navigation: navigation
            )
        }

        XCTAssertEqual(
            state.browserUseAttentionTrigger(
                for: attention("a", .direct(url: "http://127.0.0.1:5195/x"))
            ),
            .settledOrigin
        )
        XCTAssertEqual(
            state.browserUseAttentionTrigger(
                for: attention("b", .direct(url: "http://127.0.0.1:9999/x"))
            ),
            .undecidedOrigin
        )
        XCTAssertEqual(
            state.browserUseAttentionTrigger(for: attention("c", .direct(url: nil))),
            .unresolvedOrigin
        )
        XCTAssertEqual(state.browserUseAttentionTrigger(for: attention("d", .indirect)), .indirectNavigation)
        XCTAssertEqual(state.browserUseAttentionTrigger(for: attention("e", .none)), .noNavigation)

        XCTAssertNil(BrowserUseAttentionDetector.delayNanoseconds(for: .settledOrigin))
        XCTAssertNil(BrowserUseAttentionDetector.delayNanoseconds(for: .noNavigation))
        XCTAssertEqual(
            BrowserUseAttentionDetector.delayNanoseconds(for: .undecidedOrigin),
            BrowserUseAttentionDetector.undecidedOriginDelayNanoseconds
        )
        XCTAssertEqual(
            BrowserUseAttentionDetector.delayNanoseconds(for: .unresolvedOrigin),
            BrowserUseAttentionDetector.unresolvedOriginDelayNanoseconds
        )
        XCTAssertEqual(
            BrowserUseAttentionDetector.delayNanoseconds(for: .indirectNavigation),
            BrowserUseAttentionDetector.indirectNavigationDelayNanoseconds
        )
    }

    // MARK: - Call shape

    func testOnlyNavigatingCodeCanRaiseTheOriginPrompt() {
        // The 2026-08-14 false alarm: a URL passed to fetch() inside the page, with
        // nothing navigating anywhere.
        let inPageFetch = BrowserUseCallShape.read("""
        nodeRepl.write(await ticketTab.playwright.evaluate(async () => {
          const res = await fetch("https://ti-platform.lark-us.net/api/v1/ticket/462/");
          return res.status;
        }));
        """)
        XCTAssertEqual(inPageFetch.navigation, .none)

        XCTAssertEqual(
            BrowserUseCallShape.read("nodeRepl.write(await bizTab.playwright.domSnapshot());").navigation,
            .none
        )
        // A blank tab is not a destination; the goto that follows is.
        XCTAssertEqual(
            BrowserUseCallShape.read("globalThis.tab = await browser.tabs.new();").navigation,
            .none
        )
        // reload/goBack revisit an origin the browser is already allowed to be on.
        XCTAssertEqual(
            BrowserUseCallShape.read("await bitsTab.reload(); await bitsTab.goBack();").navigation,
            .none
        )
    }

    func testNavigationShapeDistinguishesLiteralVariableAndClickDestinations() {
        XCTAssertEqual(
            BrowserUseCallShape.read(
                #"globalThis.tab = await browser.tabs.new(); await tab.goto("http://127.0.0.1:5195/gmail-ops");"#
            ).navigation,
            .direct(url: "http://127.0.0.1:5195/gmail-ops")
        )
        XCTAssertEqual(
            BrowserUseCallShape.read(#"await browser.tabs.new({ url: "https://example.com/x" });"#).navigation,
            .direct(url: "https://example.com/x")
        )
        XCTAssertEqual(
            BrowserUseCallShape.read("await tab.goto(dashboardUrl);").navigation,
            .direct(url: nil)
        )
        XCTAssertEqual(
            BrowserUseCallShape.read(
                #"await bitsTab.playwright.getByRole('link',{name:/orca/}).click();"#
            ).navigation,
            .indirect
        )
    }

    func testDeclaredWaitsAreSummedAndCapped() {
        XCTAssertEqual(
            BrowserUseCallShape.read(
                "await new Promise(r=>setTimeout(r,28000)); await t.reload(); await t.playwright.waitForTimeout(3000);"
            ).declaredWait,
            31,
            accuracy: 0.001
        )
        // Sub-100ms tweaks are noise, not a budget.
        XCTAssertEqual(
            BrowserUseCallShape.read("await t.playwright.waitForTimeout(50);").declaredWait,
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            BrowserUseCallShape.read("await t.playwright.waitForTimeout(600000);").declaredWait,
            BrowserUseCallShape.maxDeclaredWait,
            accuracy: 0.001
        )
    }

    func testDeclaredWaitsExtendTheWeakTriggersOnly() {
        XCTAssertEqual(
            BrowserUseAttentionDetector.delayNanoseconds(for: .indirectNavigation, declaredWait: 28),
            BrowserUseAttentionDetector.indirectNavigationDelayNanoseconds + 28_000_000_000
        )
        XCTAssertEqual(
            BrowserUseAttentionDetector.delayNanoseconds(for: .unresolvedOrigin, declaredWait: 5),
            BrowserUseAttentionDetector.unresolvedOriginDelayNanoseconds + 5_000_000_000
        )
        // A fresh origin in the source blocks the navigation up front, so waits the
        // script schedules afterwards must not hold the card back.
        XCTAssertEqual(
            BrowserUseAttentionDetector.delayNanoseconds(for: .undecidedOrigin, declaredWait: 28),
            BrowserUseAttentionDetector.undecidedOriginDelayNanoseconds
        )
    }

    func testCallThatCannotNavigateNeverRaisesTheCard() async throws {
        let state = AppState()
        state.sessions["s1"] = codexSession()
        state.browserUseOriginPolicyProvider = { _ in .empty }

        let pre = try makeEvent(
            name: "PreToolUse",
            toolUseId: "exec-browser-in-page-fetch",
            code: #"""
            nodeRepl.write(await ticketTab.playwright.evaluate(async () => {
              const res = await fetch("https://ti-platform.lark-us.net/api/v1/ticket/462/");
              return res.status;
            }));
            """#
        )
        state.cachePreToolUseIfApplicable(pre)
        // Even with the delay forced to zero — the suppression is about what the call
        // can do, not about how long it takes.
        state.updateBrowserUseAttention(for: pre, delayNanoseconds: 0, playSound: false)
        try await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertNil(state.browserUseAttention)
        XCTAssertTrue(state.browserUseAttentionDelayTasks.isEmpty)
        XCTAssertEqual(state.surface, .collapsed)
    }

    func testAlreadyAllowedOriginNeverRaisesTheCard() async throws {
        let state = AppState()
        state.sessions["s1"] = codexSession()
        state.browserUseOriginPolicyProvider = { threadId in
            XCTAssertEqual(threadId, "s1")
            return BrowserUseOriginPolicy.parse("""
            [origins]
            allowed = ["http://127.0.0.1:5195"]
            """)
        }

        let pre = try makeEvent(
            name: "PreToolUse",
            toolUseId: "exec-browser-allowed",
            code: #"globalThis.tab = await browser.tabs.new(); await tab.goto("http://127.0.0.1:5195/gmail-ops");"#
        )
        state.cachePreToolUseIfApplicable(pre)
        state.updateBrowserUseAttention(for: pre, playSound: false)
        try await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertNil(state.browserUseAttention)
        XCTAssertTrue(state.browserUseAttentionDelayTasks.isEmpty)
        XCTAssertEqual(state.surface, .collapsed)
    }

    func testDeniedOriginNeverRaisesTheCard() async throws {
        let state = AppState()
        state.sessions["s1"] = codexSession()
        state.browserUseOriginPolicyProvider = { _ in
            BrowserUseOriginPolicy.parse("""
            [origins]
            denied = ["http://127.0.0.1:48137"]
            """)
        }

        let pre = try makeEvent(
            name: "PreToolUse",
            toolUseId: "exec-browser-denied",
            code: #"await agent.browsers.getForUrl("http://127.0.0.1:48137/poc");"#
        )
        state.cachePreToolUseIfApplicable(pre)
        state.updateBrowserUseAttention(for: pre, playSound: false)
        try await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertNil(state.browserUseAttention)
        XCTAssertEqual(state.surface, .collapsed)
    }

    func testOriginAnsweredDuringTheDelayWindowSuppressesTheCard() async throws {
        let state = AppState()
        state.sessions["s1"] = codexSession()
        var answered = false
        state.browserUseOriginPolicyProvider = { _ in
            answered
                ? BrowserUseOriginPolicy.parse("""
                  [origins]
                  allowed = ["http://127.0.0.1:9999"]
                  """)
                : .empty
        }

        let pre = try makeEvent(
            name: "PreToolUse",
            toolUseId: "exec-browser-answered",
            code: #"await agent.browsers.getForUrl("http://127.0.0.1:9999/app");"#
        )
        state.cachePreToolUseIfApplicable(pre)
        state.updateBrowserUseAttention(for: pre, delayNanoseconds: 30_000_000, playSound: false)
        answered = true
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertNil(state.browserUseAttention)
        XCTAssertEqual(state.surface, .collapsed)
    }

    func testUndecidedOriginStillRaisesTheCard() async throws {
        let state = AppState()
        state.sessions["s1"] = codexSession()
        state.browserUseOriginPolicyProvider = { _ in .empty }

        let pre = try makeEvent(
            name: "PreToolUse",
            toolUseId: "exec-browser-new-origin",
            code: #"await agent.browsers.getForUrl("http://127.0.0.1:9999/app");"#
        )
        state.cachePreToolUseIfApplicable(pre)
        state.updateBrowserUseAttention(for: pre, delayNanoseconds: 0, playSound: false)
        try await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertEqual(state.browserUseAttention?.toolUseId, "exec-browser-new-origin")
        XCTAssertEqual(state.surface, .browserUseAttention(sessionId: "s1"))
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
