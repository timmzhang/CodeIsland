import XCTest
import CodeIslandCore
@testable import CodeIsland

final class NotchPanelViewTests: XCTestCase {
    func testEffectiveNotchWidthAppliesCollapsedWidthScaleOnNonNotchScreens() {
        XCTAssertEqual(
            NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 50, hasNotch: false),
            100,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 150, hasNotch: false),
            300,
            accuracy: 0.001
        )
    }

    func testEffectiveNotchWidthNeverShrinksUnderPhysicalNotch() {
        XCTAssertEqual(
            NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 50, hasNotch: true),
            200,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 100, hasNotch: true),
            200,
            accuracy: 0.001
        )
    }

    func testEffectiveNotchWidthWidensBeyondPhysicalNotch() {
        XCTAssertEqual(
            NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 150, hasNotch: true),
            300,
            accuracy: 0.001
        )
    }

    func testEffectiveNotchWidthClampsOutOfRangeScale() {
        XCTAssertEqual(
            NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 10, hasNotch: false),
            100,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 250, hasNotch: false),
            300,
            accuracy: 0.001
        )
    }

    func testCompactToolNameKeepsShortNamesUnchanged() {
        XCTAssertEqual(ToolNameDisplay.compact("Bash"), "Bash")
        XCTAssertEqual(ToolNameDisplay.compact("  Read  "), "Read")
    }

    func testCompactToolNameTruncatesLongNamesWithoutLosingSuffix() {
        let compact = ToolNameDisplay.compact("mcp__very_long_server_name__fetch_document_page", maxCharacters: 24)

        XCTAssertLessThanOrEqual(compact.count, 24)
        XCTAssertTrue(compact.hasPrefix("mcp"))
        XCTAssertTrue(compact.hasSuffix("document_page"))
        XCTAssertTrue(compact.contains("..."))
    }

    func testShouldTriggerJumpFailureFeedbackWhenAllAttemptsFail() {
        XCTAssertTrue(shouldTriggerJumpFailureFeedback([false, false, false]))
    }

    func testShouldNotTriggerJumpFailureFeedbackWhenAnyAttemptSucceeds() {
        XCTAssertFalse(shouldTriggerJumpFailureFeedback([false, true, false]))
    }

    func testJumpFailureShakeSequenceUsesFastAlternatingOffsets() {
        XCTAssertEqual(JumpAnimationHelper.shakeSequence, [8, -8, 6, -6, 3, -3, 0])
    }

    func testEvaluateJumpValidationReturnsSuccessWhenCheckSucceeds() async {
        var callCount = 0
        let outcome = await evaluateJumpValidation(
            delays: [1, 1, 1],
            isCancelled: { false },
            sleep: { _ in },
            checkSucceeded: {
                callCount += 1
                return callCount == 2
            }
        )

        XCTAssertEqual(outcome, .success)
    }

    func testEvaluateJumpValidationReturnsFailedWhenAllChecksFail() async {
        let outcome = await evaluateJumpValidation(
            delays: [1, 1, 1],
            isCancelled: { false },
            sleep: { _ in },
            checkSucceeded: { false }
        )

        XCTAssertEqual(outcome, .failed)
    }

    func testEvaluateJumpValidationReturnsCancelledBeforeCheckRuns() async {
        var checksRan = 0
        let outcome = await evaluateJumpValidation(
            delays: [1, 1, 1],
            isCancelled: { true },
            sleep: { _ in },
            checkSucceeded: {
                checksRan += 1
                return false
            }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(checksRan, 0)
    }

    func testClickJumpCollapseTimelineShowsClickRingWhenCursorReachesClickPoint() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.26)

        XCTAssertGreaterThan(timeline.expand, 0.95)
        XCTAssertTrue(timeline.showClickRing)
        XCTAssertEqual(timeline.cursorX, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 0, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineMovesCursorToClickPointFaster() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.08)

        XCTAssertEqual(timeline.cursorX, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 0, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineMovesCursorFullyOffscreenBeforeExpandStarts() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.80)

        XCTAssertEqual(timeline.cursorX, 34, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 28, accuracy: 0.001)
        XCTAssertLessThanOrEqual(timeline.expand, 0.001)
    }

    func testClickJumpCollapseTimelineStartsExpandAfterCursorIsAlreadyOffscreen() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.85)

        XCTAssertGreaterThan(timeline.expand, 0.3)
        XCTAssertEqual(timeline.cursorX, 34, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 28, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineUsesMouseLeaveLikeCollapseSpeed() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.38)

        XCTAssertGreaterThan(timeline.expand, 0.5)
        XCTAssertLessThan(timeline.expand, 0.7)
    }

    func testClickJumpCollapseTimelineUsesMouseLeaveLikeExpandSpeed() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.93)

        XCTAssertGreaterThanOrEqual(timeline.expand, 0.999)
    }

    func testClickJumpCollapseTimelineHoldsCollapsedStateForMiddleWindow() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.60)

        XCTAssertLessThanOrEqual(timeline.expand, 0.001)
        XCTAssertEqual(timeline.cursorX, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 0, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineLoopSeamIsSmooth() {
        let start = clickJumpCollapsePreviewTimeline(progress: 0)
        let end = clickJumpCollapsePreviewTimeline(progress: 1)

        XCTAssertEqual(start.expand, end.expand, accuracy: 0.001)
        XCTAssertEqual(start.cursorX, end.cursorX, accuracy: 0.001)
        XCTAssertEqual(start.cursorY, end.cursorY, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineLowersClickPoint() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.26)
        XCTAssertEqual(timeline.clickPointY, 16.0, accuracy: 0.1)
    }

    func testOrderedSessionListIdsPlacesActiveBeforeIdleAndNewestFirst() {
        let now = Date()
        var oldIdle = SessionSnapshot(startTime: now.addingTimeInterval(-400))
        oldIdle.status = .idle
        oldIdle.lastActivity = now.addingTimeInterval(-300)
        var newestIdle = SessionSnapshot(startTime: now.addingTimeInterval(-200))
        newestIdle.status = .idle
        newestIdle.lastActivity = now.addingTimeInterval(-100)
        var oldActive = SessionSnapshot(startTime: now.addingTimeInterval(-100))
        oldActive.status = .processing
        oldActive.lastActivity = now.addingTimeInterval(-250)

        XCTAssertEqual(
            orderedSessionListIds([
                "idle-old": oldIdle,
                "idle-new": newestIdle,
                "active-old": oldActive,
            ]),
            ["active-old", "idle-new", "idle-old"]
        )
    }

    func testOrderedSessionListIdsPrioritizesWaitingPrompts() {
        let now = Date()
        var running = SessionSnapshot(startTime: now)
        running.status = .running
        running.lastActivity = now
        var waiting = SessionSnapshot(startTime: now.addingTimeInterval(-100))
        waiting.status = .waitingApproval
        waiting.lastActivity = now.addingTimeInterval(-100)

        XCTAssertEqual(
            orderedSessionListIds([
                "running": running,
                "waiting": waiting,
            ]),
            ["waiting", "running"]
        )
    }

    func testClaudePermissionShowsAlwaysAllowOnlyWithNativeSuggestion() throws {
        XCTAssertFalse(permissionSupportsAlwaysAllow(try makePermissionEvent(source: "claude")))
        XCTAssertTrue(permissionSupportsAlwaysAllow(try makePermissionEvent(
            source: "claude",
            extraPayload: [
                "permission_suggestions": [[
                    "type": "addRules",
                    "rules": [["toolName": "Bash", "ruleContent": "pins show *"]],
                    "behavior": "allow",
                    "destination": "localSettings",
                ]]
            ]
        )))
        XCTAssertTrue(permissionSupportsAlwaysAllow(try makePermissionEvent(source: "codex")))
    }

    private func makePermissionEvent(
        source: String,
        extraPayload: [String: Any] = [:]
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_name": "Bash",
            "tool_input": ["command": "echo test"],
            "_source": source,
        ]
        for (key, value) in extraPayload {
            payload[key] = value
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }

    // MARK: - Usage popover retracts the panel body (p-w6c9)

    func testUsagePopoverRetractsSessionListBody() {
        XCTAssertTrue(
            UsagePopoverLayout.showsPanelBody(expanded: true, popoverVisible: false, surface: .sessionList)
        )
        XCTAssertFalse(
            UsagePopoverLayout.showsPanelBody(expanded: true, popoverVisible: true, surface: .sessionList)
        )
        XCTAssertFalse(
            UsagePopoverLayout.showsPanelBody(expanded: true, popoverVisible: true, surface: .completionCard(sessionId: "s1"))
        )
    }

    func testUsagePopoverKeepsPendingDecisionCardsVisible() {
        XCTAssertTrue(
            UsagePopoverLayout.showsPanelBody(expanded: true, popoverVisible: true, surface: .approvalCard(sessionId: "s1"))
        )
        XCTAssertTrue(
            UsagePopoverLayout.showsPanelBody(expanded: true, popoverVisible: true, surface: .questionCard(sessionId: "s1"))
        )
        XCTAssertTrue(
            UsagePopoverLayout.showsPanelBody(expanded: true, popoverVisible: true, surface: .browserUseAttention(sessionId: "s1"))
        )
    }

    /// Clicking the entry opens the detail page with the cursor still resting on
    /// it, so the popover state turns visible again behind the suppressed
    /// overlay. That must not retract the page the click just opened.
    func testUsageDetailPageIsNeverRetracted() {
        XCTAssertTrue(
            UsagePopoverLayout.showsPanelBody(expanded: true, popoverVisible: true, surface: .usageDetail)
        )
    }

    func testCollapsedPanelNeverShowsBody() {
        XCTAssertFalse(
            UsagePopoverLayout.showsPanelBody(expanded: false, popoverVisible: false, surface: .sessionList)
        )
    }

    func testDeferredCollapseFiresWhenCursorLeftThroughPopover() {
        XCTAssertTrue(
            UsagePopoverLayout.collapsesAfterPopoverHidden(
                surface: .sessionList, panelHovered: false, collapseOnMouseLeave: true
            )
        )
    }

    func testDeferredCollapseSkippedWhenCursorIsBackOnPanel() {
        XCTAssertFalse(
            UsagePopoverLayout.collapsesAfterPopoverHidden(
                surface: .sessionList, panelHovered: true, collapseOnMouseLeave: true
            )
        )
    }

    func testDeferredCollapseRespectsCollapseOnMouseLeaveSetting() {
        XCTAssertFalse(
            UsagePopoverLayout.collapsesAfterPopoverHidden(
                surface: .sessionList, panelHovered: false, collapseOnMouseLeave: false
            )
        )
    }

    func testDeferredCollapseSkipsDetailPageAndPendingCards() {
        // Clicking「查看详情」dismisses the popover — that must not collapse the panel.
        XCTAssertFalse(
            UsagePopoverLayout.collapsesAfterPopoverHidden(
                surface: .usageDetail, panelHovered: false, collapseOnMouseLeave: true
            )
        )
        XCTAssertFalse(
            UsagePopoverLayout.collapsesAfterPopoverHidden(
                surface: .approvalCard(sessionId: "s1"), panelHovered: false, collapseOnMouseLeave: true
            )
        )
        XCTAssertFalse(
            UsagePopoverLayout.collapsesAfterPopoverHidden(
                surface: .collapsed, panelHovered: false, collapseOnMouseLeave: true
            )
        )
    }

}

