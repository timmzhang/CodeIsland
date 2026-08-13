import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

@MainActor
final class AppStateCodexAppServerTests: XCTestCase {
    func testCodexExecutablePathRecognizesChatGPTDesktopBundle() {
        XCTAssertTrue(AppState.isCodexExecutablePath(
            "/Applications/ChatGPT.app/Contents/Resources/codex"
        ))
    }

    func testCodexExecutablePathRejectsUnrelatedResourceBinary() {
        XCTAssertFalse(AppState.isCodexExecutablePath(
            "/Applications/OtherAgent.app/Contents/Resources/codex"
        ))
    }

    func testCodexDiscoveryUsesTranscriptCwdForDesktopProcess() {
        XCTAssertTrue(AppState.codexDiscoveryUsesTranscriptCwd(processCwd: nil))
        XCTAssertTrue(AppState.codexDiscoveryUsesTranscriptCwd(processCwd: "/"))
        XCTAssertFalse(AppState.codexDiscoveryUsesTranscriptCwd(
            processCwd: "/Users/haoo/Documents/project"
        ))
    }

    func testCodexPlaceholderHookIsIgnoredButProjectHookIsKept() {
        XCTAssertTrue(AppState.isCodexPlaceholderHook(
            source: "codex",
            cwd: "/",
            hasTranscriptPath: false
        ))
        XCTAssertTrue(AppState.isCodexPlaceholderHook(
            source: "codex",
            cwd: nil,
            hasTranscriptPath: false
        ))
        XCTAssertFalse(AppState.isCodexPlaceholderHook(
            source: "codex",
            cwd: "/Users/haoo/Documents/project",
            hasTranscriptPath: false
        ))
        XCTAssertFalse(AppState.isCodexPlaceholderHook(
            source: "codex",
            cwd: "/",
            hasTranscriptPath: true
        ))
    }

    func testCodexTranscriptCwdReadsLargeSessionMetaLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-meta-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let payload: [String: Any] = [
            "cwd": "/Users/haoo/Documents/project",
            "instructions": String(repeating: "x", count: 10_000),
        ]
        let object: [String: Any] = ["type": "session_meta", "payload": payload]
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try data.write(to: url)

