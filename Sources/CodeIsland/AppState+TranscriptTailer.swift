import Foundation
import CodeIslandCore

/// Outcome of applying a `CursorQuestionSignal` to a session snapshot.
enum CursorQuestionApplication: Equatable {
    /// Session is now display-waiting on a Cursor-side question.
    /// `fresh` is false when it was already waiting (prompt refresh only).
    case markedWaiting(fresh: Bool)
    /// A previously pending question was superseded; normal flow resumed.
    case clearedWaiting
    /// Signal did not apply (wrong source, subagent transcript, approval in flight, …).
    case ignored
}

extension AppState {
    /// Start watching a session's transcript file for appended lines. Safe to call
    /// repeatedly with the same (session, path) pair — the tailer reattaches only
    /// when the path actually changed.
    func attachTranscriptTailerIfNeeded(sessionId: String) {
        guard var session = sessions[sessionId] else { return }
        if session.transcriptPath == nil,
           SessionSnapshot.normalizedSupportedSource(session.source) == "claude",
           let cwd = session.cwd {
            let providerSessionId = session.providerSessionId ?? sessionId
            let inferredPath = NSHomeDirectory()
                + "/.claude/projects/\(cwd.claudeProjectDirEncoded())/\(providerSessionId).jsonl"
            if FileManager.default.fileExists(atPath: inferredPath) {
                session.transcriptPath = inferredPath
                sessions[sessionId] = session
            }
        }

        guard let path = session.transcriptPath, !path.isEmpty else { return }
        if attachedTranscriptPaths[sessionId] == path { return }
        attachedTranscriptPaths[sessionId] = path
        let source = SessionSnapshot.normalizedSupportedSource(session.source)
        let isCodex = source == "codex"

        // Backfill messages from the transcript file so recentMessages is populated
        let (_, messages) = Self.readRecentFromTranscript(path: path)
        if !messages.isEmpty, var session = sessions[sessionId] {
            session.recentMessages = messages
            if let lastUser = messages.last(where: { $0.isUser }) {
                session.lastUserPrompt = lastUser.text
            }
            if let lastAssistant = messages.last(where: { !$0.isUser }) {
                session.lastAssistantMessage = lastAssistant.text
            }
            sessions[sessionId] = session
        }

        // Claude's hook channel has no background-shell lifecycle. Recover the
        // current queue from the existing transcript before attaching at EOF so
        // an app restart cannot briefly show a live background shell as finished.
        if source == "claude", var session = sessions[sessionId] {
            let taskIds = Self.latestClaudeBackgroundTaskIds(path: path)
            session.activeBackgroundTaskIds = taskIds
            if !taskIds.isEmpty, session.status == .idle {
                session.status = .running
                session.currentTool = "Bash"
                session.toolDescription = "Background shell"
                session.isWaitingForBackgroundTasks = true
            }
            sessions[sessionId] = session
        }

        if sessions[sessionId]?.source == "codex",
           let turnStatus = Self.latestCodexTurnStatus(path: path),
           var session = sessions[sessionId] {
            switch turnStatus {
            case .processing:
                session.status = .processing
                session.interrupted = false
                session.taskRoundEnded = false
            case .idle:
                session.status = .idle
                session.currentTool = nil
                session.toolDescription = nil
            }
            if let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                session.lastActivity = modifiedAt
            }
            sessions[sessionId] = session
        }

        // Cursor stuck-question recovery (#265): if the transcript already ends
        // with an unanswered AskQuestion (e.g. CodeIsland launched or the session
        // was discovered while Cursor sat on a question), surface the wait now
        // instead of showing an endless "thinking". Recency-gated so an idle card
        // over a long-abandoned transcript doesn't resurrect as waiting.
        if let session = sessions[sessionId],
           session.source == "cursor" || session.source == "cursor-cli",
           CursorSessionFolding.parentConversationId(fromTranscriptPath: path) == sessionId,
           let signal = Self.latestCursorTailQuestion(path: path) {
            let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            let isRecent = modifiedAt.map { Date().timeIntervalSince($0) < Self.cursorQuestionBackfillMaxAge } ?? false
            let skipStalePending: Bool
            if case .pending = signal, !isRecent {
                skipStalePending = true
            } else {
                skipStalePending = false
            }
            if !skipStalePending, var mutable = sessions[sessionId] {
                if Self.applyCursorQuestionSignal(
                    signal,
                    to: &mutable,
                    sessionId: sessionId,
                    transcriptPath: path
                ) != .ignored {
                    sessions[sessionId] = mutable
                }
            }
        }

