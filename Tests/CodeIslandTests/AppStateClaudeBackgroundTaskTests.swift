import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateClaudeBackgroundTaskTests: XCTestCase {
    func testStopReadsRecentTranscriptBeforeDeclaringCompletion() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-claude-stop-race-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let started = #"{"type":"user","toolUseResult":{"backgroundTaskId":"bg-race"}}"#
        try Data((started + "\n").utf8).write(to: url)

        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "s1",
            "_source": "claude",
            "transcript_path": url.path,
        ]
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
        let appState = AppState()

        appState.handleEvent(event)

        XCTAssertEqual(appState.sessions["s1"]?.status, .running)
        XCTAssertEqual(appState.sessions["s1"]?.activeBackgroundTaskIds, ["bg-race"])
        XCTAssertEqual(appState.sessions["s1"]?.isWaitingForBackgroundTasks, true)
    }

    func testLateTranscriptStartRevivesSessionAfterStopRace() {
        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        session.status = .idle
        appState.sessions["s1"] = session

        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: "s1",
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            startedBackgroundTaskIds: ["bg-1"],
            hasActivity: true
        ))

        XCTAssertEqual(appState.sessions["s1"]?.status, .running)
        XCTAssertEqual(appState.sessions["s1"]?.activeBackgroundTaskIds, ["bg-1"])
        XCTAssertEqual(appState.sessions["s1"]?.isWaitingForBackgroundTasks, true)
        XCTAssertEqual(appState.sessions["s1"]?.currentTool, "Bash")
    }

    func testColdScanSuppressesCompletionWhenBackgroundStartFallsOutsideRecentTail() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-claude-deep-stop-race-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let started = #"{"type":"user","toolUseResult":{"backgroundTaskId":"bg-deep"}}"#
        let filler = String(repeating: "x", count: 600 * 1024)
        let ignored = #"{"type":"progress","data":"\#(filler)"}"#
        try Data((started + "\n" + ignored + "\n").utf8).write(to: url)

        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "s1",
            "_source": "claude",
            "transcript_path": url.path,
        ]
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
        let defaults = UserDefaults.standard
        let previousStyle = defaults.object(forKey: SettingsKey.completionNotificationStyle)
        defaults.set("expand", forKey: SettingsKey.completionNotificationStyle)
        defer {
            if let previousStyle {
                defaults.set(previousStyle, forKey: SettingsKey.completionNotificationStyle)
            } else {
                defaults.removeObject(forKey: SettingsKey.completionNotificationStyle)
            }
        }
        let appState = AppState()

        appState.handleEvent(event)

        XCTAssertEqual(appState.sessions["s1"]?.status, .running)
        XCTAssertEqual(appState.sessions["s1"]?.activeBackgroundTaskIds, ["bg-deep"])
        XCTAssertNil(appState.justCompletedSessionId)
    }

    func testLastBackgroundTaskCompletionResumesProcessing() {
        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        session.status = .running
        session.currentTool = "Bash"
        session.toolDescription = "Background shell"
        session.activeBackgroundTaskIds = ["bg-1"]
        session.isWaitingForBackgroundTasks = true
        appState.sessions["s1"] = session

        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: "s1",
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            finishedBackgroundTaskIds: ["bg-1"],
            hasActivity: true
        ))

        XCTAssertEqual(appState.sessions["s1"]?.status, .processing)
        XCTAssertTrue(appState.sessions["s1"]?.activeBackgroundTaskIds.isEmpty == true)
        XCTAssertEqual(appState.sessions["s1"]?.isWaitingForBackgroundTasks, false)
        XCTAssertNil(appState.sessions["s1"]?.currentTool)
    }

    func testOneCompletionKeepsOtherBackgroundShellActive() {
        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        session.status = .running
        session.activeBackgroundTaskIds = ["bg-1", "bg-2"]
        session.isWaitingForBackgroundTasks = true
        appState.sessions["s1"] = session

        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: "s1",
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            finishedBackgroundTaskIds: ["bg-1"],
            hasActivity: true
        ))

        XCTAssertEqual(appState.sessions["s1"]?.status, .running)
        XCTAssertEqual(appState.sessions["s1"]?.activeBackgroundTaskIds, ["bg-2"])
        XCTAssertEqual(appState.sessions["s1"]?.isWaitingForBackgroundTasks, true)
    }

    func testBackgroundCompletionDoesNotDismissPermissionWait() {
        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        session.status = .waitingApproval
        session.currentTool = "Bash"
        session.activeBackgroundTaskIds = ["bg-1"]
        session.isWaitingForBackgroundTasks = true
        appState.sessions["s1"] = session

        appState.applyTranscriptDelta(ConversationTailDelta(
            sessionId: "s1",
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            finishedBackgroundTaskIds: ["bg-1"],
            hasActivity: true
        ))

        XCTAssertEqual(appState.sessions["s1"]?.status, .waitingApproval)
        XCTAssertEqual(appState.sessions["s1"]?.currentTool, "Bash")
        XCTAssertTrue(appState.sessions["s1"]?.activeBackgroundTaskIds.isEmpty == true)
        XCTAssertEqual(appState.sessions["s1"]?.isWaitingForBackgroundTasks, false)
    }

    func testColdScanReconstructsOnlyUnfinishedBackgroundTasks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-claude-background-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let startedOne = #"{"type":"user","toolUseResult":{"backgroundTaskId":"bg-1"}}"#
        let finishedOne = #"{"type":"queue-operation","content":"<task-notification>\n<task-id>bg-1</task-id>\n<status>completed</status>\n</task-notification>"}"#
        let startedTwo = #"{"type":"user","toolUseResult":{"backgroundTaskId":"bg-2"}}"#
        try Data(([startedOne, finishedOne, startedTwo].joined(separator: "\n") + "\n").utf8)
            .write(to: url)

        XCTAssertEqual(AppState.latestClaudeBackgroundTaskIds(path: url.path), ["bg-2"])
    }
}