// MARK: - Hover phase state machine (PR #208)

final class NotchHoverInteractionTests: XCTestCase {
    func testQuickPassThroughReversesPrehoverWithoutExpanding() {
        var phase = NotchHoverInteraction.nextPhase(from: .collapsed, event: .mouseEntered)
        XCTAssertEqual(phase, .prehover)

        phase = NotchHoverInteraction.nextPhase(from: phase, event: .mouseExited)
        XCTAssertEqual(phase, .collapsed)

        // The stale expand timer firing after the mouse left must not expand.
        phase = NotchHoverInteraction.nextPhase(from: phase, event: .expandDelayElapsed)
        XCTAssertEqual(phase, .collapsed)
    }

    func testDwellExpandsThenCollapsesAfterLeaveDelay() {
        var phase = NotchHoverInteraction.nextPhase(from: .collapsed, event: .mouseEntered)
        phase = NotchHoverInteraction.nextPhase(from: phase, event: .expandDelayElapsed)
        XCTAssertEqual(phase, .expanded)

        // Leaving alone doesn't collapse an expanded panel — the delay does.
        phase = NotchHoverInteraction.nextPhase(from: phase, event: .mouseExited)
        XCTAssertEqual(phase, .expanded)

        phase = NotchHoverInteraction.nextPhase(from: phase, event: .collapseDelayElapsed)
        XCTAssertEqual(phase, .collapsed)
    }

    func testCollapseDelayWhileNotExpandedIsANoOp() {
        XCTAssertEqual(NotchHoverInteraction.nextPhase(from: .collapsed, event: .collapseDelayElapsed), .collapsed)
        XCTAssertEqual(NotchHoverInteraction.nextPhase(from: .prehover, event: .collapseDelayElapsed), .prehover)
    }

    func testWidthScaleSliderUsesOnePercentSteps() {
        XCTAssertEqual(NotchWidthScale.min, 50)
        XCTAssertEqual(NotchWidthScale.max, 150)
        XCTAssertEqual(NotchWidthScale.step, 1)
    }

    func testEffectiveNotchWidthClampsToSharedBounds() {
        // Physical notch is never scaled.
        XCTAssertEqual(NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 80, hasNotch: true), 200)
        // Simulated notch scales and clamps to NotchWidthScale bounds.
        XCTAssertEqual(NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 75, hasNotch: false), 150)
        XCTAssertEqual(NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 10, hasNotch: false), 100)
        XCTAssertEqual(NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 900, hasNotch: false), 300)
    }
}