        transcriptTailer.attach(
            sessionId: sessionId,
            filePath: path,
            // A Codex file may be discovered after its first turn or after a
            // missed hook. Replay it once, then continue from the retained
            // offset; provider/store dedup makes launch-backfill overlap safe.
            replayExisting: isCodex,
            usageSessionId: session.providerSessionId ?? sessionId,
            codexModel: isCodex ? session.model : nil
        )
    }

    /// Backfill freshness bound for flipping a session into the display-only
    /// question wait from a cold start. Live tail deltas are not age-gated.
    nonisolated static let cursorQuestionBackfillMaxAge: TimeInterval = 30 * 60

    /// Trailing Cursor question state for a whole transcript file, scanned in
    /// bounded chunks (same pattern as `latestCodexTurnStatus`).
    nonisolated static func latestCursorTailQuestion(path: String) -> CursorQuestionSignal? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        handle.seek(toFileOffset: 0)
        let chunkSize = 64 * 1024
        var pendingFragment = Data()
        var latestSignal: CursorQuestionSignal?

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            let result = JSONLTailer.scanLines(pendingFragment + chunk)
            pendingFragment = result.trailingFragment
            if let signal = result.delta.cursorQuestion {
                latestSignal = signal
            }
        }

        return latestSignal
    }

    /// Apply a Cursor trailing-question signal to one session snapshot.
    ///
    /// Pure state transition (no side effects) so both the live tail path and the
    /// attach-time backfill share identical rules, and tests can drive it directly:
    /// - `.pending` flips a **main-agent** Cursor session (transcript parent ==
    ///   session id, so folded Task/subagent transcripts never qualify) into
    ///   `.waitingQuestion` with the question text stored for the card. A real
    ///   approval wait is never stomped.
    /// - `.cleared` erases the stored question; if the session was in the
    ///   display-only wait it resumes as `.processing` (follow-up hooks or tail
    ///   deltas refine from there).
    nonisolated static func applyCursorQuestionSignal(
        _ signal: CursorQuestionSignal,
        to session: inout SessionSnapshot,
        sessionId: String,
        transcriptPath: String?
    ) -> CursorQuestionApplication {
        guard session.source == "cursor" || session.source == "cursor-cli" else { return .ignored }

        switch signal {
        case .pending(let prompt):
            guard let transcriptPath,
                  CursorSessionFolding.parentConversationId(fromTranscriptPath: transcriptPath) == sessionId else {
                return .ignored
            }
            // An interactive approval outranks the display-only wait.
            guard session.status != .waitingApproval else { return .ignored }
            let fresh = session.status != .waitingQuestion || session.cursorPendingQuestion == nil
            session.status = .waitingQuestion
            session.cursorPendingQuestion = prompt
            session.currentTool = nil
            session.toolDescription = nil
            session.lastActivity = Date()
            return .markedWaiting(fresh: fresh)

        case .cleared:
            guard session.cursorPendingQuestion != nil else { return .ignored }
            session.cursorPendingQuestion = nil
            if session.status == .waitingQuestion {
                session.status = .processing
            }
            session.lastActivity = Date()
            return .clearedWaiting
        }
    }

    private nonisolated static func latestCodexTurnStatus(path: String) -> ConversationTurnStatus? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        // A long Codex turn can place its task_started event well before the
        // final 128 KB after emitting large reasoning/tool rows. Scan in chunks
        // so startup state recovery remains bounded in memory without missing
        // that event.
        handle.seek(toFileOffset: 0)
        let chunkSize = 64 * 1024
        var pendingFragment = Data()
        var latestStatus: ConversationTurnStatus?

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            let result = JSONLTailer.scanLines(pendingFragment + chunk)
            pendingFragment = result.trailingFragment
            if let turnStatus = result.delta.turnStatus {
                latestStatus = turnStatus
            }
        }

        return latestStatus
    }

    /// Reconstruct Claude's currently live background Bash queue from a transcript.
    /// The scan is chunked so even long-lived sessions stay bounded in memory.
    nonisolated static func latestClaudeBackgroundTaskIds(path: String) -> Set<String> {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { handle.closeFile() }

        handle.seek(toFileOffset: 0)
        let chunkSize = 64 * 1024
        var pendingFragment = Data()
        var activeTaskIds: Set<String> = []

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            let result = JSONLTailer.scanLines(pendingFragment + chunk)
            pendingFragment = result.trailingFragment
            activeTaskIds.formUnion(result.delta.startedBackgroundTaskIds)
            activeTaskIds.subtract(result.delta.finishedBackgroundTaskIds)
        }

        return activeTaskIds
    }

    /// Lightweight Stop-boundary recovery for the file-watch race. A newly
    /// backgrounded Bash result is adjacent to the Stop hook, so only the tail
    /// is needed; already-known long-running tasks live in SessionSnapshot.
    nonisolated static func recentClaudeBackgroundTaskIds(
        path: String,
        maxBytes: UInt64 = 512 * 1024
    ) -> Set<String> {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let startOffset = fileSize > maxBytes ? fileSize - maxBytes : 0
        handle.seek(toFileOffset: startOffset)
        var data = handle.readDataToEndOfFile()
        if startOffset > 0, let firstNewline = data.firstIndex(of: 0x0A) {
            data = Data(data[data.index(after: firstNewline)...])
        }

        let result = JSONLTailer.scanLines(data)
        var activeTaskIds = Set(result.delta.startedBackgroundTaskIds)
        activeTaskIds.subtract(result.delta.finishedBackgroundTaskIds)
        return activeTaskIds
    }

    /// Stop watching a session's transcript. Called when the session is removed or
    /// when a new transcript path supersedes an older one.
    func detachTranscriptTailer(sessionId: String) {
        attachedTranscriptPaths.removeValue(forKey: sessionId)
        transcriptTailer.detach(sessionId: sessionId)
    }

    /// Apply an incremental update produced by the tailer. Runs on the main actor.
    func applyTranscriptDelta(_ delta: ConversationTailDelta) {
        // Usage rows count even for sessions we no longer track — forward
        // before the session-existence guard below.
        if !delta.usageEvents.isEmpty {
            UsageManager.shared.ingestClaude(delta.usageEvents)
        }
        if !delta.codexUsageEvents.isEmpty {
            UsageManager.shared.ingestCodex(delta.codexUsageEvents)
        }

        for permissionDecision in delta.permissionDecisions {
            _ = resolvePermissionFromTranscript(
                sessionId: delta.sessionId,
                toolUseId: permissionDecision.toolUseId,
                decision: permissionDecision.decision
            )
        }
        resolveBrowserUseAttentionFromTranscript(toolUseIds: delta.completedToolCallIds)

        guard var session = sessions[delta.sessionId] else { return }
        var mutated = false
        var backgroundStateChanged = false

        if !delta.startedBackgroundTaskIds.isEmpty || !delta.finishedBackgroundTaskIds.isEmpty {
            let previousTaskIds = session.activeBackgroundTaskIds
            session.activeBackgroundTaskIds.formUnion(delta.startedBackgroundTaskIds)
            session.activeBackgroundTaskIds.subtract(delta.finishedBackgroundTaskIds)
            backgroundStateChanged = session.activeBackgroundTaskIds != previousTaskIds

            if !session.activeBackgroundTaskIds.isEmpty, session.status == .idle {
                // The Stop hook won the race with the transcript file extension.
                // Restore the state immediately instead of waiting for a later hook.
                session.status = .running
                session.currentTool = "Bash"
                session.toolDescription = "Background shell"
                session.isWaitingForBackgroundTasks = true
                backgroundStateChanged = true
            } else if session.activeBackgroundTaskIds.isEmpty,
                      session.isWaitingForBackgroundTasks {
                session.isWaitingForBackgroundTasks = false
                let isWaitingForUser = session.status == .waitingApproval
                    || session.status == .waitingQuestion
                if !isWaitingForUser,
                   !session.subagents.values.contains(where: { $0.status != .idle }) {
                    // Claude consumes the completion notification as a system-origin
                    // prompt, so the next accurate state is processing until Stop.
                    session.status = .processing
                    session.currentTool = nil
                    session.toolDescription = nil
                }
                backgroundStateChanged = true
            }
            mutated = mutated || backgroundStateChanged
        }

        if delta.hasActivity {
            session.lastActivity = Date()
            mutated = true
        }

        if let turnStatus = delta.turnStatus {
            switch turnStatus {
            case .processing:
                session.status = .processing
                session.interrupted = false
                session.taskRoundEnded = false
            case .idle:
                session.status = .idle
                session.currentTool = nil
                session.toolDescription = nil
                clearBrowserUseAttention(forSessionId: delta.sessionId)
            }
            // A status-only event is still activity. This matters for a long Codex
            // turn whose transcript has not emitted a message yet.
            session.lastActivity = Date()
            mutated = true
        }

        if let prompt = delta.lastUserPrompt, session.lastUserPrompt != prompt {
            session.lastUserPrompt = prompt
            if session.recentMessages.last(where: { $0.isUser })?.text != prompt {
                session.addRecentMessage(ChatMessage(isUser: true, text: prompt))
            }
            mutated = true
        }
        if let reply = delta.lastAssistantMessage, session.lastAssistantMessage != reply {
            session.lastAssistantMessage = reply
            if session.recentMessages.last(where: { !$0.isUser })?.text != reply {
                session.addRecentMessage(ChatMessage(isUser: false, text: reply))
            }
            mutated = true
        }

        // Claude never fires the Stop hook when the user interrupts a turn (Esc), and
        // Claude Desktop keeps its bundled `claude` engine process alive between turns,
        // so neither the hook path nor process-exit/timeout sweeps ever settle the
        // session — it stays "thinking" forever. The transcript's interrupt marker is
        // the only reliable end-of-turn signal in that case.
        if let prompt = delta.lastUserPrompt,
           prompt.hasPrefix("[Request interrupted by user"),
           session.status != .idle {
            session.status = .idle
            session.interrupted = true
            session.currentTool = nil
            session.toolDescription = nil
            mutated = true
        }

        // Cursor question tool has no hook channel (#265) — the transcript tail is
        // the only signal that the agent is blocked on (or resumed from) a question
        // answered inside Cursor's own UI.
        var questionStateChanged = false
        if let signal = delta.cursorQuestion {
            let application = Self.applyCursorQuestionSignal(
                signal,
                to: &session,
                sessionId: delta.sessionId,
                transcriptPath: attachedTranscriptPaths[delta.sessionId]
            )
            if application != .ignored {
                mutated = true
                questionStateChanged = true
            }
            if application == .markedWaiting(fresh: true) {
                SoundManager.shared.handleEvent("PermissionRequest")
            }
        }

        // Codex async questions never block the turn and fire no hook: the rollout
        // row is the only signal, and the reminder must outlive whatever status
        // the still-running turn reports next.
        var codexQuestionApplication: CodexAsyncQuestionApplication = .ignored
        if let signal = delta.codexAsyncQuestion {
            codexQuestionApplication = Self.applyCodexAsyncQuestionSignal(signal, to: &session)
            if codexQuestionApplication != .ignored {
                mutated = true
                questionStateChanged = true
            }
        }

        if mutated {
            session.lastActivity = Date()
            sessions[delta.sessionId] = session
        }
        switch codexQuestionApplication {
        case .markedPending(fresh: true):
            presentCodexAsyncQuestionCard(sessionId: delta.sessionId)
        case .clearedPending:
            clearCodexAsyncQuestionCard(forSessionId: delta.sessionId)
        case .markedPending(fresh: false), .ignored:
            break
        }
        if questionStateChanged || backgroundStateChanged {
            // Hooks stay silent while Cursor waits on its question, so nothing
            // else recomputes the aggregated pill/mascot state for this flip.
            // Claude background task transcript updates have the same property.
            refreshDerivedState()
        }
    }
}