        XCTAssertEqual(
            AppState.codexSessionCwd(path: url.path),
            "/Users/haoo/Documents/project"
        )
    }

    func testCodexAppServerExecutablePrefersRunningBundlePath() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("codeisland-codex-app-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("Nested/Codex.app", isDirectory: true)
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let bundledExecutable = resourcesURL.appendingPathComponent("codex")
        try makeExecutable(at: bundledExecutable)

        let fallbackExecutable = tempDir.appendingPathComponent("fallback-codex")
        try makeExecutable(at: fallbackExecutable)

        let resolved = AppState.codexAppServerExecutableURL(
            runningBundleURLs: [bundleURL],
            fallbackPaths: [fallbackExecutable.path],
            fileManager: fm
        )

        XCTAssertEqual(resolved?.path, bundledExecutable.path)
    }

    func testCodexAppServerExecutableFallsBackWhenNoRunningBundlePathExists() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("codeisland-codex-app-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }

        let fallbackExecutable = tempDir.appendingPathComponent("fallback-codex")
        try makeExecutable(at: fallbackExecutable)

        let resolved = AppState.codexAppServerExecutableURL(
            runningBundleURLs: [],
            fallbackPaths: [fallbackExecutable.path],
            fileManager: fm
        )

        XCTAssertEqual(resolved?.path, fallbackExecutable.path)
    }

    func testActiveWithApprovalFlagMapsToWaitingApproval() {
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([.string("waitingOnApproval")])
        ])

        XCTAssertEqual(snapshot.status, .waitingApproval)
    }

    func testActiveWithUserInputFlagMapsToWaitingQuestion() {
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([.string("waitingOnUserInput")])
        ])

        XCTAssertEqual(snapshot.status, .waitingQuestion)
    }

    func testActiveWithoutFlagsMapsToProcessingAndClearsTool() {
        var snapshot = SessionSnapshot()
        snapshot.status = .waitingApproval
        snapshot.currentTool = "Bash"
        snapshot.toolDescription = "pending"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([])
        ])

        XCTAssertEqual(snapshot.status, .processing)
        XCTAssertNil(snapshot.currentTool)
        XCTAssertNil(snapshot.toolDescription)
    }

    func testIdleMapsToIdleAndClearsTool() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        snapshot.currentTool = "Read"
        snapshot.toolDescription = "foo.swift"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("idle")
        ])

        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertNil(snapshot.currentTool)
        XCTAssertNil(snapshot.toolDescription)
    }

    func testNotLoadedAndSystemErrorMapToIdle() {
        var s1 = SessionSnapshot()
        s1.status = .running
        AppState.applyCodexThreadStatus(&s1, status: ["type": .string("notLoaded")])
        XCTAssertEqual(s1.status, .idle)

        var s2 = SessionSnapshot()
        s2.status = .running
        AppState.applyCodexThreadStatus(&s2, status: ["type": .string("systemError")])
        XCTAssertEqual(s2.status, .idle)
    }

    func testUnknownStatusTypeIsNoOp() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        snapshot.currentTool = "Bash"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("futureEnumCaseTBD")
        ])

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.currentTool, "Bash")
    }

    func testNilStatusIsNoOp() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        AppState.applyCodexThreadStatus(&snapshot, status: nil)
        XCTAssertEqual(snapshot.status, .running)
    }

    func testApprovalFlagTakesPrecedenceOverUserInputFlag() {
        // Codex can theoretically emit both flags at once; approval is strictly
        // more actionable, so we should route to .waitingApproval.
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([
                .string("waitingOnUserInput"),
                .string("waitingOnApproval")
            ])
        ])

        XCTAssertEqual(snapshot.status, .waitingApproval)
    }

    // MARK: - Approval answered in Codex's own UI

    /// The user answered the approval in Codex itself, so the thread leaves
    /// `waitingOnApproval`. That notification is the ONLY timely signal we get — the
    /// hook channel stays silent until the approved tool finishes — so the mirror card
    /// has to be released right here instead of lingering for the rest of the turn.
    func testThreadLeavingWaitingOnApprovalDismissesMirrorCard() async throws {
        let appState = AppState()
        appState.handleCodexAppServerMessage(makeThreadStarted(threadId: "t-1", waitingOnApproval: true))
        XCTAssertEqual(appState.sessions["codexapp:t-1"]?.status, .waitingApproval)

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(
                    try! self.makeCodexPermissionEvent(sessionId: "t-1"),
                    continuation: cont
                )
            }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.handleCodexAppServerMessage(makeStatusChanged(threadId: "t-1", waitingOnApproval: false))

        // Released with an empty hook response: the status flag says the approval is
        // over but not which way it went, so we must not assert allow or deny.
        let response = await responseTask.value
        XCTAssertEqual(String(data: response, encoding: .utf8), "{}")
        XCTAssertTrue(appState.permissionQueue.isEmpty)
        XCTAssertEqual(appState.sessions["codexapp:t-1"]?.status, .processing)
        if case .approvalCard = appState.surface {
            XCTFail("stale approval card should have collapsed")
        }
    }

    /// A status notification that was never preceded by `waitingOnApproval` says
    /// nothing about our card — a live prompt must survive it.
    func testStatusChangeWithoutPriorApprovalWaitKeepsCard() async throws {
        let appState = AppState()
        appState.handleCodexAppServerMessage(makeThreadStarted(threadId: "t-2", waitingOnApproval: false))

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(
                    try! self.makeCodexPermissionEvent(sessionId: "t-2"),
                    continuation: cont
                )
            }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.handleCodexAppServerMessage(makeStatusChanged(threadId: "t-2", waitingOnApproval: false))

        XCTAssertEqual(appState.permissionQueue.count, 1)
        responseTask.cancel()
        appState.denyPermission()
        _ = await responseTask.value
    }

    /// Threads are independent: resolving one must not drain another's card.
    func testApprovalResolvedOnOneThreadLeavesOtherThreadsCard() async throws {
        let appState = AppState()
        appState.handleCodexAppServerMessage(makeThreadStarted(threadId: "t-a", waitingOnApproval: true))
        appState.handleCodexAppServerMessage(makeThreadStarted(threadId: "t-b", waitingOnApproval: true))

        let taskA = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(
                    try! self.makeCodexPermissionEvent(sessionId: "t-a"),
                    continuation: cont
                )
            }
        }
        await Task.yield()
        let taskB = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(
                    try! self.makeCodexPermissionEvent(sessionId: "t-b"),
                    continuation: cont
                )
            }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 2)

        appState.handleCodexAppServerMessage(makeStatusChanged(threadId: "t-a", waitingOnApproval: false))

        let responseA = await taskA.value
        XCTAssertEqual(String(data: responseA, encoding: .utf8), "{}")
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.permissionQueue.first?.event.sessionId, "t-b")

        appState.handleCodexAppServerMessage(makeStatusChanged(threadId: "t-b", waitingOnApproval: false))
        let responseB = await taskB.value
        XCTAssertEqual(String(data: responseB, encoding: .utf8), "{}")
        XCTAssertTrue(appState.permissionQueue.isEmpty)
    }

    private func makeCodexPermissionEvent(sessionId: String) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "Bash",
            "tool_input": ["command": "echo hi"],
            "_source": "codex",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }

    private func makeThreadStarted(threadId: String, waitingOnApproval: Bool) -> CodexJSONRPCMessage {
        makeNotification(method: "thread/started", params: [
            "thread": [
                "id": threadId,
                "cwd": "/Users/haoo/Documents/project",
                "status": statusPayload(waitingOnApproval: waitingOnApproval),
            ],
        ])
    }

    private func makeStatusChanged(threadId: String, waitingOnApproval: Bool) -> CodexJSONRPCMessage {
        makeNotification(method: "thread/status/changed", params: [
            "threadId": threadId,
            "status": statusPayload(waitingOnApproval: waitingOnApproval),
        ])
    }

    private func statusPayload(waitingOnApproval: Bool) -> [String: Any] {
        [
            "type": "active",
            "activeFlags": waitingOnApproval ? ["waitingOnApproval"] : [],
        ]
    }

    private func makeNotification(method: String, params: [String: Any]) -> CodexJSONRPCMessage {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return CodexAppServerClient.parseMessage(data)!
    }

    private func makeExecutable(at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
