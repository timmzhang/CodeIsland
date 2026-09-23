import Foundation
import SwiftUI
import CodeIslandCore

/// Outcome of applying a `CodexAsyncQuestionSignal` to a session snapshot.
enum CodexAsyncQuestionApplication: Equatable {
    /// A queued async question is now recorded on the session. `fresh` is false
    /// when the same question was already recorded (replay / duplicate row).
    case markedPending(fresh: Bool)
    /// The recorded question was answered or superseded by a newer user message.
    case clearedPending
    /// Signal did not apply (not a Codex session, stale row, nothing to clear, …).
    case ignored
}

/// Codex `request_user_input_async` ("Queued follow-up inputs · ⌥↑ to answer").
///
/// The async question tool is the one Codex prompt with no channel into
/// CodeIsland: no hook fires, the app-server sees a plain `item/completed`, and
/// the turn keeps running (and may finish) while the question sits in the TUI
/// queue behind an "Action Required" terminal title. The rollout row is the only
/// signal, so this is a display-only reminder in the Browser Use mould: a card
/// that jumps back to the terminal, plus a hint on the session row that outlives
/// the card until a user message row proves the question was dealt with.
extension AppState {
    /// A question older than this when first seen is treated as stale: the
    /// rollout is replayed whenever a Codex session is (re)attached, and a resumed
    /// thread that ended on an unanswered question days ago has no queue left in
    /// its fresh TUI process to answer from.
    nonisolated static let codexAsyncQuestionMaxAge: TimeInterval = 30 * 60
    /// The card collapses on its own after this long; the row hint stays.
    static let codexAsyncQuestionCardTimeoutNanoseconds: UInt64 = 120_000_000_000

    /// Pure state transition shared by the live tail path and tests.
    nonisolated static func applyCodexAsyncQuestionSignal(
        _ signal: CodexAsyncQuestionSignal,
        to session: inout SessionSnapshot,
        now: Date = Date()
    ) -> CodexAsyncQuestionApplication {
        guard SessionSnapshot.normalizedSupportedSource(session.source) == "codex" else { return .ignored }

        switch signal {
        case .pending(let prompt, let askedAt):
            if let askedAt, now.timeIntervalSince(askedAt) > codexAsyncQuestionMaxAge {
                return .ignored
            }
            let fresh = session.codexPendingQuestion != prompt
            session.codexPendingQuestion = prompt
            session.lastActivity = now
            return .markedPending(fresh: fresh)

        case .cleared:
            guard session.codexPendingQuestion != nil else { return .ignored }
            session.codexPendingQuestion = nil
            session.lastActivity = now
            return .clearedPending
        }
    }

    /// Raise the reminder card for a freshly detected question.
    ///
    /// Interactive cards keep priority: `showNextPending()` reveals this one once
    /// they resolve, as long as the question is still queued. Like the Browser Use
    /// reminder this ignores Smart Suppress: the queue line at the bottom of a busy
    /// Codex TUI is exactly what went unnoticed with the terminal frontmost.
    func presentCodexAsyncQuestionCard(sessionId: String, playSound: Bool = true) {
        guard sessions[sessionId]?.codexPendingQuestion != nil else { return }

        codexAsyncQuestionCardSessionId = sessionId
        activeSessionId = sessionId
        if playSound {
            SoundManager.shared.handleEvent("PermissionRequest")
        }

        switch surface {
        case .approvalCard, .browserUseAttention:
            break
        case .questionCard where pendingQuestion != nil:
            break
        default:
            withAnimation(NotchAnimation.open) {
                surface = .questionCard(sessionId: sessionId)
            }
        }

        codexAsyncQuestionTimeoutTask?.cancel()
        codexAsyncQuestionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: AppState.codexAsyncQuestionCardTimeoutNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.codexAsyncQuestionCardSessionId == sessionId else { return }
            self.clearCodexAsyncQuestionCard(forSessionId: sessionId)
        }
    }

    /// Whether the panel should render the display-only Codex bar for `surface`.
    var codexAsyncQuestionCardIsShowing: Bool {
        guard let sid = codexAsyncQuestionCardSessionId,
              pendingQuestion == nil,
              case .questionCard(let shown) = surface, shown == sid else { return false }
        return sessions[sid]?.codexPendingQuestion != nil
    }

    /// Drop the card (not the row hint) for one session.
    func clearCodexAsyncQuestionCard(forSessionId sessionId: String, showNext: Bool = true) {
        guard codexAsyncQuestionCardSessionId == sessionId else { return }
        codexAsyncQuestionCardSessionId = nil
        codexAsyncQuestionTimeoutTask?.cancel()
        codexAsyncQuestionTimeoutTask = nil
        if showNext, pendingQuestion == nil, case .questionCard(let shown) = surface, shown == sessionId {
            _ = showNextPending()
        }
    }

    func dismissCodexAsyncQuestionCard() {
        guard let sid = codexAsyncQuestionCardSessionId else { return }
        clearCodexAsyncQuestionCard(forSessionId: sid)
    }

    func openCodexAsyncQuestionSession() {
        guard let sid = codexAsyncQuestionCardSessionId else { return }
        if let session = sessions[sid], !session.isRemote {
            TerminalActivator.activate(session: session, sessionId: sid)
        } else {
            SoundManager.shared.preview("8bit_error")
        }
        clearCodexAsyncQuestionCard(forSessionId: sid)
    }
}
